defmodule UhtBatch.EventStore do
  @moduledoc """
  事件存储端口。生产环境由 EventStoreDB（Spear）适配器实现；
  测试环境使用内存适配器。系统只做追加读取，不做覆盖与删除。
  """

  alias UhtBatch.Domain.Event

  @type expected :: :any | :stream_exists | non_neg_integer()
  @type stream :: String.t()

  @callback append_batch(term(), stream(), [Event.t()], expected(), term()) ::
              {:ok, [Event.t()]} | {:error, term()}
  @callback read_stream(term(), stream(), term()) :: {:ok, [Event.t()]} | {:error, term()}
  @callback sample_claimed?(term(), String.t(), term()) :: boolean()
end

defmodule UhtBatch.StatusBus do
  @moduledoc """
  隔离设备只读状态端口（NATS）。只消费、不发布；
  系统无法也不会通过该端口向阀阵/灌装机发送任何指令。
  """

  @callback subscribe(subject :: String.t(), handler :: module() | function(), opts :: keyword()) ::
              {:ok, reference()} | {:error, term()}
end

defmodule UhtBatch.Attestation do
  @moduledoc """
  WebAuthn 断言验证端口。生产/质量签署需通过 WebAuthn 证明身份与角色。
  """

  @callback verify_credential_assertion(
              challenge :: binary(),
              assertion :: map(),
              credential :: map(),
              opts :: keyword()
            ) :: {:ok, %{credential_id: binary(), signer_id: String.t()}} | {:error, term()}
end
