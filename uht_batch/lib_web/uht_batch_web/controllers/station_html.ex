defmodule UhtBatchWeb.StationHTML do
  @moduledoc false
  use UhtBatchWeb, :html

  # 模板目录相对本文件所在目录（controllers/）解析；
  # 通配符需匹配 .html.heex 文件本身，模板名由 Phoenix.Template 推导。
  embed_templates "../templates/station/*"
end
