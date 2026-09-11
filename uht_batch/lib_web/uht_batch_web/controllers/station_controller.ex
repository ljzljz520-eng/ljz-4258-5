defmodule UhtBatchWeb.StationController do
  @moduledoc "受控工位只读页面：展示事实链、核查结果与隔离设备只读状态。"
  use UhtBatchWeb, :controller

  defp load(conn) do
    batch_id = conn.params["batch_id"] || conn.assigns[:batch_id] || ""
    snap = if batch_id != "", do: UhtBatch.Service.snapshot(batch_id) |> elem(1), else: empty()
    {batch_id, snap}
  end

  defp empty, do: %{state: nil, findings: [], events: []}

  def heat(conn, _params) do
    {batch_id, snap} = load(conn)
    render(conn, :heat, batch_id: batch_id, snap: snap, page: :heat)
  end

  def buffer(conn, _params) do
    {batch_id, snap} = load(conn)
    render(conn, :buffer, batch_id: batch_id, snap: snap, page: :buffer)
  end

  def filler(conn, _params) do
    {batch_id, snap} = load(conn)

    render(
      conn,
      :filler,
      [batch_id: batch_id, snap: snap, page: :filler] ++ blockers_assigns(snap)
    )
  end

  defp blockers_assigns(snap) do
    production_blockers =
      if snap.state,
        do: UhtBatch.Domain.Checks.blockers_for(:production, snap.state),
        else: []

    quality_blockers =
      if snap.state,
        do: UhtBatch.Domain.Checks.blockers_for(:quality, snap.state),
        else: []

    [
      production_blockers: production_blockers,
      quality_blockers: quality_blockers
    ]
  end
end
