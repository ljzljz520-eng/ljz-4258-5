defmodule UhtBatchWeb.Plugs.RequireStationSession do
  @moduledoc """
  工位会话要求：已通过 WebAuthn 登录。生产/质量签署在签署动作上
  再做一次 WebAuthn step-up 断言验证。
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if get_session(conn, :signer_id) do
      conn
      |> assign(:signer_id, get_session(conn, :signer_id))
      |> assign(:role, get_session(conn, :role))
      |> put_resp_header("cache-control", "no-store")
    else
      conn
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(401, "未认证的工位会话（需要 WebAuthn 登录）")
      |> halt()
    end
  end
end
