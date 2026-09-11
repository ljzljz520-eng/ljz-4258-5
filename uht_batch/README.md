# UhtBatch —— UHT 乳品连续链批次事件追溯

超高温乳品“**热处理 → 无菌缓冲 → 灌装**”连续链的批次事实追溯系统。
操作员按**批准记录确认实际事件**，平台把事实以不可变事件方式追加到
EventStoreDB，NATS 侧仅接收**隔离设备的只读状态**，生产/质量签署通过
**WebAuthn** 完成。平台核查界面段、时间与样品谱系，**不控制阀阵或灌装机**。

> 本系统不提供、不保存、也不推断任何**无菌操作参数**（温度、压力、流量、
> 保持时间等）；这些由设备与既有批记录保存。

## 边界与安全设计

| 边界 | 设计 |
| --- | --- |
| 只追加，不修改 | 所有事实写入 EventStoreDB 追加流；不存在更新/删除 API |
| 设备只读 | NATS 适配器只有订阅函数，模块内无任何 `publish`；消息经白名单（设备/状态）翻译，任何 `command/setpoint/open/close/start/stop/valve` 等控制字段直接拒绝 |
| 事实需确认 | 设备短停信号只生成“待操作员确认”偏差；链事实 `line_short_stop` 必须由操作员按批准记录确认 |
| 签署门禁 | 生产/质量签署均需 WebAuthn 断言；质量在生产之上额外核查商业无菌样品与谱系 |
| 无工艺参数 | 命令字段白名单，页面表单不提供任何工艺参数输入 |

## 事实事件类型

`pretreatment_confirmed` · `heat_treatment_passed` · `transfer_started` ·
`tank_occupied` · `interface_declared` · `filling_started` · `line_short_stop` ·
`line_resumed` · `deviation_opened/closed` · `sample_registered/rejected` ·
`backfill_acknowledged` · `production_signed_off` · `quality_signed_off` ·
`equipment_status_received`（设备只读）。

每个事件含 `occurred_at`（事实发生时间，按记录填写）与 `recorded_at`
（平台写入时间），因此**设备日志补传改变事件顺序**可以被精确识别。

## 核查规则（`UhtBatch.Domain.Checks`）

1. **界面段**：上批底液身份（`DEV-HEEL-UNKNOWN`）、产品界面去向
   （`DEV-IFACE-UNKNOWN`，未澄清前禁止灌装开始）、灌装后才澄清界面（警告）。
2. **时间链**：补传时序倒置（`DEV-BACKFILL-ORDER`，必须确认后才能签署）、
   设备短停未确认、短停未恢复、预处理晚于热处理。
3. **样品谱系**：商业无菌样品数量（质量策略
   `commercial_sterility_samples`）、谱系必须引用本批链事件、
   样品登记时间不得早于其谱系源头、样品编号**全局（跨批次）唯一**
   （专用 `sample-claims` 保留流）。

## 测试场景（与需求一一对应）

```
mix test
# 17 tests, 0 failures
```

1. **无菌罐含上批底液**：身份可追溯时无偏差；身份不明时开偏差并阻断签署，
   经证据核实并关闭后放行（`test/heel_identity_test.exs`）。
2. **产品界面去向不明**：灌装开始被拒；澄清/关闭偏差后继续
   （`test/interface_destination_test.exs`）。
3. **灌装线短停**：NATS 短停 → 待确认偏差；操作员确认并恢复后放行；
   控制字段消息被拒绝（`test/short_stop_test.exs`）。
4. **样品编号重用**：跨批次重用被拒，原谱系不被覆盖；谱系缺口/时间倒挂阻断
   质量签署（`test/sample_reuse_test.exs`）。
5. **设备日志补传改变事件顺序**：生成补传倒置并阻断双方签署，操作员确认后放行；
   顺序正常的日志不误报（`test/backfill_order_test.exs`）。

## 运行

### 离线核心（无任何外部依赖，标准库即可）

仓库不提交 `mix.lock` 时，`mix test` 只编译 `lib/` 核心与内存适配器：

```sh
mix test
```

### 完整环境（EventStoreDB / NATS / WebAuthn / Phoenix）

```sh
mix deps.get
EVENTSTORE_URL=esdb://eventstore:2113 \
NATS_URL=nats://nats:4222 \
WEBAUTHN_MODE=wax \
mix phx.server  # 或 mix run --no-halt
```

工位页面（WebAuthn 会话保护）：

* `GET /stations/heat?batch_id=...`   热处理工位
* `GET /stations/buffer?batch_id=...` 无菌缓冲（含隔离设备只读状态）
* `GET /stations/filler?batch_id=...` 灌装（短停、样品、补传确认、双签署）

## 代码结构

```
lib/uht_batch/domain/        纯函数核心（无外部依赖）
  event.ex                   事件模型
  state.ex                   事件流折叠 + 补传倒置识别
  decide.ex                  命令→事件决策（不变量）
  checks.ex                  界面段/时间/样品谱系核查与签署门禁
  lineage.ex                 跨批次祖先谱系（底液/界面）
  equipment_ingest.ex        NATS 消息白名单翻译（拒绝控制字段）
lib/uht_batch/integrations/  内存/测试适配器（EventStore / NATS / WebAuthn）
lib/uht_batch/pipelines/     NATS 只读订阅管道
lib/uht_batch/service.ex     应用服务门面
lib_integrations/            可选外部适配器（spear / gnat / wax，按 lock 条件编译）
lib_web/                     可选 Phoenix 受控工位（按 lock 条件编译，Bandit）
```

## 不在范围内

* 阀阵/灌装机/热处理设备的任何控制；
* 无菌工艺参数（温度、压力、流量、保持时间）的采集与展示；
* 设备侧鉴权网络隔离本身（由工厂网络与 NATS ACL 保证，本系统只消费只读 subject）。
