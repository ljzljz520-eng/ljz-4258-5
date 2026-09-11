defmodule UhtBatch.Service do
  @moduledoc """
  批次事件应用服务：

  * `submit/3`     操作员按批准记录确认一个事实命令；
  * `ingest_equipment/2` 接收 NATS 隔离设备只读状态；
  * `sign/4`       WebAuthn 生产/质量签署；
  * `snapshot/1`   读取折叠状态与核查结果（工位页面使用）。

  平台只追加事实、执行核查；不控制阀阵或灌装机。
  """

  alias UhtBatch.Domain.{Checks, Decide, EquipmentIngest, Event, Lineage, State}
  alias UhtBatch.Integrations.MemoryEventStore

  @default_config [
    event_store: MemoryEventStore,
    event_store_ref: MemoryEventStore,
    clock: UhtBatch.Clock,
    attestation: UhtBatch.Integrations.FakeAttestation
  ]

  defp es_module(cfg), do: cfg[:event_store]
  defp es_ref(cfg), do: cfg[:event_store_ref] || cfg[:event_store]

  ## 配置 ------------------------------------------------------------------

  defp config(overrides) do
    Keyword.merge(@default_config, Application.get_env(:uht_batch, :service, []))
    |> Keyword.merge(overrides)
  end

  defp stream(batch_id), do: Lineage.batch_stream(batch_id)
  defp claims_stream, do: "sample-claims"

  defp now(cfg) do
    case cfg[:clock] do
      fun when is_function(fun, 0) -> fun.()
      mod when is_atom(mod) -> mod.utc_now()
    end
  end

  ## 读取状态 --------------------------------------------------------------

  @spec snapshot(String.t(), keyword()) ::
          {:ok, %{state: State.t(), findings: list(), events: [Event.t()]}} | {:error, term()}
  def snapshot(batch_id, opts \\ []) do
    cfg = config(opts)

    with {:ok, events} <- es_module(cfg).read_stream(es_ref(cfg), stream(batch_id), opts) do
      state = Enum.reduce(events, State.new(batch_id), &State.apply(&2, &1))
      policy = opts[:policy] || Application.get_env(:uht_batch, :quality_policy, %{})
      {:ok, %{state: state, findings: Checks.all(state, policy), events: events}}
    end
  end

  ## 命令提交 --------------------------------------------------------------

  @spec submit(atom(), map(), keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def submit(command_name, command, opts \\ []) do
    cfg = config(opts)
    command = prepare_command(command, cfg)
    batch_id = Map.fetch!(command, :batch_id)

    with {:ok, events} <- load_and_decide(cfg, command_name, command),
         events <- with_correlation(events, command),
         :ok <- reserve_sample_claims(cfg, events, opts),
         {:ok, stored} <-
           es_module(cfg).append_batch(es_ref(cfg), stream(batch_id), events, :any, opts) do
      {:ok, stored}
    end
  end

  defp load_and_decide(cfg, :register_sample, command) do
    with {:ok, events} <- es_module(cfg).read_stream(es_ref(cfg), stream(command.batch_id), []),
         true <- valid_stream?(events, command.batch_id) do
      state = Enum.reduce(events, State.new(command.batch_id), &State.apply(&2, &1))
      Decide.decide({:register_sample, command}, state, false)
    end
  end

  defp load_and_decide(cfg, name, command) do
    with {:ok, events} <- es_module(cfg).read_stream(es_ref(cfg), stream(command.batch_id), []),
         true <- valid_stream?(events, command.batch_id) do
      state = Enum.reduce(events, State.new(command.batch_id), &State.apply(&2, &1))
      Decide.decide({name, command}, state)
    end
  end

  # 防止误向别的批次流追加（所有事件 batch_id 必须一致）。
  defp valid_stream?(events, batch_id) do
    if Enum.all?(events, &(&1.batch_id == batch_id)),
      do: true,
      else: false
  end

  ## NATS 只读状态摄取 -----------------------------------------------------

  @doc """
  接收一条设备只读状态。短停信号会额外产生“设备短停待确认”偏差事实，
  但不会生成灌装线链事件——必须由操作员在工位页面按批准记录确认。
  """
  @spec ingest_equipment(String.t(), map(), keyword()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def ingest_equipment(subject, payload, opts \\ []) do
    cfg = config(opts)
    now = now(cfg)

    case EquipmentIngest.translate(subject, payload, now) do
      {:ok, %Event{} = evt} ->
        es_module(cfg).append_batch(es_ref(cfg), stream(evt.batch_id), [evt], :any, opts)

      {:ok, %Event{batch_id: batch_id} = evt, :pending_operator_confirmation} ->
        dev = pending_equipment_stop_event(evt, now)
        es_module(cfg).append_batch(es_ref(cfg), stream(batch_id), [evt, dev], :any, opts)

      {:error, _} = err ->
        err
    end
  end

  defp pending_equipment_stop_event(evt, now) do
    %Event{
      id: "dev_#{:erlang.unique_integer([:positive, :monotonic])}",
      type: :deviation_opened,
      batch_id: evt.batch_id,
      occurred_at: evt.occurred_at,
      recorded_at: now,
      source: :equipment,
      correlation_id: evt.correlation_id,
      operator_id: nil,
      payload: %{
        deviation_id: "pendstop_#{:erlang.unique_integer([:positive, :monotonic])}",
        code: Decide.deviation_code(:equipment_short_stop_unconfirmed),
        reason: "设备报告灌装线短停，等待操作员按批准记录确认（日志 #{evt.correlation_id || "-"}）",
        context: %{
          equipment_log_ref: evt.correlation_id,
          device_id: evt.payload.device_id
        }
      },
      raw_equipment_log: evt.raw_equipment_log
    }
  end

  ## WebAuthn 签署 ---------------------------------------------------------

  @spec sign(:production | :quality, String.t(), map(), keyword()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def sign(role, batch_id, assertion, opts \\ []) when role in [:production, :quality] do
    cfg = config(opts)

    with {:ok, %{signer_id: signer_id, credential_id: cred_id}} <-
           verify_assertion(cfg, assertion, role),
         command <- %{
           batch_id: batch_id,
           operator_id: signer_id,
           credential_id: cred_id,
           occurred_at: now(cfg),
           recorded_at: now(cfg),
           policy: opts[:policy] || Application.get_env(:uht_batch, :quality_policy, %{})
         },
         do:
           (case role do
              :production -> submit(:production_signoff, command, opts)
              :quality -> submit(:quality_signoff, command, opts)
            end)
  end

  defp verify_assertion(cfg, assertion, role) do
    challenge = assertion[:challenge] || assertion["challenge"] || fake_challenge(role)

    cfg[:attestation].verify_credential_assertion(
      challenge,
      normalize(assertion),
      %{},
      origin: Application.get_env(:uht_batch, :webauthn_origin, "https://uht.local")
    )
  end

  defp fake_challenge(_), do: :crypto.strong_rand_bytes(32)

  ## 谱系查询 --------------------------------------------------------------

  def ancestors(batch_id, opts \\ []) do
    cfg = config(opts)
    reader = fn sid -> es_module(cfg).read_stream(es_ref(cfg), sid, opts) end
    Lineage.ancestors(batch_id, reader)
  end

  ## 内部帮助 --------------------------------------------------------------

  defp prepare_command(command, cfg) do
    command
    |> normalize()
    |> Map.put_new(:recorded_at, now(cfg))
    |> Map.update!(:occurred_at, fn
      %DateTime{} = dt -> dt
      s when is_binary(s) -> parse_dt!(s)
    end)
  end

  defp normalize(%_{} = struct), do: struct

  defp normalize(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {safe_atom(k), normalize(v)}
      {k, v} when is_atom(k) -> {k, normalize(v)}
    end)
  end

  defp normalize(other), do: other

  # 仅允许已知键转 atom，未知键保留字符串，避免外部数据 atom 泄漏。
  @known_command_keys ~w(
    batch_id operator_id occurred_at recorded_at record_ref product_code line_id
    tank_id from previous_batch heel_present interface_id product_a product_b
    to_batch destination filler_id reason origin equipment_log_ref stop_event_id
    sample_no sample_type lineage deviation_id disposition anomaly_refs
    credential_id correlation_id challenge source event_id policy context code
  )

  defp safe_atom(key) do
    if key in @known_command_keys, do: String.to_existing_atom(key), else: key
  end

  defp parse_dt!(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> raise ArgumentError, "invalid occurred_at: #{inspect(s)}"
    end
  end

  defp with_correlation(events, command) do
    Enum.map(events, fn e ->
      %{e | correlation_id: e.correlation_id || command[:correlation_id]}
    end)
  end

  # 样品编号全局保留：claims 流 append 时强制唯一（跨批次重用被拒绝）。
  defp reserve_sample_claims(cfg, events, opts) do
    claims =
      events
      |> Enum.filter(&(&1.type == :sample_registered))
      |> Enum.map(fn e ->
        %Event{e | id: "claim_#{:erlang.unique_integer([:positive, :monotonic])}"}
      end)

    case claims do
      [] ->
        :ok

      list ->
        with {:ok, _} <-
               es_module(cfg).append_batch(es_ref(cfg), claims_stream(), list, :any, opts),
             do: :ok
    end
  end
end
