import Config

# 本地无外部服务时使用内存适配器；设置下列环境变量可切换真实适配器：
# EVENTSTORE_URL=esdb://localhost:2113
# NATS_URL=nats://localhost:4222
if System.get_env("EVENTSTORE_URL") do
  config :uht_batch, event_store: UhtBatch.Integrations.SpearEventStore
end

if System.get_env("NATS_URL") do
  config :uht_batch, status_bus: UhtBatch.Integrations.GnatStatusBus
end

if System.get_env("WEBAUTHN_MODE") == "wax" do
  config :uht_batch, attestation: UhtBatch.Integrations.WaxAttestation
end
