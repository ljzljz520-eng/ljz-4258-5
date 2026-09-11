defmodule UhtBatch.Integrations.FakeAttestation do
  @moduledoc """
  WebAuthn 测试适配器：根据预置登记信息返回签署人，不进行密码学验证。
  生产使用 Wax 适配器。
  """
  @behaviour UhtBatch.Attestation

  @registry %{
    "prod-cred-1" => %{signer_id: "op.prod.07", role: :production},
    "qa-cred-1" => %{signer_id: "qa.lead.02", role: :quality}
  }

  @impl UhtBatch.Attestation
  def verify_credential_assertion(_challenge, assertion, _credential, _opts) do
    id = Map.get(assertion, :credential_id) || Map.get(assertion, "credential_id")

    case Map.get(@registry, id) do
      nil -> {:error, :unknown_credential}
      %{signer_id: signer} -> {:ok, %{credential_id: id, signer_id: signer}}
    end
  end

  def credential_for_role(:production), do: "prod-cred-1"
  def credential_for_role(:quality), do: "qa-cred-1"
end
