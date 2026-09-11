defmodule UhtBatch.Application do
  @moduledoc false
  use Application

  alias UhtBatch.Integrations.MemoryEventStore
  alias UhtBatch.Pipelines.EquipmentStatusPipeline

  @impl true
  def start(_type, _args) do
    children =
      [
        {MemoryEventStore, name: UhtBatch.EventStoreDefault},
        {EquipmentStatusPipeline, pipeline_opts()}
      ]
      |> maybe_web_endpoint()

    opts = [strategy: :one_for_one, name: UhtBatch.Supervisor]
    Supervisor.start_link(children, opts)
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
