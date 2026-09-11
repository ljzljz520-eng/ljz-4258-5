defmodule UhtBatch.MixProject do
  use Mix.Project

  @version "0.1.0"
  @lock Path.expand("mix.lock", __DIR__)

  def project do
    [
      app: :uht_batch,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [ignore_modules: ignore_modules()]
    ]
  end

  def application do
    [
      mod: {UhtBatch.Application, []},
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  # 有 mix.lock 且依赖已拉取时，加入外部适配器与 Phoenix 工位页面；
  # 否则仅编译标准库核心（离线 mix test）。
  defp elixirc_paths do
    base = ["lib"]
    optional = ~w(
      lib_integrations/event_store
      lib_integrations/nats
      lib_integrations/webauthn
      lib_web
    )

    if external_enabled?() do
      base ++ optional
    else
      base
    end
  end

  defp deps do
    if external_enabled?() do
      [
        # EventStoreDB
        {:spear, "~> 1.4", optional: true},
        # NATS（只订阅）
        {:gnat, "~> 1.9", optional: true},
        # WebAuthn
        {:wax_, "~> 0.5", optional: true, app: false},
        {:jason, "~> 1.4", optional: true},
        # Phoenix 受控工位（Bandit，无 cowboy）
        {:phoenix, "~> 1.7", optional: true},
        {:phoenix_html, "~> 4.1", optional: true},
        {:phoenix_live_view, "~> 1.0", optional: true},
        {:bandit, "~> 1.5", optional: true}
      ]
    else
      []
    end
  end

  defp external_enabled?, do: File.exists?(@lock)

  defp ignore_modules do
    [
      UhtBatch.Integrations.SpearEventStore,
      UhtBatch.Integrations.GnatStatusBus,
      UhtBatch.Integrations.WaxAttestation,
      UhtBatchWeb.Router
    ]
  end
end
