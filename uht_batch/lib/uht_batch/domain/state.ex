defmodule UhtBatch.Domain.State do
  @moduledoc """
  批次状态折叠（event-sourced fold）。从批次事件流（按写入顺序）
  还原当前事实状态，并在折叠过程中计算“补传导致的时序倒置”异常。
  """

  alias UhtBatch.Domain.Event

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
    max_occurred_at: nil
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
          product_a: e.payload[:product_a],
          product_b: e.payload[:product_b],
          from_batch: e.payload[:from_batch],
          to_batch: e.payload[:to_batch],
          destination: e.payload[:destination],
          status:
            if(e.payload[:destination] in [nil, "", :unknown], do: :unknown, else: :declared)
        }

        %{state | interfaces: state.interfaces ++ [iface]}

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

        %{state | deviations: deviations}

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
