defmodule UhtBatchWeb.EventController do
  @moduledoc """
  操作员“按批准记录确认实际事件”的表单入口。每个动作只追加事实；
  任何请求若试图携带无菌工艺参数/控制字段，均被忽略或拒绝。
  """
  use UhtBatchWeb, :controller

  alias UhtBatch.Service

  @reject_keys ~w(command setpoint temperature pressure flow hold_time
    valve target actuate control open close start_machine)

  defp base(conn, params) do
    if Enum.any?(params, fn {k, _} -> k in @reject_keys end) do
      {:error, :control_or_process_params_rejected}
    else
      {:ok,
       %{
         batch_id: params["batch_id"],
         operator_id: conn.assigns.signer_id,
         occurred_at: parse_time(params["occurred_at"]),
         record_ref: params["record_ref"],
         correlation_id: params["correlation_id"]
       }
       |> then(fn m ->
         if m.batch_id in [nil, ""] or m.operator_id in [nil, ""],
           do: {:error, :missing_batch_or_operator},
           else: {:ok, Map.drop(m, [:record_ref]) |> Map.put(:record_ref, m.record_ref)}
       end)}
    end
  end

  def confirm_pretreatment(conn, params) do
    run(conn, params, :confirm_pretreatment, fn b ->
      Map.merge(b, %{product_code: params["product_code"]})
    end)
  end

  def confirm_heat_pass(conn, params) do
    run(conn, params, :confirm_heat_pass, fn b ->
      Map.merge(b, %{line_id: params["line_id"]})
    end)
  end

  def transfer_to_tank(conn, params) do
    run(conn, params, :transfer_to_tank, fn b ->
      Map.merge(b, %{
        tank_id: params["tank_id"],
        from: params["from"],
        previous_batch: blank_to_nil(params["previous_batch"]),
        heel_present: params["heel_present"] == "true"
      })
    end)
  end

  def declare_interface(conn, params) do
    run(conn, params, :declare_interface, fn b ->
      Map.merge(b, %{
        interface_id: params["interface_id"],
        product_a: params["product_a"],
        product_b: params["product_b"],
        from_batch: blank_to_nil(params["from_batch"]),
        to_batch: blank_to_nil(params["to_batch"]),
        destination: blank_to_nil(params["destination"])
      })
    end)
  end

  def start_filling(conn, params) do
    run(conn, params, :start_filling, fn b ->
      Map.merge(b, %{line_id: params["line_id"], filler_id: params["filler_id"]})
    end)
  end

  def record_short_stop(conn, params) do
    run(conn, params, :record_short_stop, fn b ->
      Map.merge(b, %{
        reason: params["reason"],
        origin: if(params["equipment_log_ref"] not in [nil, ""], do: :equipment, else: :operator),
        equipment_log_ref: blank_to_nil(params["equipment_log_ref"])
      })
    end)
  end

  def resume_line(conn, params) do
    run(conn, params, :resume_line, fn b ->
      Map.merge(b, %{stop_event_id: params["stop_event_id"]})
    end)
  end

  def register_sample(conn, params) do
    run(conn, params, :register_sample, fn b ->
      lineage =
        params["lineage"]
        |> Kernel.||("")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)

      Map.merge(b, %{
        sample_no: params["sample_no"],
        sample_type: String.to_existing_atom(params["sample_type"]),
        lineage: lineage
      })
    end)
  end

  def close_deviation(conn, params) do
    run(conn, params, :close_deviation, fn b ->
      Map.merge(b, %{
        deviation_id: params["deviation_id"],
        disposition: params["disposition"]
      })
    end)
  end

  def acknowledge_backfill(conn, params) do
    refs =
      params
      |> Map.get("anomaly_refs", "")
      |> String.split(";", trim: true)
      |> Enum.map(fn pair ->
        [a, b] = pair |> String.split("|") |> Enum.map(&String.trim/1)
        {a, b}
      end)

    run(conn, params, :acknowledge_backfill, fn b ->
      Map.put(b, :anomaly_refs, refs)
    end)
  end

  defp run(conn, params, command, build) do
    case base(conn, params) do
      {:ok, b} ->
        command_map = build.(b)

        case Service.submit(command, command_map) do
          {:ok, _events} ->
            conn
            |> put_flash(:info, "事实已确认并追加：#{command}")
            |> redirect_back(params)

          {:error, reason} ->
            conn
            |> put_resp_content_type("text/plain")
            |> send_resp(409, "事实确认被拒绝：#{inspect(reason)}")
        end

      {:error, reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "请求被拒绝：#{inspect(reason)}")
    end
  end

  defp redirect_back(conn, params) do
    page = (params["page"] in ~w(heat buffer filler) && params["page"]) || "filler"

    redirect(conn,
      to: "/stations/#{page}?batch_id=#{URI.encode_www_form(params["batch_id"] || "")}"
    )
  end

  defp parse_time(nil), do: DateTime.utc_now()

  defp parse_time(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(v), do: v
end
