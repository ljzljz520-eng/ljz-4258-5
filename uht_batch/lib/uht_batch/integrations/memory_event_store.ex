defmodule UhtBatch.Integrations.MemoryEventStore do
  @moduledoc "基于 GenServer 的内存事件存储（测试与离线开发用）。"
  @behaviour UhtBatch.EventStore

  use GenServer

  ## Client

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def append_batch(pid_or_name \\ __MODULE__, stream, events, expected \\ :any, _opts \\ []) do
    GenServer.call(pid_or_name, {:append, stream, events, expected})
  end

  @impl true
  def read_stream(pid_or_name \\ __MODULE__, stream, _opts \\ []) do
    GenServer.call(pid_or_name, {:read, stream})
  end

  @impl true
  def sample_claimed?(pid_or_name \\ __MODULE__, sample_no, _opts \\ []) do
    GenServer.call(pid_or_name, {:sample_claimed, sample_no})
  end

  def reset(pid_or_name \\ __MODULE__), do: GenServer.call(pid_or_name, :reset)

  ## Server

  @impl true
  def init(:ok), do: {:ok, %{streams: %{}}}

  @impl true
  def handle_call({:append, stream, events, expected}, _from, state) do
    current = Map.get(state.streams, stream, [])
    current_len = length(current)

    with :ok <- check_expected(expected, current_len),
         :ok <- check_sample_claims(stream, events, state) do
      new_state = %{state | streams: Map.put(state.streams, stream, current ++ events)}
      {:reply, {:ok, events}, new_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:read, stream}, _from, state) do
    {:reply, {:ok, Map.get(state.streams, stream, [])}, state}
  end

  @impl true
  def handle_call({:sample_claimed, sample_no}, _from, state) do
    claimed =
      state.streams
      |> Map.get("sample-claims", [])
      |> Enum.any?(&(&1.payload[:sample_no] == sample_no))

    {:reply, claimed, state}
  end

  @impl true
  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{streams: %{}}}

  ## Helpers

  defp check_expected(:any, _), do: :ok
  defp check_expected(:stream_exists, 0), do: {:error, :not_found}
  defp check_expected(:stream_exists, _), do: :ok

  defp check_expected(n, current) when is_integer(n) do
    if n == current, do: :ok, else: {:error, {:wrong_expected_version, n, current}}
  end

  # sample-claims 流对样品编号做全局唯一保留（跨批次重用被拒绝）。
  defp check_sample_claims("sample-claims", events, state) do
    existing =
      state.streams
      |> Map.get("sample-claims", [])
      |> Enum.map(& &1.payload.sample_no)
      |> MapSet.new()

    incoming =
      events
      |> Enum.filter(&(&1.type == :sample_registered))
      |> Enum.map(& &1.payload.sample_no)

    case Enum.find(incoming, &MapSet.member?(existing, &1)) do
      nil -> :ok
      no -> {:error, {:sample_no_already_used, no}}
    end
  end

  defp check_sample_claims(_stream, _events, _state), do: :ok
end
