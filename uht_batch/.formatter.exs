# 完整环境（存在 mix.lock）时从 phoenix 导入格式化规则；
# 干净检出的离线核心无依赖可读，跳过 import_deps 以免 mix format 报错。
import_deps = if File.exists?(Path.expand("mix.lock", __DIR__)), do: [:phoenix], else: []

[
  inputs: [
    "mix.exs",
    "{config,lib,lib_integrations,lib_web,test}/**/*.{ex,exs}"
  ],
  import_deps: import_deps
]
