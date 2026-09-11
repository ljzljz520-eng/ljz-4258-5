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
    roll_label_mismatch: "DEV-ROLL-LABEL",
    equipment_splice_unconfirmed: "DEV-EQ-SPLICE-UNCONFIRMED",
    splice_failure: "DEV-SPLICE-FAIL",
    splice_coincides_interface: "DEV-ROLL-IFACE",
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

  ## 包装材料卷 ----------------------------------------------------------

  # 登记一卷包装材料的身份。操作员按实物标签与批准记录核对：
  # `label_verified=false`（或与声明标签不符）时，材料卷标签异常，
  # 自动开偏差 DEV-ROLL-LABEL；该卷在偏差关闭前不得用于换卷。
  def decide({:register_pack_roll, cmd}, %State{} = s) do
    with :ok <-
           require_fields(
             [:batch_id, :operator_id, :occurred_at, :roll_id, :material_code, :label_declared],
             cmd
           ),
         :ok <- reject(Map.has_key?(s.rolls, cmd.roll_id), :roll_already_registered) do
      verified = cmd[:label_verified] == true

      events =
        [
          event(:pack_roll_registered, cmd, %{
            roll_id: cmd.roll_id,
            material_code: cmd.material_code,
            label_declared: cmd.label_declared,
            label_verified: verified,
            record_ref: cmd[:record_ref]
          })
        ]

      events =
        if verified do
          events
        else
          events ++
            [
              deviation_event(
                cmd,
                :roll_label_mismatch,
                "包装材料卷 #{cmd.roll_id} 实物标签与声明/批准记录不符（材料 #{cmd.material_code}）",
                %{
                  roll_id: cmd.roll_id,
                  material_code: cmd.material_code,
                  label_declared: cmd.label_declared
                }
              )
            ]
        end

      {:ok, events}
    end
  end

  # 操作员按批准记录确认一次材料卷切换（接头）。接头时点与
  # `seq_before`/`seq_after` 成品序列号共同确定接头区间，
  # 该区间默认“待复核”，不能随整批一起放行。
  def decide({:confirm_roll_changeover, cmd}, %State{} = s) do
    with :ok <-
           require_fields(
             [
               :batch_id,
               :operator_id,
               :occurred_at,
               :splice_seq,
               :out_roll_id,
               :in_roll_id,
               :seq_before,
               :seq_after
             ],
             cmd
           ),
         :ok <- require_present(s.filling, :filling_not_started),
         :ok <- reject(find_changeover(s, cmd.splice_seq), :splice_seq_already_recorded),
         %{} = out_roll <- find_roll(s, cmd.out_roll_id, :out_roll_not_registered),
         %{} = in_roll <- find_roll(s, cmd.in_roll_id, :in_roll_not_registered),
         :ok <- reject(cmd.out_roll_id == cmd.in_roll_id, :same_roll_changeover),
         :ok <- roll_usable(out_roll, :out_roll_label_unresolved),
         :ok <- roll_usable(in_roll, :in_roll_label_unresolved),
         :ok <- expected_out_roll(s, cmd.out_roll_id),
         :ok <- validate_seq_window(cmd.seq_before, cmd.seq_after) do
      # 设备接头信号（迟报）被操作员按记录确认：关闭对应“待确认”偏差
      events =
        [
          event(:roll_changeover_confirmed, cmd, %{
            splice_seq: cmd.splice_seq,
            out_roll_id: cmd.out_roll_id,
            in_roll_id: cmd.in_roll_id,
            seq_before: cmd.seq_before,
            seq_after: cmd.seq_after,
            equipment_log_ref: cmd[:equipment_log_ref],
            interface_id: cmd[:interface_id],
            record_ref: cmd[:record_ref]
          })
        ]

      events = append_pending_splice_closure(s, events, cmd)
      events = events ++ interface_coincidence_events(s, cmd)

      {:ok, events}
    end
  end

  # 两卷并接失败（接头未形成/膜路未通过）。记录失败事实并开偏差
  # DEV-SPLICE-FAIL；失败区间成品默认隔离。若失败由设备信号先报、
  # 操作员随后按记录确认，则同时关闭“接头待确认”偏差。
  def decide({:record_splice_failure, cmd}, %State{} = s) do
    with :ok <-
           require_fields(
             [
               :batch_id,
               :operator_id,
               :occurred_at,
               :splice_seq,
               :out_roll_id,
               :attempted_in_roll_id,
               :reason
             ],
             cmd
           ),
         :ok <- require_present(s.filling, :filling_not_started),
         :ok <- reject(find_failure(s, cmd.splice_seq), :splice_failure_already_recorded),
         %{} <- find_roll(s, cmd.out_roll_id, :out_roll_not_registered),
         %{} <- find_roll(s, cmd.attempted_in_roll_id, :in_roll_not_registered) do
      dcmd = Map.put_new(cmd, :deviation_id, gen_id("dev"))

      events =
        [
          event(:splice_failure_recorded, dcmd, %{
            splice_seq: dcmd.splice_seq,
            out_roll_id: dcmd.out_roll_id,
            attempted_in_roll_id: dcmd.attempted_in_roll_id,
            seq_before: dcmd[:seq_before],
            seq_after: dcmd[:seq_after],
            reason: dcmd.reason,
            equipment_log_ref: dcmd[:equipment_log_ref],
            deviation_id: dcmd.deviation_id
          }),
          deviation_event(
            dcmd,
            :splice_failure,
            "材料卷 #{dcmd.out_roll_id} → #{dcmd.attempted_in_roll_id} 并接失败（接头序号 #{dcmd.splice_seq}）：#{dcmd.reason}",
            %{
              splice_seq: dcmd.splice_seq,
              out_roll_id: dcmd.out_roll_id,
              attempted_in_roll_id: dcmd.attempted_in_roll_id,
              equipment_log_ref: dcmd[:equipment_log_ref]
            }
          )
        ]

      # 失败确认只关闭设备“接头待确认”偏差（若有设备日志引用）
      {:ok, append_pending_splice_closure(s, events, cmd)}
    end
  end

  # 质量/生产按证据处置并接失败：`:retry`（重试并接，后续有成功换卷）、
  # `:quarantine`（区间成品隔离）、`:rework`（返工）。
  def decide({:dispose_splice_failure, cmd}, %State{} = s) do
    with :ok <-
           require_fields([:batch_id, :operator_id, :occurred_at, :splice_seq, :disposition], cmd),
         %{} = failure <- find_failure(s, cmd.splice_seq) || {:error, :splice_failure_not_found},
         :ok <- reject(failure.status == :disposed, :splice_failure_already_disposed),
         :ok <- validate_disposition(cmd.disposition) do
      events =
        [
          event(:splice_failure_disposed, cmd, %{
            splice_seq: cmd.splice_seq,
            disposition: cmd.disposition,
            detail: cmd[:detail]
          }),
          close_event(cmd, failure.deviation_id, cmd[:detail] || "按证据处置并接失败 #{cmd.splice_seq}")
        ]

      {:ok, events}
    end
  end

  # 接头区间**逐段**复核（不允许整批一并放行）：
  #
  # * `:accept` 接受该段：要求该接头区间已登记接头样、
  # 叠加的产品界面去向已澄清、材料卷标签无未关闭异常；
  # * `:reject` 拒绝/隔离该段成品（不需要接头样）。
  def decide({:review_splice_segment, cmd}, %State{} = s) do
    with :ok <-
           require_fields([:batch_id, :operator_id, :occurred_at, :splice_seq, :disposition], cmd),
         :ok <- reject(cmd[:whole_batch] == true, :whole_batch_release_not_allowed),
         %{} = co <- find_changeover(s, cmd.splice_seq) || {:error, :splice_not_found},
         :ok <- reject(co.reviewed, :splice_segment_already_reviewed),
         :ok <- validate_segment_disposition(cmd.disposition) do
      if cmd.disposition == :accept do
        with :ok <- segment_sample_present(s, co),
             :ok <- segment_interface_resolved(s, co),
             :ok <- segment_rolls_resolved(s, co) do
          {:ok, [review_event(cmd)]}
        end
      else
        {:ok, [review_event(cmd)]}
      end
    end
  end

  ## 样品 -----------------------------------------------------------------

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
      # 商业无菌样品需在灌装开始之后登记；接头样需在灌装开始且存在接头事实后登记
      :ok =
        cond do
          cmd.sample_type in [:commercial_sterility, :incubation] and is_nil(s.filling) ->
            {:error, :filling_not_started}

          cmd.sample_type == :splice and is_nil(s.filling) ->
            {:error, :filling_not_started}

          true ->
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

  ## 包装材料卷 / 接头辅助

  defp find_roll(s, roll_id, reason) do
    case Map.get(s.rolls, roll_id) do
      nil -> {:error, reason}
      roll -> roll
    end
  end

  defp find_changeover(s, splice_seq),
    do: Enum.find(s.changeovers, &(&1.splice_seq == splice_seq))

  defp find_failure(s, splice_seq),
    do: Enum.find(s.splice_failures, &(&1.splice_seq == splice_seq))

  defp roll_usable(roll, reason) do
    if roll.label_status == :verified, do: :ok, else: {:error, reason}
  end

  # 换下卷必须是当前在用卷（防止按错批次记录/错序确认）
  defp expected_out_roll(s, out_roll_id) do
    case s.current_roll_id do
      nil ->
        :ok

      current ->
        if current == out_roll_id, do: :ok, else: {:error, {:out_roll_not_current, current}}
    end
  end

  defp validate_seq_window(before_seq, after_seq) do
    cond do
      not is_integer(before_seq) or not is_integer(after_seq) ->
        {:error, :seq_must_be_integer}

      before_seq < 0 or after_seq < 0 ->
        {:error, :seq_must_be_non_negative}

      after_seq < before_seq ->
        {:error, :seq_after_before_before}

      true ->
        :ok
    end
  end

  defp validate_disposition(d) when d in [:retry, :quarantine, :rework], do: :ok
  defp validate_disposition(_), do: {:error, :invalid_failure_disposition}

  defp validate_segment_disposition(d) when d in [:accept, :reject], do: :ok
  defp validate_segment_disposition(_), do: {:error, :invalid_segment_disposition}

  defp review_event(cmd) do
    event(:splice_segment_reviewed, cmd, %{
      splice_seq: cmd.splice_seq,
      disposition: cmd.disposition,
      note: cmd[:note]
    })
  end

  # 设备接头信号（迟报）待确认偏差：操作员确认换卷/失败事实时自动关闭
  defp append_pending_splice_closure(s, events, cmd) do
    case open_deviation(s, :equipment_splice_unconfirmed, cmd[:equipment_log_ref]) do
      nil ->
        events

      d ->
        events ++
          [
            close_event(
              cmd,
              d.id,
              "操作员按批准记录确认设备接头信号 #{cmd[:equipment_log_ref] || ""}（接头序号 #{cmd.splice_seq}）"
            )
          ]
    end
  end

  # 卷切换恰逢产品界面：显式引用界面，或按时间窗自动识别。
  # 叠加区间的产品界面未澄清前，该接头段不得复核接受。
  defp interface_coincidence_events(s, cmd) do
    window = cmd[:interface_window_seconds] || 300

    coincident =
      case cmd[:interface_id] do
        id when id in [nil, ""] ->
          Enum.filter(s.interfaces, fn i ->
            abs(DateTime.diff(i.at, cmd.occurred_at, :second)) <= window
          end)

        id ->
          case Enum.find(s.interfaces, &(&1.id == id)) do
            nil -> []
            iface -> [iface]
          end
      end

    Enum.flat_map(coincident, fn iface ->
      cond do
        # 去向已澄清：不构成偏差（界面身份已在接头事实上关联）
        iface.status == :declared and iface.destination not in [nil, "", "unknown", :unknown] ->
          []

        # 已存在同一接头/界面的开放偏差：不重复开
        already_open?(s, iface.id, cmd.splice_seq) ->
          []

        true ->
          [
            deviation_event(
              cmd,
              :splice_coincides_interface,
              "材料卷切换（接头序号 #{cmd.splice_seq}）与产品界面 #{iface.id} 时间重叠，界面去向澄清前该接头段禁止接受",
              %{
                splice_seq: cmd.splice_seq,
                interface_id: iface.id,
                out_roll_id: cmd.out_roll_id,
                in_roll_id: cmd.in_roll_id
              }
            )
          ]
      end
    end)
  end

  defp already_open?(s, interface_id, splice_seq) do
    code = deviation_code(:splice_coincides_interface)

    Enum.any?(State.open_deviations(s), fn d ->
      d.code == code and
        get_in(d.context, [:interface_id]) == interface_id and
        get_in(d.context, [:splice_seq]) == splice_seq
    end)
  end

  # 接头段接受：该段必须有接头样（谱系引用接头确认事件）
  defp segment_sample_present(s, co) do
    if State.splice_sample_registered?(s, co.event_id),
      do: :ok,
      else: {:error, {:splice_sample_missing, co.splice_seq}}
  end

  # 接头段接受：叠加的产品界面去向必须已澄清（对应偏差已关闭）
  defp segment_interface_resolved(s, co) do
    code = deviation_code(:splice_coincides_interface)

    unresolved =
      s.deviations
      |> Map.values()
      |> Enum.filter(&(&1.status == :open and &1.code == code))
      |> Enum.filter(&(get_in(&1.context, [:splice_seq]) == co.splice_seq))

    if unresolved == [],
      do: :ok,
      else: {:error, {:interface_unresolved_for_splice, co.splice_seq}}
  end

  # 接头段接受：两卷标签均已核实
  defp segment_rolls_resolved(s, co) do
    rolls = [Map.get(s.rolls, co.out_roll_id), Map.get(s.rolls, co.in_roll_id)]

    if Enum.all?(rolls, &(not is_nil(&1) and &1.label_status == :verified)),
      do: :ok,
      else: {:error, {:roll_label_unresolved_for_splice, co.splice_seq}}
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
       when type in [:commercial_sterility, :incubation, :micro, :retain, :splice],
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
