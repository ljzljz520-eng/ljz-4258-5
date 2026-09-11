defmodule UhtBatch.Domain.Checks do
  @moduledoc """
  平台侧核查（只读、只判定，不控制设备）：

  1. 界面段：上批底液身份、产品界面去向；
  2. 时间链：顺序、补传倒置、灌装线短停开合；
  3. 样品谱系：商业无菌样品齐备且谱系可回溯到本批链事实。
  """

  alias UhtBatch.Domain.{Decide, State}

  @type finding :: %{
          code: String.t(),
          severity: :block | :warning,
          message: String.t(),
          scope: :production | :quality | :both
        }

  @doc "全部发现（含警告）。"
  def all(%State{} = s, policy \\ %{}) do
    [
      pretreatment_before_heat(s),
      heel_identity(s),
      open_interfaces(s),
      interface_resolved_after_filling(s),
      backfill_order(s),
      unconfirmed_equipment_stops(s),
      open_filling_stops(s),
      sterility_samples(s, policy),
      sample_lineage(s),
      chronology(s),
      roll_label_mismatches(s),
      unconfirmed_equipment_splices(s),
      open_splice_failures(s),
      splice_interface_overlaps(s),
      pending_splice_segments(s),
      splice_segment_samples(s),
      rejected_splice_segments(s)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  @doc "签署门禁：生产=所有 :production/:both block；质量=全部 block。"
  def blockers_for(role, %State{} = s, policy \\ %{}) do
    s
    |> all(policy)
    |> Enum.filter(&(&1.severity == :block))
    |> Enum.filter(&(&1.scope in [role, :both]))
  end

  ## 1. 预处理必须先于热处理通过
  defp pretreatment_before_heat(s) do
    cond do
      is_nil(s.heat_pass) ->
        nil

      is_nil(s.pretreatment) ->
        block("DEV-HEAT-NO-PRE", "热处理通过缺少预处理确认", :both)

      DateTime.compare(s.pretreatment.at, s.heat_pass.at) == :gt ->
        block("DEV-TIME-PRE-HEAT", "预处理确认时间晚于热处理通过时间", :both)

      true ->
        nil
    end
  end

  ## 2a. 上批底液身份不明
  defp heel_identity(s) do
    case find_open(s, Decide.deviation_code(:heel_identity_unknown)) do
      nil ->
        nil

      d ->
        block(d.code, "无菌罐含上批底液，上批身份未确认：#{d.reason}", :both)
    end
  end

  ## 2b. 产品界面去向不明
  defp open_interfaces(s) do
    case find_open(s, Decide.deviation_code(:interface_destination_unknown)) do
      nil ->
        nil

      d ->
        block(d.code, "存在去向不明的产品界面：#{d.reason}", :both)
    end
  end

  ## 2c. 界面在灌装开始之后才澄清（应在灌装前明确去向）
  defp interface_resolved_after_filling(s) do
    if s.filling do
      late =
        s.interfaces
        |> Enum.filter(&(&1.status == :declared))
        |> Enum.filter(&(DateTime.compare(&1.at, s.filling.at) == :gt))

      if late != [] do
        warn("DEV-IFACE-LATE", "#{length(late)} 个产品界面在灌装开始后才声明去向", :both)
      end
    end
  end

  ## 3a. 补传导致事件顺序改变且未确认
  defp backfill_order(s) do
    s
    |> State.unacknowledged_backfills()
    |> Enum.map(fn a ->
      block("DEV-BACKFILL-ORDER", "设备日志补传改变事件顺序且未经操作员确认：#{a.detail}", :both)
    end)
  end

  ## 3b. 设备报告的短停未由操作员确认成事实
  defp unconfirmed_equipment_stops(s) do
    case find_open(s, Decide.deviation_code(:equipment_short_stop_unconfirmed)) do
      nil ->
        nil

      d ->
        block(d.code, "设备报告的灌装线短停尚未经操作员确认：#{d.reason}", :both)
    end
  end

  ## 3c. 灌装线短停尚未恢复
  defp open_filling_stops(s) do
    s.stops
    |> Enum.filter(&is_nil(&1.resumed_at))
    |> Enum.map(fn stop ->
      block(
        "DEV-STOP-OPEN",
        "灌装线短停（#{stop.reason}）开始于 #{DateTime.to_iso8601(stop.at)} 且尚未恢复",
        :both
      )
    end)
  end

  ## 4a. 商业无菌样品齐备
  defp sterility_samples(s, policy) do
    required = Map.get(policy, :commercial_sterility_samples, 1)

    if s.filling do
      valid =
        s.samples
        |> Map.values()
        |> Enum.count(&(&1.sample_type == :commercial_sterility and &1.status == :registered))

      if valid < required do
        block("DEV-SAMPLE-MISSING", "商业无菌样品数量不足：#{valid}/#{required}", :quality)
      end
    end
  end

  ## 4b. 样品谱系必须衔接本批链事实，且登记时间不早于所引用事实
  defp sample_lineage(s) do
    by_id = Map.new(s.chain_events, &{&1.id, &1})

    s.samples
    |> Map.values()
    |> Enum.filter(&(&1.status == :registered))
    |> Enum.flat_map(fn sample ->
      cond do
        sample.lineage == [] and sample.sample_type == :commercial_sterility ->
          [block("DEV-SAMPLE-LINEAGE", "商业无菌样品 #{sample.sample_no} 缺少谱系引用", :quality)]

        sample.lineage == [] ->
          []

        true ->
          missing = Enum.reject(sample.lineage, &Map.has_key?(by_id, &1))

          cond do
            missing != [] ->
              [
                block(
                  "DEV-SAMPLE-LINEAGE",
                  "样品 #{sample.sample_no} 谱系引用不存在的链事件 #{inspect(missing)}",
                  :quality
                )
              ]

            true ->
              earliest =
                sample.lineage
                |> Enum.map(&by_id[&1].occurred_at)
                |> Enum.min(DateTime)

              if DateTime.compare(earliest, sample.at) == :gt do
                [
                  block(
                    "DEV-SAMPLE-LINEAGE-TIME",
                    "样品 #{sample.sample_no} 登记时间早于其谱系源头事件",
                    :quality
                  )
                ]
              else
                []
              end
          end
      end
    end)
  end

  ## 5. 链上事实的基本时序（发生时间单调；倒置已由 backfill_order 覆盖，
  ## 这里给出警告级别的时间统计，便于工位页面呈现）
  defp chronology(s) do
    chain = s.chain_events

    out_of_order =
      chain
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] ->
        DateTime.compare(a.occurred_at, b.occurred_at) == :gt
      end)

    if out_of_order > 0 do
      warn("DEV-CHAIN-REORDER", "写入流中有 #{out_of_order} 处发生时间倒置（以补传异常列表为准）", :both)
    end
  end

  ## 6a. 包装材料卷标签错（未核实关闭前阻断）
  defp roll_label_mismatches(s) do
    case find_open(s, Decide.deviation_code(:roll_label_mismatch)) do
      nil ->
        # 也覆盖“卷状态仍是 mismatch 但偏差未列出”的防御性场景
        case State.label_mismatched_rolls(s) do
          [] -> nil
          _ -> block("DEV-ROLL-LABEL", "存在标签异常且未核实的包装材料卷", :both)
        end

      d ->
        block(d.code, "包装材料卷标签异常未关闭：#{d.reason}", :both)
    end
  end

  ## 6b. 设备接头传感器信号未经操作员确认（迟报信号本身不得自动成事实）
  defp unconfirmed_equipment_splices(s) do
    case find_open(s, Decide.deviation_code(:equipment_splice_unconfirmed)) do
      nil ->
        nil

      d ->
        block(d.code, "设备报告的接头信号尚未经操作员确认：#{d.reason}", :both)
    end
  end

  ## 6c. 两卷并接失败未处置
  defp open_splice_failures(s) do
    s
    |> State.open_splice_failures()
    |> Enum.map(fn f ->
      block(
        "DEV-SPLICE-FAIL",
        "接头序号 #{f.splice_seq}（#{f.out_roll_id} → #{f.attempted_in_roll_id}）并接失败未处置：#{f.reason}",
        :both
      )
    end)
  end

  ## 6d. 卷切换恰逢产品界面，界面去向未澄清前接头段不得接受
  defp splice_interface_overlaps(s) do
    code = Decide.deviation_code(:splice_coincides_interface)

    s.deviations
    |> Map.values()
    |> Enum.filter(&(&1.status == :open and &1.code == code))
    |> Enum.map(fn d ->
      block(
        code,
        "接头序号 #{d.context[:splice_seq]} 与产品界面 #{d.context[:interface_id]} 重叠且去向未澄清：#{d.reason}",
        :both
      )
    end)
  end

  ## 6e. 接头区间默认待复核：逐段复核前，不能沿用整批放行
  defp pending_splice_segments(s) do
    s
    |> State.pending_splice_segments()
    |> Enum.map(fn co ->
      block(
        "DEV-SPLICE-PENDING",
        "材料卷 #{co.out_roll_id} → #{co.in_roll_id} 的接头区间" <>
          "（序号 #{co.seq_before}–#{co.seq_after}）尚未逐段复核，不得随整批放行",
        :quality
      )
    end)
  end

  ## 6f. 每个接头区间必须有接头样（谱系引用该接头确认事件）
  defp splice_segment_samples(s) do
    s.changeovers
    |> Enum.filter(fn co ->
      not (co.reviewed == true and co.disposition == :reject)
    end)
    |> Enum.reject(&State.splice_sample_registered?(s, &1.event_id))
    |> Enum.map(fn co ->
      block(
        "DEV-SPLICE-SAMPLE-MISSING",
        "接头序号 #{co.splice_seq} 的区间缺少接头样（谱系须引用接头确认事件 #{co.event_id}）",
        :quality
      )
    end)
  end

  ## 6g. 已复核拒绝/隔离的接头区间：仅警告并列出隔离序列号
  defp rejected_splice_segments(s) do
    s
    |> State.rejected_splice_segments()
    |> Enum.map(fn co ->
      warn(
        "DEV-SPLICE-SEG-QUARANTINE",
        "接头序号 #{co.splice_seq} 区间（序号 #{co.seq_before}–#{co.seq_after}）已判隔离，不随本批放行",
        :quality
      )
    end)
  end

  defp find_open(s, code) do
    s.deviations
    |> Map.values()
    |> Enum.find(&(&1.status == :open and &1.code == code))
  end

  defp block(code, msg, scope), do: %{code: code, severity: :block, message: msg, scope: scope}
  defp warn(code, msg, scope), do: %{code: code, severity: :warning, message: msg, scope: scope}
end
