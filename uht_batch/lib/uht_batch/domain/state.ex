defmodule UhtBatch.Domain.State do
  @moduledoc """
  批次状态折叠（event-sourced fold）。从批次事件流（按写入顺序）
  还原当前事实状态，并在折叠过程中计算“补传导致的时序倒置”异常。
  """

  alias UhtBatch.Domain.{Decide, Event}

  # 处置/元事件：其发生时间是管理动作时间，不推进连续链事实末端
  @backfill_meta_types [
    :deviation_closed,
    :backfill_acknowledged,
    :production_signed_off,
    :quality_signed_off,
    :splice_failure_disposed,
    :splice_segment_reviewed
  ]

  defstruct [
    :batch_id,
    events: [],
    chain_events: [],
    pretreatment: nil,
    heat_pass: nil,
    transfers: [],
    current_tank: nil,
    tank_history: %{},
    interfaces: [],
    filling: nil,
    stops: [],
    active_stop: nil,
    deviations: %{},
    samples: %{},
    equipment_signals: [],
    production_signoff: nil,
    quality_signoff: nil,
    backfill_anomalies: [],
    acknowledged_pairs: MapSet.new(),
    max_occurred_at: nil,
    rolls: %{},
    changeovers: [],
    splice_failures: [],
    current_roll_id: nil
  ]

  @type t :: %__MODULE__{}

  @doc "空批次状态。"
  def new(batch_id), do: %__MODULE__{batch_id: batch_id}

  @doc """
  按**写入顺序**折叠单个事件。`occurred_at` 早于已确认链事实时，
  计算出补传时序倒置异常（不会修改或重排既有事件）。
  """
  def apply(%__MODULE__{} = state, %Event{} = e) do
    state = %{state | events: state.events ++ [e]}

    state =
      if e.type == :equipment_status_received do
        track_equipment_signal(state, e)
      else
        state
      end

    if e.type in Event.chain_types() or e.type == :equipment_status_received do
      state
      |> detect_backfill(e)
      |> maybe_apply_chain(e)
    else
      state
    end
  end

  defp detect_backfill(state, %Event{occurred_at: at} = e) do
    # “元事件”（操作员对补传倒置的确认、偏差关闭、签署）的发生时间是处置动作
    # 时间，不代表连续链事实时点；既不推进链末端，也不参与倒置判定。
    if e.type in @backfill_meta_types do
      state
    else
      case state.max_occurred_at do
        nil ->
          %{state | max_occurred_at: at}

        max_at ->
          if DateTime.compare(at, max_at) == :lt do
            prior =
              Enum.find(state.chain_events, &(&1.occurred_at == max_at)) ||
                List.last(state.chain_events)

            anomaly = %{
              inserted_event_id: e.id,
              prior_event_id: prior && prior.id,
              inserted_occurred_at: at,
              prior_occurred_at: max_at,
              detail:
                "补传事件 #{e.type} 的发生时间 #{DateTime.to_iso8601(at)} 早于已确认链末端 #{DateTime.to_iso8601(max_at)}",
              equipment_origin: e.source == :equipment or e.raw_equipment_log != nil,
              acknowledged: false,
              ack_event_id: nil
            }

            %{state | backfill_anomalies: state.backfill_anomalies ++ [anomaly]}
          else
            %{state | max_occurred_at: at}
          end
      end
    end
  end

  defp maybe_apply_chain(state, %Event{type: :equipment_status_received}), do: state

  defp maybe_apply_chain(state, e) do
    state = %{state | chain_events: state.chain_events ++ [e]}
    apply_chain_body(state, e)
  end

  defp apply_chain_body(state, e) do
    case e.type do
      :pretreatment_confirmed ->
        %{
          state
          | pretreatment: %{
              at: e.occurred_at,
              operator_id: e.operator_id,
              record_ref: e.payload[:record_ref],
              product_code: e.payload[:product_code]
            }
        }

      :heat_treatment_passed ->
        %{
          state
          | heat_pass: %{
              at: e.occurred_at,
              operator_id: e.operator_id,
              record_ref: e.payload[:record_ref],
              line_id: e.payload[:line_id]
            }
        }

      :transfer_started ->
        transfer = %{
          at: e.occurred_at,
          tank_id: e.payload[:tank_id],
          from: e.payload[:from],
          previous_batch: e.payload[:previous_batch],
          event_id: e.id
        }

        %{state | transfers: state.transfers ++ [transfer]}

      :tank_occupied ->
        entry = %{
          tank_id: e.payload[:tank_id],
          batch_id: e.batch_id,
          previous_batch: e.payload[:previous_batch],
          heel_present: e.payload[:heel_present] == true,
          at: e.occurred_at,
          event_id: e.id
        }

        history =
          Map.update(state.tank_history, e.payload[:tank_id], [entry], &(&1 ++ [entry]))

        %{state | current_tank: e.payload[:tank_id], tank_history: history}

      :interface_declared ->
        iface = %{
          id: e.payload[:interface_id],
          at: e.occurred_at,
          event_id: e.id,
          product_a: e.payload[:product_a],
          product_b: e.payload[:product_b],
          from_batch: e.payload[:from_batch],
          to_batch: e.payload[:to_batch],
          destination: e.payload[:destination],
          status:
            if(e.payload[:destination] in [nil, "", :unknown, "unknown"],
              do: :unknown,
              else: :declared
            )
        }

        # 同一界面 ID 的后续声明（如先“去向不明”后澄清）合并为同一事实视图
        interfaces =
          if Enum.any?(state.interfaces, &(&1.id == iface.id)) do
            Enum.map(state.interfaces, fn i -> if i.id == iface.id, do: iface, else: i end)
          else
            state.interfaces ++ [iface]
          end

        %{state | interfaces: interfaces}

      :filling_started ->
        %{
          state
          | filling: %{
              at: e.occurred_at,
              line_id: e.payload[:line_id],
              filler_id: e.payload[:filler_id],
              event_id: e.id
            }
        }

      :line_short_stop ->
        stop = %{
          at: e.occurred_at,
          resumed_at: nil,
          reason: e.payload[:reason],
          source: e.source,
          origin: e.payload[:origin],
          equipment_log_ref: e.payload[:equipment_log_ref],
          confirmed_by: e.operator_id,
          event_id: e.id,
          resume_event_id: nil
        }

        %{state | stops: state.stops ++ [stop], active_stop: stop}

      :line_resumed ->
        stops =
          Enum.map(state.stops, fn s ->
            if s.event_id == e.payload[:stop_event_id] do
              %{s | resumed_at: e.occurred_at, resume_event_id: e.id}
            else
              s
            end
          end)

        active =
          case Enum.find(stops, &(&1.event_id == e.payload[:stop_event_id])) do
            %{resumed_at: at} when not is_nil(at) -> nil
            other -> other
          end

        %{state | stops: stops, active_stop: active}

      :pack_roll_registered ->
        roll = %{
          roll_id: e.payload[:roll_id],
          at: e.occurred_at,
          event_id: e.id,
          material_code: e.payload[:material_code],
          label_declared: e.payload[:label_declared],
          label_verified: e.payload[:label_verified],
          label_status: if(e.payload[:label_verified] == true, do: :verified, else: :mismatch),
          operator_id: e.operator_id,
          started_at: nil,
          start_seq: nil,
          ended_at: nil,
          end_seq: nil
        }

        %{
          state
          | rolls: Map.put(state.rolls, roll.roll_id, roll),
            current_roll_id: state.current_roll_id || roll.roll_id
        }

      :roll_changeover_confirmed ->
        co = %{
          splice_seq: e.payload[:splice_seq],
          at: e.occurred_at,
          event_id: e.id,
          out_roll_id: e.payload[:out_roll_id],
          in_roll_id: e.payload[:in_roll_id],
          seq_before: e.payload[:seq_before],
          seq_after: e.payload[:seq_after],
          equipment_log_ref: e.payload[:equipment_log_ref],
          interface_id: e.payload[:interface_id],
          operator_id: e.operator_id,
          reviewed: false,
          disposition: nil,
          review_event_id: nil,
          reviewed_at: nil,
          reviewer_id: nil,
          review_note: nil
        }

        rolls =
          state.rolls
          |> mark_roll(co.out_roll_id, fn r ->
            %{r | ended_at: r.ended_at || co.at, end_seq: co.seq_before}
          end)
          |> mark_roll(co.in_roll_id, fn r ->
            %{r | started_at: co.at, start_seq: co.seq_after, ended_at: nil}
          end)

        %{
          state
          | changeovers: state.changeovers ++ [co],
            current_roll_id: co.in_roll_id,
            rolls: rolls
        }

      :splice_failure_recorded ->
        failure = %{
          splice_seq: e.payload[:splice_seq],
          at: e.occurred_at,
          event_id: e.id,
          out_roll_id: e.payload[:out_roll_id],
          attempted_in_roll_id: e.payload[:attempted_in_roll_id],
          reason: e.payload[:reason],
          equipment_log_ref: e.payload[:equipment_log_ref],
          deviation_id: e.payload[:deviation_id],
          status: :open,
          disposition: nil,
          disposition_detail: nil,
          dispose_event_id: nil,
          disposed_at: nil
        }

        %{state | splice_failures: state.splice_failures ++ [failure]}

      :splice_failure_disposed ->
        failures =
          Enum.map(state.splice_failures, fn f ->
            if f.splice_seq == e.payload[:splice_seq] do
              %{
                f
                | status: :disposed,
                  disposition: e.payload[:disposition],
                  disposition_detail: e.payload[:detail],
                  dispose_event_id: e.id,
                  disposed_at: e.occurred_at
              }
            else
              f
            end
          end)

        %{state | splice_failures: failures}

      :splice_segment_reviewed ->
        changeovers =
          Enum.map(state.changeovers, fn co ->
            if co.splice_seq == e.payload[:splice_seq] do
              %{
                co
                | reviewed: true,
                  disposition: e.payload[:disposition],
                  review_event_id: e.id,
                  reviewed_at: e.occurred_at,
                  reviewer_id: e.operator_id,
                  review_note: e.payload[:note]
              }
            else
              co
            end
          end)

        %{state | changeovers: changeovers}

      :deviation_opened ->
        d = %{
          id: e.payload[:deviation_id],
          code: e.payload[:code],
          status: :open,
          opened_at: e.occurred_at,
          closed_at: nil,
          reason: e.payload[:reason],
          context: e.payload[:context] || %{},
          disposition: nil,
          close_event_id: nil
        }

        %{state | deviations: Map.put(state.deviations, d.id, d)}

      :deviation_closed ->
        deviations =
          Map.update!(state.deviations, e.payload[:deviation_id], fn d ->
            %{
              d
              | status: :closed,
                closed_at: e.occurred_at,
                disposition: e.payload[:disposition],
                close_event_id: e.id
            }
          end)

        closed = Map.fetch!(deviations, e.payload[:deviation_id])

        rolls =
          if closed.code == Decide.deviation_code(:roll_label_mismatch) do
            roll_id = get_in(closed.context, [:roll_id])

            case roll_id && Map.get(state.rolls, roll_id) do
              nil ->
                state.rolls

              _roll ->
                Map.update!(state.rolls, roll_id, fn r ->
                  %{r | label_status: :verified, label_verified: true}
                end)
            end
          else
            state.rolls
          end

        %{state | deviations: deviations, rolls: rolls}

      :sample_registered ->
        key = e.payload[:sample_no]

        sample = %{
          sample_no: key,
          sample_type: e.payload[:sample_type],
          at: e.occurred_at,
          status: :registered,
          lineage: e.payload[:lineage] || [],
          record_ref: e.payload[:record_ref],
          operator_id: e.operator_id,
          event_id: e.id,
          reject_event_id: nil
        }

        %{state | samples: Map.put(state.samples, key, sample)}

      :sample_rejected ->
        samples =
          Map.update!(state.samples, e.payload[:sample_no], fn s ->
            %{s | status: :rejected, reject_event_id: e.id}
          end)

        %{state | samples: samples}

      :backfill_acknowledged ->
        acked =
          Enum.reduce(e.payload[:anomaly_refs] || [], state.acknowledged_pairs, fn ref, acc ->
            MapSet.put(acc, ref)
          end)

        anomalies =
          Enum.map(state.backfill_anomalies, fn a ->
            ref = {a.inserted_event_id, a.prior_event_id}

            if MapSet.member?(acked, ref) do
              %{a | acknowledged: true, ack_event_id: e.id}
            else
              a
            end
          end)

        %{state | backfill_anomalies: anomalies, acknowledged_pairs: acked}

      :production_signed_off ->
        %{
          state
          | production_signoff: %{
              at: e.occurred_at,
              operator_id: e.operator_id,
              credential_id: e.payload[:credential_id],
              event_id: e.id
            }
        }

      :quality_signed_off ->
        %{
          state
          | quality_signoff: %{
              at: e.occurred_at,
              operator_id: e.operator_id,
              credential_id: e.payload[:credential_id],
              event_id: e.id
            }
        }

      _ ->
        state
    end
  end

  defp track_equipment_signal(state, e) do
    signal = %{
      at: e.occurred_at,
      recorded_at: e.recorded_at,
      device_id: e.payload[:device_id],
      status: e.payload[:status],
      raw: e.raw_equipment_log,
      event_id: e.id
    }

    %{state | equipment_signals: state.equipment_signals ++ [signal]}
  end

  defp mark_roll(rolls, roll_id, fun) do
    case Map.get(rolls, roll_id) do
      nil -> rolls
      roll -> Map.put(rolls, roll_id, fun.(roll))
    end
  end

  @doc "未复核的接头区间（默认待复核，禁止整批放行）。"
  def pending_splice_segments(%__MODULE__{changeovers: cos}) do
    Enum.filter(cos, &(&1.reviewed == false))
  end

  @doc "已复核但判定拒绝/隔离的接头区间。"
  def rejected_splice_segments(%__MODULE__{changeovers: cos}) do
    Enum.filter(cos, &(&1.reviewed == true and &1.disposition == :reject))
  end

  @doc "未处置的两卷并接失败。"
  def open_splice_failures(%__MODULE__{splice_failures: fs}) do
    Enum.filter(fs, &(&1.status == :open))
  end

  @doc """
  包装材料卷与成品序列形成的区间（按确认写入顺序）。

  首卷：灌装开始（或首卷登记）→ 第一次接头 `seq_before`；
  换卷后：`seq_after` → 下一次接头；末卷至当前序列末端（`nil`）。
  每个接头区间在 `:splice_zone` 中单独列出（默认待复核）。
  """
  def roll_intervals(%__MODULE__{} = s) do
    cos = Enum.sort_by(s.changeovers, & &1.at, DateTime)

    runs =
      cond do
        cos == [] ->
          case s.current_roll_id do
            nil -> []
            rid -> [%{roll_id: rid, from_seq: 0, to_seq: nil, kind: :roll_run}]
          end

        true ->
          first = hd(cos)

          head =
            if first.out_roll_id do
              [
                %{
                  roll_id: first.out_roll_id,
                  from_seq: 0,
                  to_seq: first.seq_before,
                  kind: :roll_run
                }
              ]
            else
              []
            end

          middle =
            cos
            |> Enum.chunk_every(2, 1, :discard)
            |> Enum.map(fn [a, b] ->
              %{
                roll_id: a.in_roll_id,
                from_seq: a.seq_after,
                to_seq: b.seq_before,
                kind: :roll_run
              }
            end)

          last = List.last(cos)

          tail = [
            %{roll_id: last.in_roll_id, from_seq: last.seq_after, to_seq: nil, kind: :roll_run}
          ]

          head ++ middle ++ tail
      end

    zones =
      Enum.map(cos, fn co ->
        %{
          splice_seq: co.splice_seq,
          from_seq: co.seq_before,
          to_seq: co.seq_after,
          out_roll_id: co.out_roll_id,
          in_roll_id: co.in_roll_id,
          reviewed: co.reviewed,
          disposition: co.disposition,
          kind: :splice_zone
        }
      end)

    runs ++ zones
  end

  @doc "标签异常（未核实）的材料卷。"
  def label_mismatched_rolls(%__MODULE__{rolls: rolls}) do
    rolls |> Map.values() |> Enum.filter(&(&1.label_status == :mismatch))
  end

  @doc "某接头区间是否已登记接头样（谱系引用接头确认事件）。"
  def splice_sample_registered?(%__MODULE__{} = s, changeover_event_id) do
    s.samples
    |> Map.values()
    |> Enum.any?(fn sample ->
      sample.status == :registered and
        sample.sample_type == :splice and
        changeover_event_id in (sample.lineage || [])
    end)
  end

  @doc "按发生时间排序的链事实视图（仅用于展示/检查，不改变流）。"
  def chronological_chain(%__MODULE__{chain_events: events}) do
    Enum.sort_by(events, & &1.occurred_at, DateTime)
  end

  @doc "未关闭偏差列表。"
  def open_deviations(%__MODULE__{deviations: deviations}) do
    deviations |> Map.values() |> Enum.filter(&(&1.status == :open))
  end

  @doc "未确认的补传时序倒置。"
  def unacknowledged_backfills(%__MODULE__{backfill_anomalies: list}) do
    Enum.filter(list, &(&1.acknowledged == false))
  end

  @doc "全部批次事件写入版本号（长度）。"
  def version(%__MODULE__{events: events}), do: length(events)
end
