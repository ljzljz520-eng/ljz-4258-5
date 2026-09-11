defmodule UhtBatch.Domain.Event do
  @moduledoc """
  批次事实事件。事件一经写入 EventStoreDB 即不可变（append-only）。

  本系统**不记录无菌操作参数**（温度、压力、流量、保持时间等由设备
  /既有批记录保存）；此处仅保存“按批准记录确认的事实”。
  """

  @enforce_keys [:id, :type, :batch_id, :occurred_at, :recorded_at, :payload]
  defstruct [
    :id,
    :type,
    :batch_id,
    :occurred_at,
    :recorded_at,
    :source,
    :correlation_id,
    :operator_id,
    :payload,
    :raw_equipment_log
  ]

  @typedoc """
  - `occurred_at`  事实实际发生时间（操作员按批准记录填写，或设备时间戳）
  - `recorded_at`  平台接收/写入时间（由时钟注入，便于确定性测试）
  - `source`       `:operator`（人工确认） | `:equipment`（NATS 只读状态）
  """
  @type t :: %__MODULE__{
          id: String.t(),
          type: event_type(),
          batch_id: String.t(),
          occurred_at: DateTime.t(),
          recorded_at: DateTime.t(),
          source: :operator | :equipment | :system,
          correlation_id: String.t() | nil,
          operator_id: String.t() | nil,
          payload: map(),
          raw_equipment_log: map() | nil
        }

  @type event_type ::
          :pretreatment_confirmed
          | :heat_treatment_passed
          | :transfer_started
          | :tank_occupied
          | :interface_declared
          | :filling_started
          | :line_short_stop
          | :line_resumed
          | :pack_roll_registered
          | :roll_changeover_confirmed
          | :splice_failure_recorded
          | :splice_failure_disposed
          | :splice_segment_reviewed
          | :deviation_opened
          | :deviation_closed
          | :sample_registered
          | :sample_rejected
          | :backfill_acknowledged
          | :production_signed_off
          | :quality_signed_off
          | :equipment_status_received

  @doc "所有由操作员确认、构成连续链的事件类型。"
  def chain_types do
    [
      :pretreatment_confirmed,
      :heat_treatment_passed,
      :transfer_started,
      :tank_occupied,
      :interface_declared,
      :filling_started,
      :line_short_stop,
      :line_resumed,
      :pack_roll_registered,
      :roll_changeover_confirmed,
      :splice_failure_recorded,
      :splice_failure_disposed,
      :splice_segment_reviewed,
      :deviation_opened,
      :deviation_closed,
      :sample_registered,
      :sample_rejected,
      :backfill_acknowledged,
      :production_signed_off,
      :quality_signed_off
    ]
  end
end
