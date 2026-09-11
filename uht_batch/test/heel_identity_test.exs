defmodule UhtBatch.HeelIdentityTest do
  use UhtBatch.DataCase, async: false

  alias UhtBatch.Service

  test "含上批底液但身份明确：谱系可追溯，不开启偏差", %{opts: opts} do
    batch = Factory.batch_id()
    prior = "B-PRIOR-77"

    {:ok, _} =
      establish_chain(batch, opts, %{
        transfer_opts: [heel: true, previous_batch: prior]
      })

    {:ok, %{state: state, findings: findings}} = Service.snapshot(batch, opts)
    assert state.tank_history["AT-201"] |> hd() |> Map.get(:heel_present)
    refute Enum.any?(findings, &(&1.code == "DEV-HEEL-UNKNOWN"))
    assert {:ok, chain} = Service.ancestors(batch, opts)
    assert hd(chain) == batch
    assert List.last(chain) == prior
  end

  test "无菌罐含上批底液且上批身份不明：事实照记并开启偏差，签署被阻断", %{opts: opts} do
    batch = Factory.batch_id()

    # 预处理 + 热处理
    {:ok, _} = Service.submit(:confirm_pretreatment, Factory.pretreatment(batch), opts)
    {:ok, _} = Service.submit(:confirm_heat_pass, Factory.heat_pass(batch), opts)

    # 带底液转罐，previous_batch 留空
    transfer =
      batch
      |> Factory.transfer(heel: true)
      |> Map.delete(:previous_batch)

    assert {:ok, events} = Service.submit(:transfer_to_tank, transfer, opts)
    types = Enum.map(events, & &1.type)
    assert :deviation_opened in types

    # 界面去向明确 + 灌装开始
    iface = %{
      batch_id: batch,
      operator_id: "op.101",
      occurred_at: ~U[2026-09-10T09:40:00Z],
      interface_id: "IF-1",
      product_a: "UHT-WHOLE-MILK-3.5",
      product_b: "UHT-SKIM",
      from_batch: batch,
      to_batch: "B-NEXT",
      destination: "rework-tank-RW-2"
    }

    assert {:ok, _} = Service.submit(:declare_interface, iface, opts)
    assert {:ok, _} = Service.submit(:start_filling, Factory.filling(batch), opts)

    {:ok, %{findings: findings}} = Service.snapshot(batch, opts)
    assert Enum.any?(findings, &(&1.code == "DEV-HEEL-UNKNOWN" and &1.severity == :block))

    # 生产签署被阻断
    assertion = %{
      challenge: :crypto.strong_rand_bytes(32),
      credential_id: UhtBatch.Integrations.FakeAttestation.credential_for_role(:production)
    }

    assert {:error, {:signoff_blocked, blockers}} =
             Service.sign(:production, batch, assertion, opts)

    assert Enum.any?(blockers, &(&1.code == "DEV-HEEL-UNKNOWN"))

    # 质量按证据确认上批身份后关闭偏差
    [d] =
      UhtBatch.Service.snapshot(batch, opts)
      |> then(fn {:ok, snap} -> snap.state.deviations |> Map.values() end)
      |> Enum.filter(&(&1.code == "DEV-HEEL-UNKNOWN"))

    close = %{
      batch_id: batch,
      operator_id: "qa.02",
      occurred_at: ~U[2026-09-10T11:00:00Z],
      deviation_id: d.id,
      disposition: "经罐区记录核实上批为 B-PRIOR-77"
    }

    assert {:ok, _} = Service.submit(:close_deviation, close, opts)
    {:ok, %{findings: findings2}} = Service.snapshot(batch, opts)
    refute Enum.any?(findings2, &(&1.code == "DEV-HEEL-UNKNOWN"))
  end
end
