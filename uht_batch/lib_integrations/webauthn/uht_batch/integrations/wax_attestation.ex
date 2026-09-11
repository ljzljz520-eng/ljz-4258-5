defmodule UhtBatch.Integrations.WaxAttestation do
  @moduledoc """
  WebAuthn 断言验证适配器（wax_）。用于登录与生产/质量签署 step-up。

  预先登记的凭证由工厂 IAM 维护，调用方在 opts 中传入：

      credentials: [{credential_id, cose_key, %{signer_id: ..., role: ...}}]
      wax_challenge: %Wax.Challenge{}   # new_authentication_challenge/1 生成

  本模块只验证断言并回传签署人身份；它不发起任何业务动作。
  """
  @behaviour UhtBatch.Attestation

  @impl true
  def verify_credential_assertion(_challenge, assertion, _credential, opts) do
    cred_id = assertion[:credential_id] || assertion["credential_id"]
    auth_data = assertion[:authenticator_data] || assertion["authenticator_data"]
    sig = assertion[:signature] || assertion["signature"]
    client_data_json = assertion[:client_data_json] || assertion["client_data_json"]

    wax_challenge =
      opts[:wax_challenge] ||
        raise ArgumentError, "缺少 :wax_challenge（Wax.new_authentication_challenge/1 产物）"

    registered =
      opts[:credentials] ||
        raise ArgumentError, "缺少 :credentials 已登记凭证列表"

    wax_creds =
      Enum.map(registered, fn {id, cose_key, _meta} -> {id, cose_key} end)

    with :ok <- validate_present(cred_id, :credential_id),
         :ok <- validate_present(auth_data, :authenticator_data),
         :ok <- validate_present(sig, :signature),
         :ok <- validate_present(client_data_json, :client_data_json),
         {:ok, _auth_data} <-
           Wax.authenticate(
             cred_id,
             auth_data,
             sig,
             client_data_json,
             wax_challenge,
             wax_creds
           ),
         {:ok, meta} <- lookup_meta(registered, cred_id) do
      {:ok,
       %{
         credential_id: cred_id,
         signer_id: meta.signer_id,
         role: meta[:role]
       }}
    end
  end

  defp lookup_meta(registered, cred_id) do
    case Enum.find(registered, fn {id, _key, _meta} -> id == cred_id end) do
      {_id, _key, meta} -> {:ok, meta}
      nil -> {:error, :unknown_credential}
    end
  end

  defp validate_present(nil, field), do: {:error, {:missing, field}}
  defp validate_present("", field), do: {:error, {:missing, field}}
  defp validate_present(_, _), do: :ok
end
