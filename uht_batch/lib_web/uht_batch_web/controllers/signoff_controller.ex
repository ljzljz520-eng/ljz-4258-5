defmodule UhtBatchWeb.SignoffController do
  @moduledoc """
  WebAuthn step-up 生产/质量签署。平台核查界面段、时间与样品谱系；
  签署本身只是事实追加，不向任何设备发指令。
  """
  use UhtBatchWeb, :controller

  alias UhtBatch.Service

  def production(conn, params), do: do_sign(conn, params, :production)
  def quality(conn, params), do: do_sign(conn, params, :quality)

  defp do_sign(conn, params, role) do
    assertion = %{
      challenge: get_session(conn, :signoff_challenge),
      credential_id: params["credential_id"],
      authenticator_data: params["authenticator_data"],
      client_data_json: params["client_data_json"],
      signature: params["signature"]
    }

    case Service.sign(role, params["batch_id"], assertion) do
      {:ok, _events} ->
        conn
        |> put_flash(:info, "#{role} 签署完成")
        |> redirect(to: "/stations/filler?batch_id=#{URI.encode_www_form(params["batch_id"])}")

      {:error, {:signoff_blocked, blockers}} ->
        body =
          blockers
          |> Enum.map(&"[BLOCK] #{&1.code} #{&1.message}")
          |> Enum.join("\n")

        send_resp(conn, 409, "签署被阻断：\n#{body}")

      {:error, reason} ->
        send_resp(conn, 400, "签署失败：#{inspect(reason)}")
    end
  end
end
