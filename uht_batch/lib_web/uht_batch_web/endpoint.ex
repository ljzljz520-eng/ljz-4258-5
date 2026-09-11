defmodule UhtBatchWeb.Endpoint do
  @moduledoc "受控工位页面 Endpoint（只读事实呈现 + 操作员确认动作）。"
  use Phoenix.Endpoint, otp_app: :uht_batch

  @session_options [
    store: :cookie,
    key: "_uht_batch_key",
    signing_salt: "uht-trace",
    same_site: "Strict",
    secure: true
  ]

  plug Plug.Static,
    at: "/",
    from: :uht_batch,
    gzip: false,
    only: ~w(css js)

  plug Plug.RequestId
  plug Plug.Session, @session_options
  plug UhtBatchWeb.Router
end
