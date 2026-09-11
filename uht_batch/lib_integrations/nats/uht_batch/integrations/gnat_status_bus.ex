defmodule UhtBatch.Integrations.GnatStatusBus do
  @moduledoc """
  NATS 适配器（gnat）。**只订阅，模块中没有任何发布函数**，
  对应“隔离设备只读状态”的网络边界。

      config :uht_batch,
        status_bus: #{__MODULE__},
        nats_connection: :gnat
  """
  @behaviour UhtBatch.StatusBus

  @impl UhtBatch.StatusBus
  def subscribe(subject, handler, opts \\ []) do
    conn =
      Keyword.get(opts, :connection, Application.get_env(:uht_batch, :nats_connection, :gnat))

    # 订阅进程受调用方监督树监督（如 pipeline 动态订阅场景）。
    __MODULE__.Subscriber.start_link({conn, subject, handler})
  end
end

defmodule UhtBatch.Integrations.GnatStatusBus.Subscriber do
  @moduledoc false
  use GenServer

  @doc false
  def start_link({conn, subject, handler}),
    do: GenServer.start_link(__MODULE__, {conn, subject, handler})

  @impl true
  def init({conn, subject, handler}) do
    case Gnat.sub(conn, self(), subject) do
      {:ok, _sid} -> {:ok, %{subject: subject, handler: handler}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:msg, %{topic: topic, body: body}}, state) do
    payload =
      case Jason.decode(body) do
        {:ok, map} -> map
        _ -> body
      end

    dispatch(state.handler, topic, payload)
    {:noreply, state}
  end

  defp dispatch(fun, topic, payload) when is_function(fun, 2), do: fun.(topic, payload)

  defp dispatch({mod, fun, extra}, topic, payload),
    do: apply(mod, fun, [topic, payload | extra])
end
