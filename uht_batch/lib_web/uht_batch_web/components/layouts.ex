defmodule UhtBatchWeb.Layouts do
  @moduledoc false
  use UhtBatchWeb, :html

  def render("app.html", assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="zh-CN">
      <head>
        <meta charset="utf-8" />
        <meta name="robots" content="noindex,nofollow" />
        <meta name="referrer" content="no-referrer" />
        <title>UHT 批次受控工位</title>
      </head>
      <body>
        <header>
          <nav>
            <a href="/stations/heat?batch_id={@batch_id}">热处理工位</a> |
            <a href="/stations/buffer?batch_id={@batch_id}">无菌缓冲工位</a> |
            <a href="/stations/filler?batch_id={@batch_id}">灌装工位</a>
          </nav>
          <p class="signer">签署人：<%= @conn.assigns[:signer_id] %></p>
        </header>
        <main>{render_slot(@inner_block)}</main>
        <footer>只读追溯/事实确认系统 — 不连接阀阵或灌装机的控制通道</footer>
      </body>
    </html>
    """
  end
end
