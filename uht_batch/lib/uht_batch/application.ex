defmodule UhtBatch.Application do
  @moduledoc false
  use Application

  alias UhtBatch.Integrations.MemoryEventStore
  alias UhtBatch.Pipelines.EquipmentStatusPipeline

  @impl true
  def start(_type, _args) do
    children =
      [
        event_store_child(),
        nats_connection_child(),
        {EquipmentStatusPipeline, pipeline_opts()}
      ]
      |> Enum.reject(&is_nil/1)
      |> maybe_web_endpoint()

    opts = [strategy: :one_for_one, name: UhtBatch.Supervisor]
    Supervisor.start_link(children, opts)
  end

  ## 事件存储：默认内存适配器，注册名即服务门面的 :event_store_ref。
  ## config/runtime.exs 按 EVENTSTORE_URL 注入 SpearEventStore 与
  ## :event_store_url 后，这里改为启动 Spear.Connection（断线自动重连）。
  defp event_store_child do
    service = Application.get_env(:uht_batch, :service, [])

    case Keyword.get(service, :event_store, MemoryEventStore) do
      MemoryEventStore ->
        {MemoryEventStore, name: Keyword.get(service, :event_store_ref, MemoryEventStore)}

      UhtBatch.Integrations.SpearEventStore ->
        url =
          Application.get_env(:uht_batch, :event_store_url) ||
            raise "SpearEventStore 需要配置 :event_store_url（EVENTSTORE_URL）"

        {Spear.Connection,
         connection_string: url,
         name: Keyword.get(service, :event_store_ref, UhtBatch.EventStoreConnection)}

      other ->
        raise "未知的 event_store 适配器：#{inspect(other)}"
    end
  end

  ## NATS 只读连接：config/runtime.exs 按 NATS_URL 注入 GnatStatusBus 与
  ## :nats_url 后，启动名为 :gnat 的受监督连接（GnatStatusBus 默认引用
  ## :gnat；连接断开由 ConnectionSupervisor 自动重连）。
  defp nats_connection_child do
    if Application.get_env(:uht_batch, :status_bus) == UhtBatch.Integrations.GnatStatusBus do
      url =
        Application.get_env(:uht_batch, :nats_url) ||
          raise "GnatStatusBus 需要配置 :nats_url（NATS_URL）"

      uri = URI.parse(url)

      {Gnat.ConnectionSupervisor,
       %{
         name: :gnat,
         connection_settings: [%{host: uri.host || "localhost", port: uri.port || 4222}]
       }}
    end
  end

  defp pipeline_opts do
    case Application.get_env(:uht_batch, :status_bus) do
      nil -> [name: EquipmentStatusPipeline]
      bus -> [name: EquipmentStatusPipeline, status_bus: bus]
    end
  end

  # Phoenix 仅在依赖存在时编译/启动；核心域不依赖 Phoenix。
  defp maybe_web_endpoint(children) do
    if Code.ensure_loaded?(UhtBatchWeb.Endpoint) do
      children ++ [UhtBatchWeb.Endpoint]
    else
      children
    end
  end
end
