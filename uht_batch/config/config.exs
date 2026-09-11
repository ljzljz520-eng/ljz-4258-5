import Config

config :uht_batch,
  # 运行时可替换为 EventStoreDB / NATS / Wax 适配器
  event_store: UhtBatch.Integrations.MemoryEventStore,
  status_bus: nil,
  attestation: UhtBatch.Integrations.FakeAttestation,
  webauthn_origin: "https://uht-stations.local",
  webauthn_rp_id: "uht-stations.local",
  # 质量策略：每批至少 1 份商业无菌样品
  quality_policy: %{commercial_sterility_samples: 1}

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:batch_id]

# 仅在 Phoenix 依赖存在时生效；缺失时整个 web 目录不参与编译
if Code.ensure_loaded?(Bandit) do
  config :uht_batch, UhtBatchWeb.Endpoint,
    adapter: Bandit.PhoenixAdapter,
    url: [host: "uht-stations.local", port: 4000, scheme: "https"],
    http: [ip: {127, 0, 0, 1}, port: 4000],
    server: false,
    secret_key_base: "PLACEHOLDER-secret-key-base-change-in-prod-0123456789abcdef",
    live_view: [signing_salt: "uht-live"],
    render_errors: []
end
