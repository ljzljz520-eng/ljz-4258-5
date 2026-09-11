defmodule UhtBatch.PackRollChangeoverTest do
  use UhtBatch.DataCase, async: false

  alias UhtBatch.Service
  alias UhtBatch.Domain.State
  alias UhtBatch.Integrations.FakeAttestation

  @prod_cred FakeAttestation.credential_for_role(:production)
  @qa_cred FakeAttestation.credential_for_role(:quality)

  # 建立：预处理 → 热处理 → 转罐 → 灌装，并登记首卷/第二卷（默认均已核对标签）
  defp chain_with_two_rolls(batch, opts, second_opts \\ []) do
    {:ok, _} = establish_chain(batch, opts)

    assert {:ok, _} =
             Service.submit(:register_pack_roll, Factory.pack_roll(batch, "ROLL-A"), opts)

    assert {:ok, _} =
             Service.submit(
               :register_pack_roll,
               Factory.pack_roll(batch, "ROLL-B", second_opts),
               opts
             )
  end

  defp splice_sample(batch, no, changeover_event_id, at \\ ~U[2026-09-10T10:45:00Z]) do
    Factory.sample(batch, no, [changeover_event_id], type: :splice, at: at)
  end

  defp find_event(events, type), do: Enum.find(events, &(&1.type == type))

  defp open_dev(state, code) do
    state.deviations |> Map.values() |> Enum.find(&(&1.code == code and &1.status == :open))
  end

  defp ack_open_anomalies(batch, _state, opts, at \\ ~U[2026-09-10T12:05:00Z]) do
    %{state: fresh} = snapshot(batch, opts)

    refs =
      fresh.backfill_anomalies
      |> Enum.reject(& &1.acknowledged)
      |> Enum.map(&{&1.inserted_event_id, &1.prior_event_id})

    if refs != [] do
      {:ok, _} =
        Service.submit(
          :acknowledge_backfill,
          %{batch_id: batch, operator_id: "op.101", occurred_at: at, anomaly_refs: refs},
          opts
        )
    end
  end

  defp review_accept(batch, seq, at \\ ~U[2026-09-10T11:40:00Z]) do
    %{
      batch_id: batch,
      operator_id: "qa.02",
      occurred_at: at,
      splice_seq: seq,
      disposition: :accept,
      note: "接头段外观与密封性检查合格"
    }
  end

  defp snapshot(batch, opts), do: Service.snapshot(batch, opts) |> then(fn {:ok, s} -> s end)

  # 正向基线：无换卷时首卷覆盖全部序列区间，且不产生接头相关偏差
  test "基线：无换卷——首卷区间 0..开放端，无待复核接头段，可整批放行", %{opts: opts} do
    batch = Factory.batch_id()
    {:ok, _} = establish_chain(batch, opts)

    assert {:ok, _} =
             Service.submit(:register_pack_roll, Factory.pack_roll(batch, "ONLY-ROLL"), opts)

    %{state: state, findings: findings} = snapshot(batch, opts)

    assert [%{roll_id: "ONLY-ROLL", from_seq: 0, to_seq: nil, kind: :roll_run}] =
             State.roll_intervals(state)

    assert State.pending_splice_segments(state) == []
    refute Enum.any?(findings, &(&1.code in ["DEV-SPLICE-PENDING", "DEV-ROLL-LABEL"]))
  end

  # 场景 1：材料卷标签错
  test "场景1：材料卷标签错——开偏差阻断换卷与放行，核实重贴关闭后方可换卷", %{opts: opts} do
    batch = Factory.batch_id()

    chain_with_two_rolls(batch, opts,
      label: "LAMI-FILM-TBA-250(应为200)",
      label_verified: false
    )

    %{state: state} = snap = snapshot(batch, opts)
    assert Enum.any?(snap.findings, &(&1.code == "DEV-ROLL-LABEL" and &1.scope == :both))
    assert [%{roll_id: "ROLL-B"}] = State.label_mismatched_rolls(state)

    # 标签未核实：换卷被拒
    co = Factory.changeover(batch, "ROLL-A", "ROLL-B", 1)

    assert {:error, :in_roll_label_unresolved} =
             Service.submit(:confirm_roll_changeover, co, opts)

    # 同卷重复登记也被拒
    assert {:error, :roll_already_registered} =
             Service.submit(
               :register_pack_roll,
               Factory.pack_roll(batch, "ROLL-B", at: ~U[2026-09-10T10:34:00Z]),
               opts
             )

    # 质量核实、重贴标签并关闭偏差
    dev = open_dev(state, "DEV-ROLL-LABEL")

    assert {:ok, _} =
             Service.submit(
               :close_deviation,
               %{
                 batch_id: batch,
                 operator_id: "qa.02",
                 occurred_at: ~U[2026-09-10T10:35:00Z],
                 deviation_id: dev.id,
                 disposition: "实物核对为 TBA-200，重贴正确标签后允许上线"
               },
               opts
             )

    %{state: state2} = snapshot(batch, opts)
    assert State.label_mismatched_rolls(state2) == []
    assert get_in(state2.rolls, ["ROLL-B", :label_status]) == :verified

    # 换卷成功：接头区间默认待复核，卷-成品序列区间可推导
    assert {:ok, evs} = Service.submit(:confirm_roll_changeover, co, opts)
    co_ev = find_event(evs, :roll_changeover_confirmed)
    assert co_ev.payload.splice_seq == 1

    %{state: state3} = snapshot(batch, opts)
    [zone] = State.pending_splice_segments(state3)
    assert zone.out_roll_id == "ROLL-A" and zone.in_roll_id == "ROLL-B"
    assert {zone.seq_before, zone.seq_after} == {12_000, 12_020}
    assert state3.current_roll_id == "ROLL-B"

    intervals = State.roll_intervals(state3)
    runs = Enum.filter(intervals, &(&1.kind == :roll_run))

    assert [
             %{roll_id: "ROLL-A", from_seq: 0, to_seq: 12_000},
             %{roll_id: "ROLL-B", from_seq: 12_020, to_seq: nil}
           ] = runs
  end

  # 场景 2：接头传感器迟报
  test "场景2：接头传感器迟报——待确认偏差+补传倒置，人工确认与逐段复核后才能放行", %{opts: opts} do
    batch = Factory.batch_id()
    chain_with_two_rolls(batch, opts)

    # 灌装正常推进到 11:20（以一次恢复后的商业无菌样时间代表链末端推进）
    # 设备接头信号迟报：实际发生 10:39，平台 12:00 才收到
    payload = %{
      "batch_id" => batch,
      "status" => "splice_detected",
      "occurred_at" => "2026-09-10T10:39:00Z",
      "log_ref" => "EQ-LOG-SPLICE-LATE",
      "splice_seq" => 1,
      "out_roll_id" => "ROLL-A",
      "in_roll_id" => "ROLL-B"
    }

    assert {:ok, stored} =
             Service.ingest_equipment(
               "uht.status.packaging_splicer.SPLICER-2",
               payload,
               opts
             )

    assert length(stored) == 2
    pend = find_event(stored, :deviation_opened)
    assert pend.payload.code == "DEV-EQ-SPLICE-UNCONFIRMED"
    assert pend.payload.context.splice_seq == 1

    # 设备只读信号不构成换卷事实
    %{state: state0} = snapshot(batch, opts)
    assert state0.changeovers == []
    assert Enum.any?(state0.equipment_signals, &(&1.status == "splice_detected"))

    # 操作员按批准记录确认接头（引用设备日志），时间晚到记录于 11:20 之后补传 10:39：
    # 先推进链末端，再确认，以构造补传倒置
    assert {:ok, _} =
             Service.submit(
               :record_short_stop,
               %{
                 batch_id: batch,
                 operator_id: "op.101",
                 occurred_at: ~U[2026-09-10T11:20:00Z],
                 reason: "例行换膜准备"
               },
               opts
             )

    %{state: before} = snapshot(batch, opts)
    stop = hd(before.stops)

    assert {:ok, _} =
             Service.submit(
               :resume_line,
               %{
                 batch_id: batch,
                 operator_id: "op.101",
                 occurred_at: ~U[2026-09-10T11:25:00Z],
                 stop_event_id: stop.event_id
               },
               opts
             )

    {:ok, evs} =
      Service.submit(
        :confirm_roll_changeover,
        Factory.changeover(batch, "ROLL-A", "ROLL-B", 1,
          at: ~U[2026-09-10T10:39:30Z],
          eq_log: "EQ-LOG-SPLICE-LATE"
        ),
        opts
      )

    co_ev = find_event(evs, :roll_changeover_confirmed)
    assert co_ev
    # 设备待确认偏差被自动关闭
    assert Enum.any?(evs, &(&1.type == :deviation_closed))

    %{state: state, findings: findings} = snapshot(batch, opts)
    refute Enum.any?(findings, &(&1.code == "DEV-EQ-SPLICE-UNCONFIRMED"))
    assert Enum.any?(findings, &(&1.code == "DEV-BACKFILL-ORDER"))
    assert Enum.any?(state.backfill_anomalies, &(&1.inserted_event_id == co_ev.id))

    # 未确认补传倒置前生产签署阻断
    prod = %{challenge: :crypto.strong_rand_bytes(32), credential_id: @prod_cred}
    assert {:error, {:signoff_blocked, blockers}} = Service.sign(:production, batch, prod, opts)
    assert Enum.any?(blockers, &(&1.code == "DEV-BACKFILL-ORDER"))

    ack_open_anomalies(batch, state, opts)

    # 接头段待复核/缺接头样不阻断生产签署（生产放行不含逐段质量结论）
    assert {:ok, _} =
             Service.sign(
               :production,
               batch,
               %{challenge: :crypto.strong_rand_bytes(32), credential_id: @prod_cred},
               opts
             )

    # 接头段默认待复核且缺接头样 → 质量不能整批放行
    qa = %{challenge: :crypto.strong_rand_bytes(32), credential_id: @qa_cred}
    assert {:error, {:signoff_blocked, qb}} = Service.sign(:quality, batch, qa, opts)
    codes = Enum.map(qb, & &1.code)
    assert "DEV-SPLICE-PENDING" in codes
    assert "DEV-SPLICE-SAMPLE-MISSING" in codes

    # 补接头样（谱系引用接头确认事件）并逐段复核接受后，该段闭环
    assert {:ok, _} =
             Service.submit(
               :register_sample,
               splice_sample(batch, "SP-1", co_ev.id, ~U[2026-09-10T11:35:00Z]),
               opts
             )

    assert {:ok, _} =
             Service.submit(
               :review_splice_segment,
               review_accept(batch, 1, ~U[2026-09-10T11:40:00Z]),
               opts
             )

    %{state: state2, findings: findings2} = snapshot(batch, opts)
    assert State.pending_splice_segments(state2) == []

    refute Enum.any?(
             findings2,
             &(&1.code in [
                 "DEV-BACKFILL-ORDER",
                 "DEV-SPLICE-PENDING",
                 "DEV-SPLICE-SAMPLE-MISSING"
               ])
           )
  end

  # 场景 3：两卷并接失败
  test "场景3：两卷并接失败——失败事实+偏差阻断，区间隔离并重试成功后放行", %{opts: opts} do
    batch = Factory.batch_id()
    chain_with_two_rolls(batch, opts)

    # 设备先报 splice_failed（待操作员确认）
    payload = %{
      "batch_id" => batch,
      "status" => "splice_failed",
      "occurred_at" => "2026-09-10T10:41:00Z",
      "log_ref" => "EQ-LOG-SPLICE-FAIL-9",
      "splice_seq" => 9,
      "out_roll_id" => "ROLL-A",
      "in_roll_id" => "ROLL-B"
    }

    assert {:ok, stored} =
             Service.ingest_equipment(
               "uht.status.packaging_splicer.SPLICER-2",
               payload,
               opts
             )

    pend = find_event(stored, :deviation_opened)
    assert pend.payload.code == "DEV-EQ-SPLICE-UNCONFIRMED"

    # 操作员按记录确认并接失败：失败事实 + DEV-SPLICE-FAIL + 关闭待确认偏差
    {:ok, evs} =
      Service.submit(
        :record_splice_failure,
        %{
          batch_id: batch,
          operator_id: "op.101",
          occurred_at: ~U[2026-09-10T10:41:00Z],
          splice_seq: 9,
          out_roll_id: "ROLL-A",
          attempted_in_roll_id: "ROLL-B",
          seq_before: 12_000,
          seq_after: 12_012,
          reason: "膜路未对齐，热封失败",
          equipment_log_ref: "EQ-LOG-SPLICE-FAIL-9"
        },
        opts
      )

    assert find_event(evs, :splice_failure_recorded)
    assert find_event(evs, :deviation_closed)
    fail_dev = find_event(evs, :deviation_opened)
    assert fail_dev.payload.code == "DEV-SPLICE-FAIL"

    %{state: state, findings: findings} = snapshot(batch, opts)
    assert length(State.open_splice_failures(state)) == 1
    assert Enum.any?(findings, &(&1.code == "DEV-SPLICE-FAIL"))
    # 失败不产生接头区间，当前卷仍是 ROLL-A
    assert state.current_roll_id == "ROLL-A"
    assert state.changeovers == []

    # 未处置前双方签署阻断
    prod = %{challenge: :crypto.strong_rand_bytes(32), credential_id: @prod_cred}
    assert {:error, {:signoff_blocked, blockers}} = Service.sign(:production, batch, prod, opts)
    assert Enum.any?(blockers, &(&1.code == "DEV-SPLICE-FAIL"))

    # 同一失败序号不能重复记录
    assert {:error, :splice_failure_already_recorded} =
             Service.submit(
               :record_splice_failure,
               %{
                 batch_id: batch,
                 operator_id: "op.101",
                 occurred_at: ~U[2026-09-10T10:42:00Z],
                 splice_seq: 9,
                 out_roll_id: "ROLL-A",
                 attempted_in_roll_id: "ROLL-B",
                 reason: "重复"
               },
               opts
             )

    # 非法处置被拒
    assert {:error, :invalid_failure_disposition} =
             Service.submit(
               :dispose_splice_failure,
               %{
                 batch_id: batch,
                 operator_id: "qa.02",
                 occurred_at: ~U[2026-09-10T10:47:00Z],
                 splice_seq: 9,
                 disposition: :ship
               },
               opts
             )

    # 质量处置：区间隔离
    assert {:ok, _} =
             Service.submit(
               :dispose_splice_failure,
               %{
                 batch_id: batch,
                 operator_id: "qa.02",
                 occurred_at: ~U[2026-09-10T10:48:00Z],
                 splice_seq: 9,
                 disposition: :quarantine,
                 detail: "序号 12000–12012 区间成品隔离待评估"
               },
               opts
             )

    # 重复处置被拒
    assert {:error, :splice_failure_already_disposed} =
             Service.submit(
               :dispose_splice_failure,
               %{
                 batch_id: batch,
                 operator_id: "qa.02",
                 occurred_at: ~U[2026-09-10T10:49:00Z],
                 splice_seq: 9,
                 disposition: :retry
               },
               opts
             )

    # 重试：新接头序号并接成功
    {:ok, evs2} =
      Service.submit(
        :confirm_roll_changeover,
        Factory.changeover(batch, "ROLL-A", "ROLL-B", 10,
          at: ~U[2026-09-10T10:52:00Z],
          seq_before: 12_100,
          seq_after: 12_120
        ),
        opts
      )

    co10 = find_event(evs2, :roll_changeover_confirmed)

    %{findings: findings2} = snapshot(batch, opts)
    refute Enum.any?(findings2, &(&1.code == "DEV-SPLICE-FAIL"))

    # 成功接头段：登记接头样 + 逐段接受；失败区间不要求接头样
    assert {:ok, _} =
             Service.submit(
               :register_sample,
               splice_sample(batch, "SP-OK-10", co10.id, ~U[2026-09-10T10:55:00Z]),
               opts
             )

    assert {:ok, _} =
             Service.submit(
               :review_splice_segment,
               review_accept(batch, 10, ~U[2026-09-10T11:00:00Z])
               |> Map.put(:note, "重试接头合格"),
               opts
             )

    %{state: state2, findings: findings3} = snapshot(batch, opts)
    failure = hd(state2.splice_failures)
    assert failure.status == :disposed and failure.disposition == :quarantine
    refute Enum.any?(findings3, &(&1.code == "DEV-SPLICE-FAIL"))
    assert State.pending_splice_segments(state2) == []
  end

  # 场景 4：接头段样品缺失
  test "场景4：接头段缺接头样——阻断逐段接受与质量放行，补样后方可复核", %{opts: opts} do
    batch = Factory.batch_id()
    chain_with_two_rolls(batch, opts)

    {:ok, evs} =
      Service.submit(
        :confirm_roll_changeover,
        Factory.changeover(batch, "ROLL-A", "ROLL-B", 1),
        opts
      )

    co = find_event(evs, :roll_changeover_confirmed)

    rev = review_accept(batch, 1, ~U[2026-09-10T10:50:00Z])

    # 未登记接头样：逐段接受被拒
    assert {:error, {:splice_sample_missing, 1}} =
             Service.submit(:review_splice_segment, rev, opts)

    %{findings: findings} = snapshot(batch, opts)
    assert Enum.any?(findings, &(&1.code == "DEV-SPLICE-SAMPLE-MISSING"))
    assert Enum.any?(findings, &(&1.code == "DEV-SPLICE-PENDING"))

    # 生产签署可通过（待复核/接头样属质量门禁），质量签署被阻断
    assert {:ok, _} =
             Service.sign(
               :production,
               batch,
               %{challenge: :crypto.strong_rand_bytes(32), credential_id: @prod_cred},
               opts
             )

    qa = %{challenge: :crypto.strong_rand_bytes(32), credential_id: @qa_cred}
    assert {:error, {:signoff_blocked, blockers}} = Service.sign(:quality, batch, qa, opts)
    assert Enum.any?(blockers, &(&1.code == "DEV-SPLICE-SAMPLE-MISSING"))

    # 接头样谱系必须引用本接头确认事件：登记后可接受
    assert {:ok, _} =
             Service.submit(:register_sample, splice_sample(batch, "SP-JOINT-1", co.id), opts)

    assert {:ok, review_evs} =
             Service.submit(
               :review_splice_segment,
               %{rev | note: "接头段合格"},
               opts
             )

    assert find_event(review_evs, :splice_segment_reviewed)

    %{state: state, findings: findings2} = snapshot(batch, opts)
    assert State.pending_splice_segments(state) == []
    refute Enum.any?(findings2, &(&1.code in ["DEV-SPLICE-PENDING", "DEV-SPLICE-SAMPLE-MISSING"]))
  end

  test "场景4b：接头样登记时间早于接头时点，被谱系时间核查阻断", %{opts: opts} do
    batch = Factory.batch_id()
    chain_with_two_rolls(batch, opts)

    {:ok, evs} =
      Service.submit(
        :confirm_roll_changeover,
        Factory.changeover(batch, "ROLL-A", "ROLL-B", 1, at: ~U[2026-09-10T10:40:00Z]),
        opts
      )

    co = find_event(evs, :roll_changeover_confirmed)

    assert {:ok, _} =
             Service.submit(
               :register_sample,
               Factory.sample(batch, "SP-EARLY", [co.id],
                 type: :splice,
                 at: ~U[2026-09-10T10:05:00Z]
               ),
               opts
             )

    %{findings: findings} = snapshot(batch, opts)
    assert Enum.any?(findings, &(&1.code == "DEV-SAMPLE-LINEAGE-TIME"))
  end

  # 场景 5：卷切换恰逢产品界面
  test "场景5：换卷恰逢去向不明界面——双偏差叠加，澄清界面后该接头段才可接受", %{opts: opts} do
    batch = Factory.batch_id()
    chain_with_two_rolls(batch, opts)

    # 产品界面去向不明（10:38 声明）
    unknown = %{
      batch_id: batch,
      operator_id: "op.101",
      occurred_at: ~U[2026-09-10T10:38:00Z],
      interface_id: "IF-SPLICE-1",
      product_a: "UHT-WHOLE-MILK-3.5",
      product_b: "UHT-CHOCO"
    }

    {:ok, iface_evs} = Service.submit(:declare_interface, unknown, opts)
    iface_dev = find_event(iface_evs, :deviation_opened)
    assert iface_dev.payload.code == "DEV-IFACE-UNKNOWN"

    # 10:40 换卷，与界面时点重叠（默认 ±300s 窗）
    {:ok, co_evs} =
      Service.submit(
        :confirm_roll_changeover,
        Factory.changeover(batch, "ROLL-A", "ROLL-B", 1, at: ~U[2026-09-10T10:40:00Z]),
        opts
      )

    co = find_event(co_evs, :roll_changeover_confirmed)
    overlap_dev = find_event(co_evs, :deviation_opened)
    assert overlap_dev.payload.code == "DEV-ROLL-IFACE"
    assert overlap_dev.payload.context.interface_id == "IF-SPLICE-1"
    assert overlap_dev.payload.context.splice_seq == 1

    # 即便登记了接头样，界面未澄清前该接头段不能接受
    assert {:ok, _} =
             Service.submit(:register_sample, splice_sample(batch, "SP-1", co.id), opts)

    rev = review_accept(batch, 1, ~U[2026-09-10T11:00:00Z])

    assert {:error, {:interface_unresolved_for_splice, 1}} =
             Service.submit(:review_splice_segment, rev, opts)

    %{findings: findings} = snapshot(batch, opts)
    assert Enum.any?(findings, &(&1.code == "DEV-ROLL-IFACE"))

    # 澄清界面去向（同一界面 ID 重新声明，视图合并）
    declared = %{
      batch_id: batch,
      operator_id: "op.101",
      occurred_at: ~U[2026-09-10T10:55:00Z],
      interface_id: "IF-SPLICE-1",
      product_a: "UHT-WHOLE-MILK-3.5",
      product_b: "UHT-CHOCO",
      destination: "rework-tank-RW-2"
    }

    assert {:ok, _} = Service.submit(:declare_interface, declared, opts)

    assert {:ok, _} =
             Service.submit(
               :close_deviation,
               %{
                 batch_id: batch,
                 operator_id: "qa.02",
                 occurred_at: ~U[2026-09-10T10:56:00Z],
                 deviation_id: iface_dev.payload.deviation_id,
                 disposition: "追踪确认界面段进入返工罐 RW-2"
               },
               opts
             )

    assert {:ok, _} =
             Service.submit(
               :close_deviation,
               %{
                 batch_id: batch,
                 operator_id: "qa.02",
                 occurred_at: ~U[2026-09-10T10:56:00Z],
                 deviation_id: overlap_dev.payload.deviation_id,
                 disposition: "界面去向已澄清，接头段可复核"
               },
               opts
             )

    assert {:ok, review_evs} =
             Service.submit(
               :review_splice_segment,
               %{rev | note: "界面已澄清，接头段合格"},
               opts
             )

    assert find_event(review_evs, :splice_segment_reviewed)

    %{state: state, findings: findings2} = snapshot(batch, opts)
    assert State.pending_splice_segments(state) == []
    refute Enum.any?(findings2, &(&1.code in ["DEV-ROLL-IFACE", "DEV-SPLICE-PENDING"]))
  end

  test "场景5b：换卷时界面去向已澄清，不产生 DEV-ROLL-IFACE；显式引用同然", %{opts: opts} do
    batch = Factory.batch_id()

    {:ok, _} = Service.submit(:confirm_pretreatment, Factory.pretreatment(batch), opts)
    {:ok, _} = Service.submit(:confirm_heat_pass, Factory.heat_pass(batch), opts)
    {:ok, _} = Service.submit(:transfer_to_tank, Factory.transfer(batch), opts)

    iface = %{
      batch_id: batch,
      operator_id: "op.101",
      occurred_at: ~U[2026-09-10T09:40:00Z],
      interface_id: "IF-EARLY",
      product_a: "UHT-WHOLE-MILK-3.5",
      product_b: "UHT-CHOCO",
      destination: "rework-tank-RW-2"
    }

    assert {:ok, _} = Service.submit(:declare_interface, iface, opts)
    assert {:ok, _} = Service.submit(:start_filling, Factory.filling(batch), opts)
    assert {:ok, _} = Service.submit(:register_pack_roll, Factory.pack_roll(batch, "RA"), opts)
    assert {:ok, _} = Service.submit(:register_pack_roll, Factory.pack_roll(batch, "RB"), opts)

    # 09:40 的界面与 10:40 的换卷超出 ±300s 自动识别窗
    {:ok, evs} =
      Service.submit(
        :confirm_roll_changeover,
        Factory.changeover(batch, "RA", "RB", 1, at: ~U[2026-09-10T10:40:00Z]),
        opts
      )

    refute Enum.any?(evs, &(&1.type == :deviation_opened))

    # 显式引用该已澄清界面：同样不产生偏差
    {:ok, evs2} =
      Service.submit(
        :confirm_roll_changeover,
        Factory.changeover(batch, "RB", "RA", 2,
          at: ~U[2026-09-10T11:10:00Z],
          interface_id: "IF-EARLY",
          seq_before: 20_000,
          seq_after: 20_020
        ),
        opts
      )

    refute Enum.any?(evs2, &(&1.type == :deviation_opened))
  end

  test "规则：整批一并复核被拒；拒绝段隔离、无需接头样且不可重复复核", %{opts: opts} do
    batch = Factory.batch_id()
    chain_with_two_rolls(batch, opts)

    {:ok, _} =
      Service.submit(
        :confirm_roll_changeover,
        Factory.changeover(batch, "ROLL-A", "ROLL-B", 1),
        opts
      )

    assert {:error, :whole_batch_release_not_allowed} =
             Service.submit(
               :review_splice_segment,
               %{
                 batch_id: batch,
                 operator_id: "qa.02",
                 occurred_at: ~U[2026-09-10T10:50:00Z],
                 splice_seq: 1,
                 disposition: :accept,
                 whole_batch: true
               },
               opts
             )

    # 无接头样时可判该段拒绝/隔离
    assert {:ok, evs} =
             Service.submit(
               :review_splice_segment,
               %{
                 batch_id: batch,
                 operator_id: "qa.02",
                 occurred_at: ~U[2026-09-10T10:50:00Z],
                 splice_seq: 1,
                 disposition: :reject,
                 note: "接头段外观异常，序号 12000–12020 隔离"
               },
               opts
             )

    assert find_event(evs, :splice_segment_reviewed)

    %{state: state, findings: findings} = snapshot(batch, opts)
    assert State.pending_splice_segments(state) == []
    assert length(State.rejected_splice_segments(state)) == 1
    refute Enum.any?(findings, &(&1.code == "DEV-SPLICE-SAMPLE-MISSING"))

    assert Enum.any?(
             findings,
             &(&1.code == "DEV-SPLICE-SEG-QUARANTINE" and &1.severity == :warning)
           )

    assert {:error, :splice_segment_already_reviewed} =
             Service.submit(
               :review_splice_segment,
               review_accept(batch, 1, ~U[2026-09-10T10:51:00Z]),
               opts
             )
  end

  test "规则：换卷须在灌装开始后、序号窗合法、换下卷须为当前卷", %{opts: opts} do
    batch = Factory.batch_id()
    {:ok, _} = Service.submit(:confirm_pretreatment, Factory.pretreatment(batch), opts)
    {:ok, _} = Service.submit(:confirm_heat_pass, Factory.heat_pass(batch), opts)
    {:ok, _} = Service.submit(:register_pack_roll, Factory.pack_roll(batch, "ROLL-A"), opts)
    {:ok, _} = Service.submit(:register_pack_roll, Factory.pack_roll(batch, "ROLL-B"), opts)

    co = Factory.changeover(batch, "ROLL-A", "ROLL-B", 1)

    # 灌装未开始
    assert {:error, :filling_not_started} =
             Service.submit(:confirm_roll_changeover, co, opts)

    {:ok, _} = Service.submit(:transfer_to_tank, Factory.transfer(batch), opts)
    assert {:ok, _} = Service.submit(:start_filling, Factory.filling(batch), opts)

    # 序列号倒挂
    bad_seq = %{co | seq_before: 100, seq_after: 50}

    assert {:error, :seq_after_before_before} =
             Service.submit(:confirm_roll_changeover, bad_seq, opts)

    # 同卷自切
    same = %{co | out_roll_id: "ROLL-A", in_roll_id: "ROLL-A"}

    assert {:error, :same_roll_changeover} =
             Service.submit(:confirm_roll_changeover, same, opts)

    # 未登记的卷
    assert {:error, :in_roll_not_registered} =
             Service.submit(
               :confirm_roll_changeover,
               %{co | in_roll_id: "ROLL-GHOST"},
               opts
             )
  end

  test "安全：设备接头通道拒绝控制字段", %{opts: opts} do
    batch = Factory.batch_id()

    assert {:error, {:control_field_rejected, "command"}} =
             Service.ingest_equipment(
               "uht.status.packaging_splicer.SPLICER-2",
               %{
                 "batch_id" => batch,
                 "status" => "splice_detected",
                 "splice_seq" => 3,
                 "command" => "actuate_splicer"
               },
               opts
             )
  end
end
