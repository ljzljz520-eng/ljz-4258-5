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
`line_resumed` · `pack_roll_registered` · `roll_changeover_confirmed` ·
`splice_failure_recorded` · `splice_failure_disposed` ·
`splice_segment_reviewed` ·
`deviation_opened/closed` · `sample_registered/rejected`（含 `splice` 接头样）·
`backfill_acknowledged` · `production_signed_off` · `quality_signed_off` ·
`equipment_status_received`（设备只读，含接头机 `splice_detected/splice_failed`）。

每个事件含 `occurred_at`（事实发生时间，按记录填写）与 `recorded_at`
（平台写入时间），因此**设备日志补传改变事件顺序**可以被精确识别。

## 包装材料卷切换

每卷包装材料必须先登记**身份**（卷号、物料编码、实物标签核对结论）：
标签与批准记录不符即开 `DEV-ROLL-LABEL`，核实重贴关闭前该卷不得上线。

换卷由操作员按批准记录确认 `roll_changeover_confirmed`：**接头时点**与
**接头前后成品序列号**（`seq_before`/`seq_after`）共同确定接头区间，
材料卷身份与成品序列由此形成区间（`State.roll_intervals/1`）。

* 接头区间**默认待复核**（`DEV-SPLICE-PENDING`），只能由质量按
  `splice_seq` **逐段**复核（接受/隔离）；任何整批一并放行都被拒绝
  （`whole_batch_release_not_allowed`），不能沿用“整批合格”结论。
* 每个接头段接受前必须有**接头样**（`sample_type=splice`，谱系引用该接头
  确认事件），缺失为 `DEV-SPLICE-SAMPLE-MISSING`；判隔离的段不要求接头样，
  仅保留警告并列出隔离序列号。
* 接头传感器（NATS 只读 `packaging_splicer`）信号只生成设备事实与
  “待操作员确认”偏差 `DEV-EQ-SPLICE-UNCONFIRMED`，**不自动**构成换卷事实；
  迟报信号早于链末端时同时产生补传时序倒置，确认倒置后才能签署。
* 两卷**并接失败**记录为 `splice_failure_recorded` + `DEV-SPLICE-FAIL`，
  失败区间默认隔离；质量处置（重试/隔离/返工）后失败闭环，重试产生新
  `splice_seq` 的成功接头。
* 卷切换**恰逢产品界面**：按显式 `interface_id` 或时间窗（默认 ±300s）识别；
  界面去向未澄清时开 `DEV-ROLL-IFACE`，澄清界面前该接头段禁止接受。

## 核查规则（`UhtBatch.Domain.Checks`）

1. **界面段**：上批底液身份（`DEV-HEEL-UNKNOWN`）、产品界面去向
   （`DEV-IFACE-UNKNOWN`，未澄清前禁止灌装开始）、灌装后才澄清界面（警告）。
2. **时间链**：补传时序倒置（`DEV-BACKFILL-ORDER`，必须确认后才能签署）、
   设备短停未确认、短停未恢复、预处理晚于热处理。
3. **样品谱系**：商业无菌样品数量（质量策略
   `commercial_sterility_samples`）、谱系必须引用本批链事件、
   样品登记时间不得早于其谱系源头、样品编号**全局（跨批次）唯一**
   （专用 `sample-claims` 保留流）；接头段还须有谱系引用接头确认事件的
   接头样。
4. **材料卷切换**：标签异常（`DEV-ROLL-LABEL`）、设备接头信号待确认
   （`DEV-EQ-SPLICE-UNCONFIRMED`）、并接失败未处置（`DEV-SPLICE-FAIL`）、
   接头段待复核（`DEV-SPLICE-PENDING`，质量门禁）、接头段缺接头样
   （`DEV-SPLICE-SAMPLE-MISSING`，质量门禁）、接头叠加未澄清界面
   （`DEV-ROLL-IFACE`）。

## 测试场景（与需求一一对应）

```
mix test
# 30 tests, 0 failures
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
6. **包装材料卷切换**（`test/pack_roll_changeover_test.exs`）：
   * 材料卷标签错：开偏差、阻断换卷/签署，核实重贴关闭后方可换卷；
   * 接头传感器迟报：待确认偏差 + 补传倒置，人工确认与逐段复核后放行；
   * 两卷并接失败：失败事实 + 偏差阻断，区间隔离/返工、重试成功并逐段复核；
   * 接头段样品缺失：阻断逐段接受与质量放行，补接头样（谱系引用接头事件）后通过；
   * 卷切换恰逢产品界面：未澄清界面叠加阻断该段，澄清后逐段接受；
   * 整批一并复核被拒；拒绝段隔离且无需接头样；设备通道控制字段被拒。

## 运行

### 离线核心（默认检出路径，无网络、无外部依赖）

仓库**不提交** `mix.lock` 与 `deps/`。干净检出下 `mix.exs` 只声明标准库
核心（`lib/` + 内存适配器），`mix test` 全程不需要网络：

```sh
mix test
# 30 tests, 0 failures
```

### 完整环境（EventStoreDB / NATS / WebAuthn / Phoenix）

`mix deps.get` 需要网络：拉取依赖并在本地生成 `mix.lock`
（lock 已被 `.gitignore` 忽略，不会提交）。lock 存在时 `mix.exs`
自动把 `lib_integrations/` 与 `lib_web/` 纳入编译：

```sh
mix deps.get
EVENTSTORE_URL=esdb://eventstore:2113 \
NATS_URL=nats://nats:4222 \
WEBAUTHN_MODE=wax \
mix phx.server  # 或 mix run --no-halt
```

三个变量由 `config/runtime.exs` 在**每次启动时**读取，注入
`UhtBatch.Service` 读取的 `:service` 配置与应用监督树；不设置则以
内存/测试适配器启动（工位页面仍可离线访问）：

| 变量 | 作用 |
| --- | --- |
| `EVENTSTORE_URL` | 事件存储切换为 Spear/EventStoreDB，并按该 URL 启动连接（断线自动重连） |
| `NATS_URL` | 启动 gnat 只读订阅连接，设备状态管道开始消费 `uht.status.>` |
| `WEBAUTHN_MODE=wax` | WebAuthn 断言验证切换为 wax_（默认 Fake 适配器仅供开发/测试） |

工位页面（WebAuthn 会话保护）：

* `GET /stations/heat?batch_id=...`   热处理工位
* `GET /stations/buffer?batch_id=...` 无菌缓冲（含隔离设备只读状态）
* `GET /stations/filler?batch_id=...` 灌装（短停、材料卷切换/接头段逐段复核、样品、补传确认、双签署）

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
