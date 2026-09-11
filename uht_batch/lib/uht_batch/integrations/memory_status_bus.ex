defmodule UhtBatch.Integrations.MemoryStatusBus do
  @moduledoc "内存只读状态总线（测试用）。提供测试辅助发布；生产适配器不可发布。"
  @behaviour UhtBatch.StatusBus

  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(:ok), do: {:ok, %{subscriptions: []}}

  @impl UhtBatch.StatusBus
  def subscribe(_subject, _handler, _opts \\ []) do
    {:ok, make_ref()}
  end

  ## 测试辅助：向 GenServer 风格 handler 投递一条只读状态消息。
  def test_publish(handler, subject, message) when is_pid(handler) do
    send(handler, {:nats_message, %{topic: subject, body: message, headers: []}})
    :ok
  end
end
