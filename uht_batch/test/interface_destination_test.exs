defmodule UhtBatch.InterfaceDestinationTest do
  use UhtBatch.DataCase, async: false

  alias UhtBatch.Service

  defp preheat_and_tank(batch, opts) do
    {:ok, _} = Service.submit(:confirm_pretreatment, Factory.pretreatment(batch), opts)
    {:ok, _} = Service.submit(:confirm_heat_pass, Factory.heat_pass(batch), opts)
    {:ok, _} = Service.submit(:transfer_to_tank, Factory.transfer(batch), opts)
  end

  test "界面去向不明时灌装开始被拒绝", %{opts: opts} do
    batch = Factory.batch_id()
    preheat_and_tank(batch, opts)

    iface = %{
      batch_id: batch,
      operator_id: "op.101",
      occurred_at: ~U[2026-09-10T09:40:00Z],
      interface_id: "IF-7",
      product_a: "UHT-WHOLE-MILK-3.5",
      product_b: "UHT-CHOCO",
      from_batch: batch,
      to_batch: "B-NEXT-9",
      destination: ""
    }

    assert {:ok, events} = Service.submit(:declare_interface, iface, opts)
    assert Enum.any?(events, &(&1.type == :deviation_opened))

    assert {:error, :open_interface_blocks_filling} =
             Service.submit(:start_filling, Factory.filling(batch), opts)
  end

  test "界面在灌装前按证据声明去向后流程继续，检查中无阻断", %{opts: opts} do
    batch = Factory.batch_id()
    preheat_and_tank(batch, opts)

    iface = %{
      batch_id: batch,
      operator_id: "op.101",
      occurred_at: ~U[2026-09-10T09:40:00Z],
      interface_id: "IF-8",
      product_a: "UHT-WHOLE-MILK-3.5",
      product_b: "UHT-CHOCO",
      from_batch: batch,
      to_batch: "B-NEXT-10",
      destination: "rework-tank-RW-2"
    }

    assert {:ok, _} = Service.submit(:declare_interface, iface, opts)
    assert {:ok, _} = Service.submit(:start_filling, Factory.filling(batch), opts)

    {:ok, %{findings: findings}} = Service.snapshot(batch, opts)
    refute Enum.any?(findings, &(&1.code == "DEV-IFACE-UNKNOWN"))
  end

  test "先报去向不明、后澄清并关闭偏差，灌装可继续", %{opts: opts} do
    batch = Factory.batch_id()
    preheat_and_tank(batch, opts)

    unknown = %{
      batch_id: batch,
      operator_id: "op.101",
      occurred_at: ~U[2026-09-10T09:40:00Z],
      interface_id: "IF-9",
      product_a: "UHT-WHOLE-MILK-3.5",
      product_b: "UHT-STRAWBERRY"
    }

    {:ok, evs} = Service.submit(:declare_interface, unknown, opts)
    dev = Enum.find(evs, &(&1.type == :deviation_opened))

    assert {:error, :open_interface_blocks_filling} =
             Service.submit(:start_filling, Factory.filling(batch), opts)

    close = %{
      batch_id: batch,
      operator_id: "qa.02",
      occurred_at: ~U[2026-09-10T09:50:00Z],
      deviation_id: dev.payload.deviation_id,
      disposition: "追踪确认界面段进入返工罐 RW-2"
    }

    assert {:ok, _} = Service.submit(:close_deviation, close, opts)
    assert {:ok, _} = Service.submit(:start_filling, Factory.filling(batch), opts)
  end
end
