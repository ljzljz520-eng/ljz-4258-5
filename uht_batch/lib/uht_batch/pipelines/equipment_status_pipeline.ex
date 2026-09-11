defmodule UhtBatch.Pipelines.EquipmentStatusPipeline do
  @moduledoc """
  设备只读状态管道：订阅 NATS `uht.status.>`，把经白名单翻译的状态
  写入批次事件流。订阅端只收不发；本模块没有任何发布/控制 API。

  外部连接尚未就绪（如 NATS 正在重连）时按固定间隔重试订阅，
  不因外部服务启动顺序拖垮应用监督树。
  """

  use GenServer

  require Logger

  @retry_interval_ms 2_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    bus = Keyword.get(opts, :status_bus, Application.get_env(:uht_batch, :status_bus))
    subject = Keyword.get(opts, :subject, "uht.status.>")

    {:ok, %{bus: bus, subject: subject, opts: opts, sub_ref: nil}, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state), do: {:noreply, subscribe(state)}

  @impl true
  def handle_info(:retry_subscribe, state), do: {:noreply, subscribe(state)}

  def handle_info(_other, state), do: {:noreply, state}

  defp subscribe(%{bus: nil} = state), do: state

  defp subscribe(%{bus: bus, subject: subject, opts: opts} = state) do
    case safe_subscribe(bus, subject, opts) do
      {:ok, ref} ->
        Logger.info("[#{__MODULE__}] subscribed (read-only) to #{subject}")
        %{state | sub_ref: ref}

      {:error, reason} ->
        Logger.warning(
          "[#{__MODULE__}] subscribe to #{subject} failed: #{inspect(reason)}; " <>
            "retrying in #{@retry_interval_ms}ms"
        )

        Process.send_after(self(), :retry_subscribe, @retry_interval_ms)
        %{state | sub_ref: nil}
    end
  end

  # 连接进程尚未注册或正在重连时，适配器可能以 exit 失败而非返回错误元组。
  defp safe_subscribe(bus, subject, opts) do
    bus.subscribe(subject, {__MODULE__, :handle_message, [opts]}, [])
  catch
    :exit, reason -> {:error, reason}
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
