defmodule UhtBatchWeb.ErrorHTML do
  @moduledoc false
  use UhtBatchWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
