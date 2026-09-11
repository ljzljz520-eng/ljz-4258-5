import Config

config :uht_batch,
  event_store: UhtBatch.Integrations.MemoryEventStore,
  attestation: UhtBatch.Integrations.FakeAttestation,
  quality_policy: %{commercial_sterility_samples: 1}
