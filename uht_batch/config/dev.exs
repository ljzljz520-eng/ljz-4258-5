import Config

# 开发环境配置。
# EVENTSTORE_URL / NATS_URL / WEBAUTHN_MODE 的适配器切换在
# config/runtime.exs 中于每次启动时求值（编译期配置无法跟踪环境变量变化）。
