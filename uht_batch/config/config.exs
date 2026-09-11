import Config

# 应用服务门面（UhtBatch.Service）从 :service 键读取适配器配置；
# 默认全部为内存/测试适配器，离线即可启动与测试。
# 生产适配器由 config/runtime.exs 按环境变量在每次启动时切换。
config :uht_batch, :service,
  event_store: UhtBatch.Integrations.MemoryEventStore,
  event_store_ref: UhtBatch.Integrations.MemoryEventStore,
  attestation: UhtBatch.Integrations.FakeAttestation

config :uht_batch,
  # NATS 隔离设备只读状态总线；nil = 不订阅（runtime.exs 按 NATS_URL 切换）
  status_bus: nil,
  webauthn_origin: "https://uht-stations.local",
  webauthn_rp_id: "uht-stations.local",
  # 质量策略：每批至少 1 份商业无菌样品
  quality_policy: %{commercial_sterility_samples: 1}

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:batch_id]

# 仅在 Phoenix 依赖存在时生效；缺失时整个 lib_web 目录不参与编译
if Code.ensure_loaded?(Bandit) do
  config :uht_batch, UhtBatchWeb.Endpoint,
    adapter: Bandit.PhoenixAdapter,
    url: [host: "uht-stations.local", port: 4000, scheme: "https"],
    http: [ip: {127, 0, 0, 1}, port: 4000],
    server: false,
    secret_key_base: "PLACEHOLDER-secret-key-base-change-in-prod-0123456789abcdef",
    live_view: [signing_salt: "uht-live"],
    render_errors: [formats: [html: UhtBatchWeb.ErrorHTML], layout: false]
end

import_config "#{config_env()}.exs"
