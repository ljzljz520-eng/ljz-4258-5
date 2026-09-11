defmodule UhtBatch.EquipmentIngestTest do
  use ExUnit.Case, async: true

  alias UhtBatch.Domain.EquipmentIngest

  defp now, do: ~U[2026-09-10T12:00:00Z]

  test "合法只读状态被翻译为设备事实" do
    assert {:ok, evt} =
             EquipmentIngest.translate(
               "uht.status.aseptic_tank.AT-201",
               %{"batch_id" => "B1", "status" => "holding"},
               now()
             )

    assert evt.type == :equipment_status_received
    assert evt.source == :equipment
    assert evt.payload.status == "holding"
  end

  test "短停状态返回待操作员确认标记" do
    assert {:ok, _evt, :pending_operator_confirmation} =
             EquipmentIngest.translate(
               "uht.status.filler_line.F7",
               %{"batch_id" => "B1", "status" => "short_stop"},
               now()
             )
  end

  test "拒绝控制字段、非法 subject、非法状态与缺失批次" do
    assert {:error, {:control_field_rejected, "setpoint"}} =
             EquipmentIngest.translate(
               "uht.status.filler_line.F7",
               %{"batch_id" => "B1", "status" => "idle", "setpoint" => 137},
               now()
             )

    assert {:error, :invalid_subject} =
             EquipmentIngest.translate("plant.weather", %{"batch_id" => "B1"}, now())

    assert {:error, {:status_not_allowed, "explode"}} =
             EquipmentIngest.translate(
               "uht.status.filler_line.F7",
               %{"batch_id" => "B1", "status" => "explode"},
               now()
             )

    assert {:error, :missing_batch_id} =
             EquipmentIngest.translate(
               "uht.status.filler_line.F7",
               %{"status" => "idle"},
               now()
             )

    assert {:error, :device_not_allowed} =
             EquipmentIngest.translate(
               "uht.status.mystery_device.X",
               %{"batch_id" => "B1", "status" => "idle"},
               now()
             )
  end
end
