import Config

# 启动期环境开关（每次启动重新求值，不受编译期配置缓存影响）：
#
#   EVENTSTORE_URL=esdb://eventstore:2113   事件存储切换为 EventStoreDB（Spear）
#   NATS_URL=nats://nats:4222               订阅隔离设备只读状态（gnat，只订阅）
#   WEBAUTHN_MODE=wax                       WebAuthn 断言验证切换为 wax_
#
# 不设置上述变量时，应用以内存/测试适配器启动（离线可运行）。
# 这些键正是 UhtBatch.Service 与监督树读取的 :service / :status_bus 配置。

if url = System.get_env("EVENTSTORE_URL") do
  unless Code.ensure_loaded?(UhtBatch.Integrations.SpearEventStore) do
    raise "EVENTSTORE_URL 已设置，但外部适配器未编译：请先运行 mix deps.get"
  end

  config :uht_batch, :service,
    event_store: UhtBatch.Integrations.SpearEventStore,
    event_store_ref: UhtBatch.EventStoreConnection

  config :uht_batch, event_store_url: url
end

if url = System.get_env("NATS_URL") do
  unless Code.ensure_loaded?(UhtBatch.Integrations.GnatStatusBus) do
    raise "NATS_URL 已设置，但外部适配器未编译：请先运行 mix deps.get"
  end

  config :uht_batch,
    status_bus: UhtBatch.Integrations.GnatStatusBus,
    nats_url: url
end

if System.get_env("WEBAUTHN_MODE") == "wax" do
  unless Code.ensure_loaded?(UhtBatch.Integrations.WaxAttestation) do
    raise "WEBAUTHN_MODE=wax 已设置，但外部适配器未编译：请先运行 mix deps.get"
  end

  config :uht_batch, :service, attestation: UhtBatch.Integrations.WaxAttestation
end

# mix phx.server 会自置 PHX_SERVER；显式设置时确保 Endpoint 真正监听
if System.get_env("PHX_SERVER") && Code.ensure_loaded?(UhtBatchWeb.Endpoint) do
  config :uht_batch, UhtBatchWeb.Endpoint, server: true
end
