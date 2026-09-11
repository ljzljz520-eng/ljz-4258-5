defmodule UhtBatchWeb.Router do
  @moduledoc """
  受控工位路由。三类工位页面：

    * /stations/heat     热处理工位：预处理/热处理通过确认
    * /stations/buffer   无菌缓冲：转罐、底液、产品界面
    * /stations/filler   灌装：短停、恢复、样品、WebAuthn 签署

  任何写入动作都是“操作员按批准记录确认事实”；
  路由层没有、也不会有阀阵/灌装机控制端点。
  """
  use Phoenix.Router, helpers: false

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug UhtBatchWeb.Plugs.RequireStationSession
  end

  scope "/stations", UhtBatchWeb do
    pipe_through :browser

    get "/heat", StationController, :heat
    get "/buffer", StationController, :buffer
    get "/filler", StationController, :filler

    # 操作员确认事实（POST + CSRF）
    post "/events/pretreatment", EventController, :confirm_pretreatment
    post "/events/heat_pass", EventController, :confirm_heat_pass
    post "/events/transfer", EventController, :transfer_to_tank
    post "/events/interface", EventController, :declare_interface
    post "/events/filling_start", EventController, :start_filling
    post "/events/pack_roll", EventController, :register_pack_roll
    post "/events/roll_changeover", EventController, :confirm_roll_changeover
    post "/events/splice_failure", EventController, :record_splice_failure
    post "/events/splice_failure/dispose", EventController, :dispose_splice_failure
    post "/events/splice_segment/review", EventController, :review_splice_segment
    post "/events/short_stop", EventController, :record_short_stop
    post "/events/resume", EventController, :resume_line
    post "/events/sample", EventController, :register_sample
    post "/events/deviation/close", EventController, :close_deviation
    post "/events/backfill/ack", EventController, :acknowledge_backfill

    # WebAuthn：生产/质量签署
    post "/signin/webauthn", WebAuthnController, :verify_assertion
    post "/signoff/production", SignoffController, :production
    post "/signoff/quality", SignoffController, :quality
  end
end
