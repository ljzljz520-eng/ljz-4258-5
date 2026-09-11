defmodule UhtBatch.SignoffFlowTest do
  use UhtBatch.DataCase, async: false

  alias UhtBatch.Service

  test "完整合规链：生产与质量 WebAuthn 签署均成功，且不可重签", %{opts: opts} do
    batch = Factory.batch_id()
    {:ok, %{heat_events: [heat_event]}} = establish_chain(batch, opts)

    {:ok, _} =
      Service.submit(
        :register_sample,
        Factory.sample(batch, "CS-OK-1", [heat_event.id], at: ~U[2026-09-10T10:20:00Z]),
        opts
      )

    prod = %{
      challenge: :crypto.strong_rand_bytes(32),
      credential_id: UhtBatch.Integrations.FakeAttestation.credential_for_role(:production)
    }

    assert {:ok, prod_events} = Service.sign(:production, batch, prod, opts)
    assert hd(prod_events).type == :production_signed_off

    qa = %{
      challenge: :crypto.strong_rand_bytes(32),
      credential_id: UhtBatch.Integrations.FakeAttestation.credential_for_role(:quality)
    }

    assert {:ok, qa_events} = Service.sign(:quality, batch, qa, opts)
    assert hd(qa_events).type == :quality_signed_off

    # 不可重签
    assert {:error, :production_already_signed_off} =
             Service.sign(:production, batch, prod, opts)

    assert {:error, :quality_already_signed_off} =
             Service.sign(:quality, batch, qa, opts)

    # 未知凭证不能签署
    assert {:error, :unknown_credential} =
             Service.sign(
               :quality,
               batch,
               %{challenge: "x", credential_id: "ghost"},
               opts
             )
  end

  test "质量签署必须在生产签署之后；缺预处理时热处理通过被拒绝", %{opts: opts} do
    batch = Factory.batch_id()

    assert {:error, :pretreatment_not_confirmed} =
             Service.submit(:confirm_heat_pass, Factory.heat_pass(batch), opts)

    {:ok, _} = Service.submit(:confirm_pretreatment, Factory.pretreatment(batch), opts)
    {:ok, _} = Service.submit(:confirm_heat_pass, Factory.heat_pass(batch), opts)
    {:ok, _} = Service.submit(:transfer_to_tank, Factory.transfer(batch), opts)

    iface = %{
      batch_id: batch,
      operator_id: "op.101",
      occurred_at: ~U[2026-09-10T09:40:00Z],
      interface_id: "IF-X",
      product_a: "A",
      product_b: "B",
      destination: "rework-tank-RW-2"
    }

    {:ok, _} = Service.submit(:declare_interface, iface, opts)
    {:ok, _} = Service.submit(:start_filling, Factory.filling(batch), opts)

    qa = %{
      challenge: :crypto.strong_rand_bytes(32),
      credential_id: UhtBatch.Integrations.FakeAttestation.credential_for_role(:quality)
    }

    assert {:error, :production_not_signed_off} = Service.sign(:quality, batch, qa, opts)
  end
end
