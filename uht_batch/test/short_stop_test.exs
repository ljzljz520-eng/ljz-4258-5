defmodule UhtBatch.ShortStopTest do
  use UhtBatch.DataCase, async: false

  alias UhtBatch.Service

  test "设备 NATS 短停只读信号产生待确认偏差，签署被阻断；确认+恢复后放行", %{opts: opts} do
    batch = Factory.batch_id()
    {:ok, _} = establish_chain(batch, opts)

    payload = %{
      "batch_id" => batch,
      "status" => "short_stop",
      "occurred_at" => "2026-09-10T10:30:00Z",
      "log_ref" => "EQ-LOG-5001"
    }

    # 1) 隔离设备只读状态进入：事实 + 待确认偏差
    assert {:ok, stored} =
             Service.ingest_equipment("uht.status.filler_line.FILL-LINE-7", payload, opts)

    assert length(stored) == 2
    assert Enum.any?(stored, &(&1.type == :equipment_status_received))
    assert Enum.any?(stored, &(&1.type == :deviation_opened))

    # 2) 设备只读状态不会自动产生 line_short_stop 链事件
    {:ok, %{state: state}} = Service.snapshot(batch, opts)
    assert state.stops == []
    assert length(state.equipment_signals) == 1

    # 3) 生产签署被阻断
    assertion = %{
      challenge: :crypto.strong_rand_bytes(32),
      credential_id: UhtBatch.Integrations.FakeAttestation.credential_for_role(:production)
    }

    assert {:error, {:signoff_blocked, blockers}} =
             Service.sign(:production, batch, assertion, opts)

    assert Enum.any?(blockers, &(&1.code == "DEV-EQ-STOP-UNCONFIRMED"))

    # 4) 操作员按批准记录确认短停（引用设备日志），自动关闭待确认偏差
    stop_cmd = %{
      batch_id: batch,
      operator_id: "op.101",
      occurred_at: ~U[2026-09-10T10:30:00Z],
      reason: "包膜检测触发短停",
      origin: :equipment,
      equipment_log_ref: "EQ-LOG-5001"
    }

    {:ok, stop_events} = Service.submit(:record_short_stop, stop_cmd, opts)
    stop_event = Enum.find(stop_events, &(&1.type == :line_short_stop))
    close_event = Enum.find(stop_events, &(&1.type == :deviation_closed))
    assert stop_event && close_event

    # 短停未恢复，仍阻断签署
    {:ok, %{findings: findings}} = Service.snapshot(batch, opts)
    assert Enum.any?(findings, &(&1.code == "DEV-STOP-OPEN"))

    # 5) 恢复
    resume = %{
      batch_id: batch,
      operator_id: "op.101",
      occurred_at: ~U[2026-09-10T10:42:00Z],
      stop_event_id: stop_event.id
    }

    assert {:ok, _} = Service.submit(:resume_line, resume, opts)

    {:ok, %{findings: findings2}} = Service.snapshot(batch, opts)
    refute Enum.any?(findings2, &(&1.code in ["DEV-EQ-STOP-UNCONFIRMED", "DEV-STOP-OPEN"]))

    # 6) 平台无法通过该通道下发任何控制：含控制字段的消息被拒绝
    bad = Map.put(payload, "command", "open_valve:V-3")

    assert {:error, {:control_field_rejected, "command"}} =
             Service.ingest_equipment("uht.status.filler_line.FILL-LINE-7", bad, opts)
  end

  test "操作员自行记录的短停不产生待确认偏差，但未恢复前同样阻断签署", %{opts: opts} do
    batch = Factory.batch_id()
    {:ok, _} = establish_chain(batch, opts)

    {:ok, evs} =
      Service.submit(
        :record_short_stop,
        %{
          batch_id: batch,
          operator_id: "op.101",
          occurred_at: ~U[2026-09-10T11:00:00Z],
          reason: "换膜卷"
        },
        opts
      )

    assert length(evs) == 1
    assert hd(evs).type == :line_short_stop

    {:ok, %{findings: findings}} = Service.snapshot(batch, opts)
    assert Enum.any?(findings, &(&1.code == "DEV-STOP-OPEN"))
    refute Enum.any?(findings, &(&1.code == "DEV-EQ-STOP-UNCONFIRMED"))
  end
end
