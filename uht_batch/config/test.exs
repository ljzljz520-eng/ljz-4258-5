import Config

# 测试固定使用内存/测试适配器（与 UhtBatch.Service 读取的 :service 键对齐）
config :uht_batch, :service,
  event_store: UhtBatch.Integrations.MemoryEventStore,
  event_store_ref: UhtBatch.Integrations.MemoryEventStore,
  attestation: UhtBatch.Integrations.FakeAttestation

config :uht_batch, quality_policy: %{commercial_sterility_samples: 1}
