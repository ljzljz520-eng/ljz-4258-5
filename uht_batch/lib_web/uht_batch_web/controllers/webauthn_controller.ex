defmodule UhtBatchWeb.WebAuthnController do
  @moduledoc """
  WebAuthn 登录断言验证。验证通过后建立工位会话；
  生产/质量签署仍需在 SignoffController 再做一次 step-up 断言。
  """
  use UhtBatchWeb, :controller

  def verify_assertion(conn, params) do
    cfg = Application.get_env(:uht_batch, :service, [])
    attestation = cfg[:attestation] || UhtBatch.Integrations.FakeAttestation

    assertion = %{
      challenge: get_session(conn, :webauthn_challenge),
      credential_id: params["credential_id"],
      authenticator_data: params["authenticator_data"],
      client_data_json: params["client_data_json"],
      signature: params["signature"]
    }

    case attestation.verify_credential_assertion(
           assertion.challenge,
           assertion,
           %{},
           origin: Application.get_env(:uht_batch, :webauthn_origin)
         ) do
      {:ok, %{signer_id: signer_id, role: role}} ->
        conn
        |> put_session(:signer_id, signer_id)
        |> put_session(:role, role)
        |> configure_session(renew: true)
        |> send_resp(204, "")

      {:error, reason} ->
        send_resp(conn, 401, "WebAuthn 验证失败：#{inspect(reason)}")
    end
  end
end
