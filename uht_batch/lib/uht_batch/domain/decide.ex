defmodule UhtBatch.Domain.Decide do
  @moduledoc """
  纯函数决策：命令 + 当前状态 -> {:ok, [新事件]} | {:error, 原因}。

  边界：
    * 仅依据“已确认事实”（操作员按批准记录确认；设备只读状态不自动构成事实）；
    * 不接收/不保存无菌操作参数；
    * 不发出任何阀阵/灌装机控制指令。
  """

  alias UhtBatch.Domain.{Event, State}

  @deviation_codes %{
    heel_identity_unknown: "DEV-HEEL-UNKNOWN",
    interface_destination_unknown: "DEV-IFACE-UNKNOWN",
    filling_with_open_interface: "DEV-FILL-OPEN-IFACE",
    equipment_short_stop_unconfirmed: "DEV-EQ-STOP-UNCONFIRMED",
    filling_stop_open: "DEV-STOP-OPEN",
    missing_sterility_sample: "DEV-SAMPLE-MISSING",
    sample_lineage_gap: "DEV-SAMPLE-LINEAGE",
    sample_no_reuse: "DEV-SAMPLE-REUSE",
    manual: "DEV-MANUAL"
  }

  def deviation_code(key), do: Map.fetch!(@deviation_codes, key)

  ## 各命令决策 -------------------------------------------------------------

  def decide({:confirm_pretreatment, cmd}, %State{} = s) do
    required([:batch_id, :operator_id, :occurred_at, :record_ref, :product_code], cmd)
    |> reject_if(s.pretreatment, :pretreatment_already_confirmed)
    |> build(fn ->
      [
        event(:pretreatment_confirmed, cmd, %{
          record_ref: cmd.record_ref,
          product_code: cmd.product_code
        })
      ]
    end)
  end

  def decide({:confirm_heat_pass, cmd}, %State{} = s) do
    with :ok <-
           require_fields([:batch_id, :operator_id, :occurred_at, :record_ref, :line_id], cmd),
         :ok <- require_present(s.pretreatment, :pretreatment_not_confirmed),
         :ok <- reject(s.heat_pass, :heat_pass_already_confirmed) do
      {:ok,
       [
         event(:heat_treatment_passed, cmd, %{
           record_ref: cmd.record_ref,
           line_id: cmd.line_id
         })
       ]}
    end
  end

  def decide({:transfer_to_tank, cmd}, %State{} = s) do
    with :ok <- require_fields([:batch_id, :operator_id, :occurred_at, :tank_id], cmd),
         :ok <- require_present(s.heat_pass, :heat_pass_not_confirmed) do
      events =
        [
          event(:transfer_started, cmd, %{
            tank_id: cmd.tank_id,
            from: cmd[:from],
            previous_batch: cmd[:previous_batch]
          }),
          event(:tank_occupied, cmd, %{
            tank_id: cmd.tank_id,
            previous_batch: cmd[:previous_batch],
            heel_present: cmd[:heel_present] == true
          })
        ]

      events =
        if cmd[:heel_present] == true and blank?(cmd[:previous_batch]) do
          events ++
            [
              deviation_event(
                cmd,
                :heel_identity_unknown,
                "无菌罐含上批底液，且上批批次身份不明（罐：#{cmd.tank_id}）",
                %{tank_id: cmd.tank_id}
              )
            ]
        else
          events
        end

      {:ok, events}
    end
  end

  def decide({:declare_interface, cmd}, %State{}) do
    with :ok <-
           require_fields(
             [:batch_id, :operator_id, :occurred_at, :interface_id, :product_a, :product_b],
             cmd
           ) do
      unknown = blank?(cmd[:destination])

      events =
        [
          event(:interface_declared, cmd, %{
            interface_id: cmd.interface_id,
            product_a: cmd.product_a,
            product_b: cmd.product_b,
            from_batch: cmd[:from_batch],
            to_batch: cmd[:to_batch],
            destination: if(unknown, do: "unknown", else: cmd.destination)
          })
        ]

      events =
        if unknown do
          events ++
            [
              deviation_event(
                cmd,
                :interface_destination_unknown,
                "产品界面 #{cmd.interface_id} 去向不明",
                %{interface_id: cmd.interface_id}
              )
            ]
        else
          events
        end

      {:ok, events}
    end
  end

  def decide({:start_filling, cmd}, %State{} = s) do
    with :ok <-
           require_fields([:batch_id, :operator_id, :occurred_at, :line_id, :filler_id], cmd),
         :ok <- require_present(s.heat_pass, :heat_pass_not_confirmed),
         :ok <- reject(s.filling, :filling_already_started),
         :ok <- require_no_open(s, :interface_destination_unknown, :open_interface_blocks_filling) do
      {:ok, [event(:filling_started, cmd, %{line_id: cmd.line_id, filler_id: cmd.filler_id})]}
    end
  end

  def decide({:record_short_stop, cmd}, %State{} = s) do
    with :ok <- require_fields([:batch_id, :operator_id, :occurred_at, :reason], cmd),
         :ok <- require_present(s.filling, :filling_not_started),
         :ok <- reject(s.active_stop, :stop_already_open) do
      events =
        [
          event(:line_short_stop, cmd, %{
            reason: cmd.reason,
            origin: cmd[:origin] || :operator,
            equipment_log_ref: cmd[:equipment_log_ref]
          })
        ]

      events =
        case open_deviation(s, :equipment_short_stop_unconfirmed, cmd[:equipment_log_ref]) do
          nil ->
            events

          d ->
            events ++
              [
                close_event(cmd, d.id, "操作员按批准记录确认设备短停 #{cmd[:equipment_log_ref] || ""}")
              ]
        end

      {:ok, events}
    end
  end

  def decide({:resume_line, cmd}, %State{} = s) do
    with :ok <- require_fields([:batch_id, :operator_id, :occurred_at, :stop_event_id], cmd),
         %{} = stop <- find_stop(s, cmd.stop_event_id),
         :ok <- reject(stop.resumed_at != nil, :stop_already_resumed) do
      {:ok,
       [
         event(:line_resumed, cmd, %{stop_event_id: cmd.stop_event_id})
       ]}
    end
  end

  def decide({:reject_sample, cmd}, %State{} = s) do
    with :ok <- require_fields([:batch_id, :operator_id, :occurred_at, :sample_no], cmd),
         %{} = sample <- Map.get(s.samples, cmd.sample_no),
         :ok <- reject(sample.status == :rejected, :sample_already_rejected) do
      {:ok,
       [
         event(:sample_rejected, cmd, %{
           sample_no: cmd.sample_no,
           reason: cmd[:reason]
         })
       ]}
    end
  end

  def decide({:open_deviation, cmd}, %State{}) do
    with :ok <- require_fields([:batch_id, :operator_id, :occurred_at, :reason], cmd) do
      {:ok, [deviation_event(cmd, :manual, cmd.reason, cmd[:context] || %{})]}
    end
  end

  def decide({:close_deviation, cmd}, %State{} = s) do
    with :ok <- require_fields([:batch_id, :operator_id, :occurred_at, :deviation_id], cmd),
         %{} = d <- Map.get(s.deviations, cmd.deviation_id) || {:error, :deviation_not_found},
         :ok <- reject(d.status == :closed, :deviation_already_closed) do
      {:ok, [close_event(cmd, d.id, cmd[:disposition] || "按证据关闭偏差")]}
    end
  end

  def decide({:acknowledge_backfill, cmd}, %State{} = s) do
    refs = cmd[:anomaly_refs] || []

    known =
      s.backfill_anomalies
      |> Enum.map(&{&1.inserted_event_id, &1.prior_event_id})
      |> MapSet.new()

    unknown = Enum.reject(refs, &MapSet.member?(known, &1))

    with :ok <- require_fields([:batch_id, :operator_id, :occurred_at], cmd),
         :ok <- if(Enum.empty?(refs), do: {:error, :no_anomaly_refs}, else: :ok),
         :ok <-
           if(Enum.empty?(unknown), do: :ok, else: {:error, {:unknown_anomaly_refs, unknown}}) do
      {:ok, [event(:backfill_acknowledged, cmd, %{anomaly_refs: refs})]}
    end
  end

  def decide({:production_signoff, cmd}, %State{} = s) do
    with :ok <- require_fields([:batch_id, :operator_id, :occurred_at, :credential_id], cmd),
         :ok <- require_present(s.heat_pass, :heat_pass_not_confirmed),
         :ok <- reject(s.production_signoff, :production_already_signed_off) do
      blockers = UhtBatch.Domain.Checks.blockers_for(:production, s, cmd[:policy] || %{})

      if blockers == [] do
        {:ok,
         [
           event(:production_signed_off, cmd, %{
             credential_id: cmd.credential_id,
             findings: []
           })
         ]}
      else
        {:error, {:signoff_blocked, blockers}}
      end
    end
  end

  def decide({:quality_signoff, cmd}, %State{} = s) do
    with :ok <- require_fields([:batch_id, :operator_id, :occurred_at, :credential_id], cmd),
         :ok <- require_present(s.production_signoff, :production_not_signed_off),
         :ok <- reject(s.quality_signoff, :quality_already_signed_off) do
      blockers = UhtBatch.Domain.Checks.blockers_for(:quality, s, cmd[:policy] || %{})

      if blockers == [] do
        {:ok,
         [
           event(:quality_signed_off, cmd, %{
             credential_id: cmd.credential_id,
             findings: UhtBatch.Domain.Checks.all(s, cmd[:policy] || %{})
           })
         ]}
      else
        {:error, {:signoff_blocked, blockers}}
      end
    end
  end

  def decide({:register_sample, cmd}, %State{} = s, sample_claimed?) do
    decide_sample(cmd, s, sample_claimed?)
  end

  defp decide_sample(cmd, %State{} = s, sample_claimed?) do
    with :ok <-
           require_fields([:batch_id, :operator_id, :occurred_at, :sample_no, :sample_type], cmd),
         :ok <-
           if(sample_claimed? or Map.has_key?(s.samples, cmd.sample_no),
             do: {:error, {:sample_no_already_used, cmd.sample_no}},
             else: :ok
           ),
         :ok <- validate_lineage(cmd[:lineage] || [], s),
         :ok <- validate_sample_type(cmd.sample_type) do
      # 商业无菌样品需在灌装开始之后登记
      :ok =
        if cmd.sample_type in [:commercial_sterility, :incubation] and is_nil(s.filling) do
          {:error, :filling_not_started}
        else
          :ok
        end

      {:ok,
       [
         event(:sample_registered, cmd, %{
           sample_no: cmd.sample_no,
           sample_type: cmd.sample_type,
           lineage: cmd[:lineage] || [],
           record_ref: cmd[:record_ref]
         })
       ]}
    end
  end

  ## 帮助函数 ---------------------------------------------------------------

  defp event(type, cmd, payload) do
    %Event{
      id: cmd[:event_id] || gen_id(type),
      type: type,
      batch_id: cmd.batch_id,
      occurred_at: cmd.occurred_at,
      recorded_at: cmd[:recorded_at] || cmd.occurred_at,
      source: cmd[:source] || :operator,
      correlation_id: cmd[:correlation_id],
      operator_id: cmd[:operator_id],
      payload: payload
    }
  end

  defp deviation_event(cmd, code_key, reason, context) do
    dcmd =
      cmd
      |> Map.put_new(:deviation_id, gen_id("dev"))
      |> Map.put(:code, deviation_code(code_key))

    event(:deviation_opened, dcmd, %{
      deviation_id: dcmd.deviation_id,
      code: deviation_code(code_key),
      reason: reason,
      context: context
    })
  end

  defp close_event(cmd, deviation_id, disposition) do
    event(:deviation_closed, cmd, %{
      deviation_id: deviation_id,
      disposition: disposition
    })
  end

  defp gen_id(prefix), do: "#{prefix}_#{:erlang.unique_integer([:positive, :monotonic])}"

  defp require_fields(fields, cmd) do
    Enum.find_value(fields, :ok, fn f ->
      val = cmd[f]
      if blank?(val), do: {:error, {:missing_field, f}}, else: nil
    end)
  end

  defp required(fields, cmd), do: require_fields(fields, cmd)

  defp build({:error, _} = err, _), do: err
  defp build(:ok, fun), do: {:ok, fun.()}

  defp reject_if({:error, _} = err, _, _), do: err
  defp reject_if(:ok, nil, _), do: :ok
  defp reject_if(:ok, _, reason), do: {:error, reason}

  defp reject(nil, _reason), do: :ok
  defp reject(false, _reason), do: :ok
  defp reject(_, reason), do: {:error, reason}

  defp require_present(nil, reason), do: {:error, reason}
  defp require_present(_, _), do: :ok

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(:unknown), do: true
  defp blank?(_), do: false

  defp find_stop(s, event_id) do
    Enum.find(s.stops, &(&1.event_id == event_id)) || {:error, :stop_not_found}
  end

  defp open_deviation(s, code_key, ref) do
    code = deviation_code(code_key)

    Enum.find(State.open_deviations(s), fn d ->
      d.code == code and
        (is_nil(ref) or get_in(d.context, [:equipment_log_ref]) == ref)
    end)
  end

  defp require_no_open(s, code_key, reason) do
    case open_deviation(s, code_key, nil) do
      nil -> :ok
      _d -> {:error, reason}
    end
  end

  defp validate_sample_type(type)
       when type in [:commercial_sterility, :incubation, :micro, :retain],
       do: :ok

  defp validate_sample_type(_), do: {:error, :invalid_sample_type}

  defp validate_lineage([], _s), do: :ok

  defp validate_lineage(chain_ids, s) do
    known = MapSet.new(s.chain_events, & &1.id)

    case Enum.find(chain_ids, &(not MapSet.member?(known, &1))) do
      nil -> :ok
      missing -> {:error, {:lineage_event_not_in_batch, missing}}
    end
  end
end
