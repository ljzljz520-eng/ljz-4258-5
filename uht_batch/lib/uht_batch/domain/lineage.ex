defmodule UhtBatch.Domain.Lineage do
  @moduledoc """
  跨批次谱系：沿“转罐时声明的上批”与“产品界面 from/to”关系，
  计算某批次的祖先批次（含无菌罐底液来源）。只读。
  """

  alias UhtBatch.Domain.{Event, State}

  @type store_reader :: (String.t() -> {:ok, [Event.t()]} | {:error, term()})

  @doc """
  BFS 展开祖先批次。`read_stream` 由 Service 注入（内存/EventStoreDB）。
  返回 {:ok, [batch_id, ...]}（起点在前，最远祖先在后）。
  """
  def ancestors(batch_id, read_stream, max_depth \\ 16) do
    do_bfs([batch_id], MapSet.new(), [], read_stream, max_depth)
  end

  defp do_bfs([], _visited, order, _read, _depth), do: {:ok, Enum.reverse(order)}

  defp do_bfs(_queue, _visited, order, _read, 0), do: {:ok, Enum.reverse(order)}

  defp do_bfs([bid | rest], visited, order, read, depth) do
    if MapSet.member?(visited, bid) do
      do_bfs(rest, visited, order, read, depth)
    else
      visited = MapSet.put(visited, bid)

      case read.(batch_stream(bid)) do
        {:ok, events} ->
          state = Enum.reduce(events, State.new(bid), &State.apply(&2, &1))
          parents = direct_parents(bid, state)
          do_bfs(rest ++ parents, visited, [bid | order], read, depth - 1)

        {:error, _} = err ->
          err
      end
    end
  end

  @doc "直接父批次：转罐声明的 previous_batch + 界面指向的 from_batch。"
  def direct_parents(batch_id, %State{} = s) do
    tank_parents =
      s.tank_history
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&(&1.batch_id == batch_id))
      |> Enum.map(& &1.previous_batch)

    iface_parents =
      s.interfaces
      |> Enum.filter(&(&1.to_batch == batch_id))
      |> Enum.map(& &1.from_batch)

    (tank_parents ++ iface_parents)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == "" or &1 == batch_id))
    |> Enum.uniq()
  end

  def batch_stream(batch_id), do: "batch-#{batch_id}"
end
