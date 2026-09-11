defmodule UhtBatch.BackfillOrderTest do
  use UhtBatch.DataCase, async: false

  alias UhtBatch.Service

  test "晚到的设备日志补传产生时序倒置，未确认前阻断双方签署", %{opts: opts} do
    batch = Factory.batch_id()
    {:ok, _} = establish_chain(batch, opts)

    # 当前链末端发生时间 10:00（灌装）。稍后补传一条发生于 09:30 的设备只读状态
    payload = %{
      "batch_id" => batch,
      "status" => "holding",
      "occurred_at" => "2026-09-10T09:30:00Z",
      "log_ref" => "EQ-LOG-LATE-01"
    }

    assert {:ok, _} =
             Service.ingest_equipment("uht.status.aseptic_tank.AT-201", payload, opts)

    {:ok, %{state: state, findings: findings}} = Service.snapshot(batch, opts)

    anomaly = hd(state.backfill_anomalies)
    refute anomaly.acknowledged
    assert anomaly.equipment_origin

    assert Enum.any?(findings, &(&1.code == "DEV-BACKFILL-ORDER" and &1.severity == :block))

    assertion = %{
      challenge: :crypto.strong_rand_bytes(32),
      credential_id: UhtBatch.Integrations.FakeAttestation.credential_for_role(:production)
    }

    assert {:error, {:signoff_blocked, blockers}} =
             Service.sign(:production, batch, assertion, opts)

    assert Enum.any?(blockers, &(&1.code == "DEV-BACKFILL-ORDER"))

    # 操作员确认补传倒置（引用事件对）
    ref = {anomaly.inserted_event_id, anomaly.prior_event_id}

    ack = %{
      batch_id: batch,
      operator_id: "op.101",
      occurred_at: ~U[2026-09-10T12:10:00Z],
      anomaly_refs: [ref]
    }

    assert {:ok, _} = Service.submit(:acknowledge_backfill, ack, opts)
    {:ok, %{state: state2, findings: findings2}} = Service.snapshot(batch, opts)
    assert hd(state2.backfill_anomalies).acknowledged
    refute Enum.any?(findings2, &(&1.code == "DEV-BACKFILL-ORDER"))

    # 未知的异常引用不允许确认
    bad_ack = %{
      batch_id: batch,
      operator_id: "op.101",
      occurred_at: ~U[2026-09-10T12:11:00Z],
      anomaly_refs: [{"nope", "nope"}]
    }

    assert {:error, {:unknown_anomaly_refs, _}} =
             Service.submit(:acknowledge_backfill, bad_ack, opts)
  end

  test "按发生时间顺序到达的设备日志不产生倒置", %{opts: opts} do
    batch = Factory.batch_id()
    # 仅建立到热处理（08:30），补传 09:00 的 holding 信号不会倒置
    {:ok, _} = Service.submit(:confirm_pretreatment, Factory.pretreatment(batch), opts)
    {:ok, _} = Service.submit(:confirm_heat_pass, Factory.heat_pass(batch), opts)

    payload = %{
      "batch_id" => batch,
      "status" => "holding",
      "occurred_at" => "2026-09-10T09:00:00Z",
      "log_ref" => "EQ-LOG-ON-TIME"
    }

    assert {:ok, _} =
             Service.ingest_equipment("uht.status.aseptic_tank.AT-201", payload, opts)

    {:ok, %{state: state}} = Service.snapshot(batch, opts)
    assert state.backfill_anomalies == []
  end
end
