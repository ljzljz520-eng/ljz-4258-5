defmodule UhtBatch.Integrations.SpearEventStore do
  @moduledoc """
  EventStoreDB 适配器（Spear 1.5）。仅追加与读取；
  样品编号全局唯一通过专用 `sample-claims` 流保留。

  连接（环境变量）：EVENTSTORE_URL=esdb://host:2113
  """
  @behaviour UhtBatch.EventStore

  alias UhtBatch.Domain.Event

  @impl true
  def append_batch(conn, stream, events, expected \\ :any, opts \\ []) do
    conn = conn || connection(opts)

    spear_events = Enum.map(events, &to_spear_event/1)

    case Spear.append(spear_events, conn, stream, expect: expected_policy(expected)) do
      :ok ->
        {:ok, events}

      {:ok, _} ->
        {:ok, events}

      {:error, %Spear.ExpectationViolation{} = v} ->
        {:error, {:wrong_expected_version, v.expected, v.current}}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def read_stream(conn, stream, opts \\ []) do
    conn = conn || connection(opts)
    from = Keyword.get(opts, :from, :start)

    events =
      conn
      |> Spear.stream!(stream, from: from)
      |> Enum.map(&from_spear_event/1)

    {:ok, events}
  catch
    :exit, {{:stream_not_found, _}, _} -> {:ok, []}
    :exit, {{:not_found, _}, _} -> {:ok, []}
    _, reason -> {:error, reason}
  end

  @impl true
  def sample_claimed?(conn, sample_no, opts \\ []) do
    case read_stream(conn, "sample-claims", opts) do
      {:ok, events} -> Enum.any?(events, &(&1.payload[:sample_no] == sample_no))
      _ -> false
    end
  end

  def start_connection(opts \\ []) do
    url = opts[:url] || System.get_env("EVENTSTORE_URL")
    args = [connection_string: url]
    args = if opts[:name], do: args ++ [name: opts[:name]], else: args
    Spear.Connection.start_link(args)
  end

  ## 映射 ------------------------------------------------------------------

  defp to_spear_event(%Event{} = e) do
    Spear.Event.new(
      Atom.to_string(e.type),
      serialize(e),
      id: e.id,
      metadata: metadata(e)
    )
  end

  defp from_spear_event(%Spear.Event{} = pe) do
    data = pe.body

    %Event{
      id: pe.id,
      type: String.to_existing_atom(pe.type),
      batch_id: data["batch_id"],
      occurred_at: parse_dt(data["occurred_at"]),
      recorded_at: parse_dt(data["recorded_at"]),
      source: String.to_existing_atom(data["source"] || "operator"),
      operator_id: data["operator_id"],
      correlation_id: data["correlation_id"],
      payload: atomize(data["payload"] || %{}),
      raw_equipment_log: data["raw_equipment_log"]
    }
  end

  defp connection(opts) do
    opts[:connection] || Process.get(:spear_connection) ||
      Application.get_env(:uht_batch, __MODULE__, [])[:connection] ||
      raise "EventStoreDB 连接未配置：请设置 EVENTSTORE_URL 或 :connection"
  end

  defp expected_policy(:any), do: :any
  defp expected_policy(:stream_exists), do: :exists
  defp expected_policy(n) when is_integer(n), do: n

  defp serialize(%Event{} = e) do
    %{
      "batch_id" => e.batch_id,
      "occurred_at" => DateTime.to_iso8601(e.occurred_at),
      "recorded_at" => DateTime.to_iso8601(e.recorded_at),
      "source" => Atom.to_string(e.source || :operator),
      "operator_id" => e.operator_id,
      "correlation_id" => e.correlation_id,
      "payload" => stringify(e.payload),
      "raw_equipment_log" => e.raw_equipment_log
    }
  end

  defp metadata(%Event{} = e) do
    %{
      "batch_id" => e.batch_id,
      "source" => Atom.to_string(e.source || :operator),
      "operator_id" => e.operator_id,
      "correlation_id" => e.correlation_id
    }
  end

  defp parse_dt(nil), do: nil
  defp parse_dt(s) when is_binary(s), do: DateTime.from_iso8601(s) |> elem(1)

  defp stringify(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp stringify(%_{} = struct), do: Map.from_struct(struct) |> stringify()

  defp stringify(v) when is_map(v) do
    Map.new(v, fn {k, x} -> {to_string(k), stringify(x)} end)
  end

  defp stringify(v) when is_list(v), do: Enum.map(v, &stringify/1)
  defp stringify(v) when is_atom(v), do: to_string(v)
  defp stringify(v), do: v

  @known_keys ~w(
    record_ref product_code line_id tank_id from previous_batch heel_present
    interface_id product_a product_b to_batch destination filler_id reason
    origin equipment_log_ref stop_event_id sample_no sample_type lineage
    deviation_id code disposition context anomaly_refs credential_id findings
    device_id device_type status subject
  )

  defp atomize(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if k in @known_keys, do: String.to_existing_atom(k), else: String.to_atom(k)
      {key, atomize(v)}
    end)
  rescue
    ArgumentError -> map
  end

  defp atomize(other), do: other
end
