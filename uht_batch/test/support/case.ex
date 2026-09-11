defmodule UhtBatch.DataCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      alias UhtBatch.Factory
      import UhtBatch.DataCase
    end
  end

  setup do
    store_name = :"Store#{:erlang.unique_integer([:positive, :monotonic])}"
    start_supervised!({UhtBatch.Integrations.MemoryEventStore, name: store_name})

    fixed_now = ~U[2026-09-10T12:00:00Z]
    clock = fn -> fixed_now end

    opts = [
      event_store: UhtBatch.Integrations.MemoryEventStore,
      event_store_ref: store_name,
      clock: clock
    ]

    {:ok, store: store_name, opts: opts, clock: clock}
  end

  ## 走通“预处理 -> 热处理 -> 转罐 -> 灌装”标准链
  def establish_chain(batch_id, opts, overrides \\ %{}) do
    pre = Map.merge(UhtBatch.Factory.pretreatment(batch_id), overrides[:pretreatment] || %{})
    heat = Map.merge(UhtBatch.Factory.heat_pass(batch_id), overrides[:heat] || %{})
    transfer0 = UhtBatch.Factory.transfer(batch_id, overrides[:transfer_opts] || [])
    transfer = Map.merge(transfer0, overrides[:transfer] || %{})
    fill = Map.merge(UhtBatch.Factory.filling(batch_id), overrides[:filling] || %{})

    {:ok, _} = UhtBatch.Service.submit(:confirm_pretreatment, pre, opts)
    {:ok, heat_events} = UhtBatch.Service.submit(:confirm_heat_pass, heat, opts)
    {:ok, _} = UhtBatch.Service.submit(:transfer_to_tank, transfer, opts)
    {:ok, _} = UhtBatch.Service.submit(:start_filling, fill, opts)

    {:ok, %{heat_events: heat_events, transfer: transfer, fill: fill}}
  end
end
