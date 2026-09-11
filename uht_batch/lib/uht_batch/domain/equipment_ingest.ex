defmodule UhtBatch.Domain.EquipmentIngest do
  @moduledoc """
  NATS 隔离设备消息的只读翻译层。

  安全约束：
    * 白名单字段 + 允许的设备状态集合；
    * 任何疑似控制字段（command/setpoint/open/close/start/stop/valve...）拒绝；
    * 设备“短停”信号只生成设备状态事实与“待操作员确认”偏差，
      **不会**自动生成 line_short_stop 链事件，更不会操作设备。
  """

  alias UhtBatch.Domain.Event

  @allowed_devices ~w(valve_bank aseptic_tank filler filler_line uht_hold uht)

  @allowed_status %{
    "valve_bank" => ~w(closed open idle isolated),
    "aseptic_tank" => ~w(ready filling holding emptied cleaned isolated),
    "filler" => ~w(idle running short_stop fault isolated),
    "filler_line" => ~w(idle running short_stop fault isolated),
    "uht_hold" => ~w(heating holding idle fault),
    "uht" => ~w(heating holding idle fault)
  }

  @control_markers ~w(command cmd setpoint target actuate open_valve close_valve
    start stop control write execute command_id control_mode)

  @spec translate(subject :: String.t(), payload :: map(), now :: DateTime.t()) ::
          {:ok, Event.t()}
          | {:ok, Event.t(), :pending_operator_confirmation}
          | {:error, term()}
  def translate(subject, payload, now) when is_map(payload) do
    with :ok <- reject_control_fields(payload),
         {:ok, device_id, device_type} <- parse_subject(subject),
         :ok <- validate_device(device_type),
         {:ok, status} <- validate_status(device_type, payload["status"] || payload[:status]),
         {:ok, batch_id} <- fetch_batch(payload) do
      occurred = parse_time(payload["occurred_at"] || payload[:occurred_at]) || now

      evt = %Event{
        id: "eq_#{:erlang.unique_integer([:positive, :monotonic])}",
        type: :equipment_status_received,
        batch_id: batch_id,
        occurred_at: occurred,
        recorded_at: now,
        source: :equipment,
        correlation_id: payload["log_ref"] || payload[:log_ref],
        operator_id: nil,
        payload: %{
          device_id: device_id,
          device_type: device_type,
          status: status,
          subject: subject
        },
        raw_equipment_log: sanitize_raw(payload)
      }

      if status == "short_stop" do
        {:ok, evt, :pending_operator_confirmation}
      else
        {:ok, evt}
      end
    end
  end

  def translate(_subject, _payload, _now), do: {:error, :payload_must_be_map}

  ## NATS subject 约定：uht.status.<device_type>.<device_id>
  defp parse_subject("uht.status." <> rest) do
    case String.split(rest, ".") do
      [device_type, device_id | _] -> {:ok, device_id, device_type}
      _ -> {:error, :invalid_subject}
    end
  end

  defp parse_subject(_), do: {:error, :invalid_subject}

  defp validate_device(type) when type in @allowed_devices, do: :ok
  defp validate_device(_), do: {:error, :device_not_allowed}

  defp validate_status(type, status) when is_binary(status) do
    if status in Map.fetch!(@allowed_status, type),
      do: {:ok, status},
      else: {:error, {:status_not_allowed, status}}
  end

  defp validate_status(_, _), do: {:error, :missing_status}

  defp fetch_batch(payload) do
    case payload["batch_id"] || payload[:batch_id] do
      b when is_binary(b) and b != "" -> {:ok, b}
      _ -> {:error, :missing_batch_id}
    end
  end

  defp parse_time(nil), do: nil

  defp parse_time(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp reject_control_fields(payload) do
    keys = payload |> Map.keys() |> Enum.map(&to_string/1)

    case Enum.find(keys, &control_key?/1) do
      nil -> :ok
      key -> {:error, {:control_field_rejected, key}}
    end
  end

  defp control_key?(key) do
    normalized = String.downcase(key)
    Enum.any?(@control_markers, &String.contains?(normalized, &1))
  end

  defp sanitize_raw(payload) do
    payload
    |> Map.reject(fn {k, _} -> control_key?(to_string(k)) end)
  end
end
