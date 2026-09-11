defmodule UhtBatch.Clock do
  @moduledoc "可注入时钟，便于确定性测试。"
  def utc_now, do: DateTime.utc_now()

  @doc "测试辅助：固定时钟。"
  def fixed(%DateTime{} = dt), do: fn -> dt end
end
