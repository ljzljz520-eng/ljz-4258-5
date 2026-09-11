defmodule UhtBatch.SampleReuseTest do
  use UhtBatch.DataCase, async: false

  alias UhtBatch.Service

  defp chain(batch, opts) do
    {:ok, %{heat_events: [heat_event]}} = establish_chain(batch, opts)
    heat_event
  end

  test "样品编号跨批次重用被拒绝，原谱系不被覆盖", %{opts: opts} do
    batch_a = Factory.batch_id()
    batch_b = Factory.batch_id()
    heat_a = chain(batch_a, opts)
    _heat_b = chain(batch_b, opts)

    # A 批登记样品 CS-5001，谱系指向 A 批热处理事件
    assert {:ok, reg_a} =
             Service.submit(
               :register_sample,
               Factory.sample(batch_a, "CS-5001", [heat_a.id]),
               opts
             )

    assert hd(reg_a).payload.lineage == [heat_a.id]

    # B 批重用同一编号：即便谱系指向 B 批自身事件也被拒绝
    snapshot_b = Service.snapshot(batch_b, opts)

    heat_b =
      snapshot_b
      |> then(fn {:ok, snap} -> Enum.find(snap.events, &(&1.type == :heat_treatment_passed)) end)

    reuse = Factory.sample(batch_b, "CS-5001", [heat_b.id])

    assert {:error, {:sample_no_already_used, "CS-5001"}} =
             Service.submit(:register_sample, reuse, opts)

    # B 批流中不得出现样品登记事实
    {:ok, %{state: state_b}} = Service.snapshot(batch_b, opts)
    refute Map.has_key?(state_b.samples, "CS-5001")

    # A 批样品谱系保持不变
    {:ok, %{state: state_a}} = Service.snapshot(batch_a, opts)
    assert state_a.samples["CS-5001"].lineage == [heat_a.id]
  end

  test "谱系引用非本批链事件被拒绝；登记时间早于源头事件被核查阻断", %{opts: opts} do
    batch = Factory.batch_id()
    _heat = chain(batch, opts)

    bad =
      Factory.sample(batch, "CS-6002", ["heat_event_from_other_batch"])

    assert {:error, {:lineage_event_not_in_batch, "heat_event_from_other_batch"}} =
             Service.submit(:register_sample, bad, opts)

    # 样品登记时间早于灌装开始（灌装前不能登记商业无菌样品）
    early = %{
      batch_id: batch,
      operator_id: "op.101",
      occurred_at: ~U[2026-09-10T08:00:00Z],
      sample_no: "CS-6003",
      sample_type: :commercial_sterility,
      lineage: []
    }

    # 该时间早于灌装，命令层按链状态判断（此时已灌装成功），改为验证时间核查：
    # 先登记一个源头为“灌装事件”、但登记时间早于灌装的样品
    {:ok, %{state: state}} = Service.snapshot(batch, opts)
    fill_id = state.filling.event_id

    too_early = %{
      batch_id: batch,
      operator_id: "op.101",
      occurred_at: ~U[2026-09-10T09:59:00Z],
      sample_no: "CS-6004",
      sample_type: :commercial_sterility,
      lineage: [fill_id],
      record_ref: "SMP-CS-6004"
    }

    assert {:ok, _} = Service.submit(:register_sample, too_early, opts)

    # 该样品发生时间早于链末端，平台同时记录“补传倒置”；
    # 操作员确认倒置后，仍应被样品时间谱系门禁阻断质量签署。
    {:ok, %{state: state0}} = Service.snapshot(batch, opts)
    anomaly = hd(state0.backfill_anomalies)

    {:ok, _} =
      Service.submit(
        :acknowledge_backfill,
        %{
          batch_id: batch,
          operator_id: "op.101",
          occurred_at: ~U[2026-09-10T12:05:00Z],
          anomaly_refs: [{anomaly.inserted_event_id, anomaly.prior_event_id}]
        },
        opts
      )

    assertion = %{
      challenge: :crypto.strong_rand_bytes(32),
      credential_id: UhtBatch.Integrations.FakeAttestation.credential_for_role(:production)
    }

    # 生产可签署（样品是质量门禁），质量被时间谱系阻断
    assert {:ok, _} = Service.sign(:production, batch, assertion, opts)

    qa = %{
      challenge: :crypto.strong_rand_bytes(32),
      credential_id: UhtBatch.Integrations.FakeAttestation.credential_for_role(:quality)
    }

    assert {:error, {:signoff_blocked, blockers}} = Service.sign(:quality, batch, qa, opts)
    assert Enum.any?(blockers, &(&1.code == "DEV-SAMPLE-LINEAGE-TIME"))
  end

  test "缺少商业无菌样品时质量签署被阻断，生产可签署", %{opts: opts} do
    batch = Factory.batch_id()
    {:ok, _} = establish_chain(batch, opts)

    assertion = %{
      challenge: :crypto.strong_rand_bytes(32),
      credential_id: UhtBatch.Integrations.FakeAttestation.credential_for_role(:production)
    }

    assert {:ok, _} = Service.sign(:production, batch, assertion, opts)

    qa = %{
      challenge: :crypto.strong_rand_bytes(32),
      credential_id: UhtBatch.Integrations.FakeAttestation.credential_for_role(:quality)
    }

    assert {:error, {:signoff_blocked, blockers}} = Service.sign(:quality, batch, qa, opts)
    assert Enum.any?(blockers, &(&1.code == "DEV-SAMPLE-MISSING"))
  end
end
