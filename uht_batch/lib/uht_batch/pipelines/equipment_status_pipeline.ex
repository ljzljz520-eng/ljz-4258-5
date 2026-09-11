defmodule UhtBatch.Pipelines.EquipmentStatusPipeline do
  @moduledoc """
  设备只读状态管道：订阅 NATS `uht.status.>`，把经白名单翻译的状态
  写入批次事件流。订阅端只收不发；本模块没有任何发布/控制 API。
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    bus = Keyword.get(opts, :status_bus, Application.get_env(:uht_batch, :status_bus))
    subject = Keyword.get(opts, :subject, "uht.status.>")

    if bus do
      case bus.subscribe(subject, {__MODULE__, :handle_message, [opts]}, []) do
        {:ok, ref} ->
          Logger.info("[#{__MODULE__}] subscribed (read-only) to #{subject}")
          {:ok, %{sub_ref: ref, bus: bus}}

        {:error, reason} ->
          Logger.warning("[#{__MODULE__}] subscribe failed: #{inspect(reason)}")
          {:ok, %{sub_ref: nil, bus: bus}}
      end
    else
      {:ok, %{sub_ref: nil, bus: nil}}
    end
  end

  ## 供内存/Gnat 适配器以消息形式调用（参数：subject, payload, opts）
  def handle_message(topic, body, opts \\ []) do
    payload =
      cond do
        is_map(body) -> body
        is_binary(body) -> decode_json(body)
        true -> %{}
      end

    case UhtBatch.Service.ingest_equipment(topic, payload, opts) do
      {:ok, events} when is_list(events) ->
        {:ok, length(events)}

      {:ok, _event} ->
        {:ok, 1}

      {:error, reason} ->
        Logger.warning("[#{__MODULE__}] rejected equipment status #{topic}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp decode_json(bin) do
    if Code.ensure_loaded?(Jason), do: apply(Jason, :decode!, [bin]), else: %{}
  rescue
    _ ->
      %{}
  end
end
