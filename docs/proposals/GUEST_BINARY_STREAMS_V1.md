---
project: GaoVM
title: Guest binary stream v1 契约
document: protocol-contract
status: accepted
accepted: true
accepted_on: 2026-10-10
target_work_packages: ["023", "024", "025"]
updated: 2026-10-11
---

# Guest binary stream v1 契约

用户于 2026-10-10 批准本文与 [private driver bridge 契约](GUEST_DRIVER_BRIDGE_V1.md)。
本文冻结下述独立 binary wire 与 trust boundary；不证明 native vsock 或完整 Guest Agent 已实现。
实施时保持既有 M0 control framing、guest/driver schema 与 public API 不变。
原实现基线 e4f6bed 包含 async control negotiation。现在增加独立 schema、golden header 与
Rust framing、control epoch、grant/ACK、P0 dispatcher/sealed-source、owned control coordinator 与 Linux resident entrypoint。
driver/daemon 通路与 durable host publication 已有实现及 Unix 组件验证，真实 Rust guest → Dart host
也已验证 durable commit-before-ACK。installed/native service acceptance 仍未完成，不能将组件测试视为完整 binary transfer acceptance。

## 1. 范围与已核实缺口

对应 PRD GST-002、GST-006、TST-006，以及开发计划 M6.2、M6.5、M6.7。
既有控制面保持 gaovm.guest.v1：4-byte big-endian length + 单个 UTF-8 JSON object；
仍禁止 batch 和 base64 artifact body。P1 upload/download 不属于本文。

| 当前事实 | 对实现的影响 |
|---|---|
| artifact.collect 返回的 artifactDescriptor 包含 stream_id、digest、size_bytes | 需要定义 stream 如何建立、绑定和结束 |
| execResult 的 artifact outputReference 只有 artifact_id、size_bytes | 不能假定 exec.status 已提供 digest 或 stream_id |
| event 仅支持 exec.state_changed、guest.warning，payload 禁止额外字段 | 不能偷偷添加 artifact.ready 或把 metadata 塞进 message |
| Executor/ArtifactCollector 提供本地 sealed spool 和 release，不是 wire transfer | 文件存在或本地 SHA-256 不等于 host 已收取、持久化 |
| driver v2 有 guest.status/channel_ready，没有已冻结的 channel-open/bridge 身份协议 | 本提案不能单独证明 daemon 已有可用、安全的 vsock 通路 |

来源：[guest schema](../../schemas/guest-protocol/v1.schema.json)、
[driver schema](../../schemas/driver-protocol/v2.schema.json)、
[guest library scope](../../guest/gaovm_guestd/README.md)。
独立 grammar/golden header 见 [binary schema](../../schemas/guest-binary/v1.schema.json)；
schema 与 framing 组件不证明 runtime session/grant、durable publish 或 native acceptance。

## 2. 已接受决策

在既有 guest_agent.vsock_port 上使用独立 binary connection；默认端口仍是
VmSpec 已定义的 10777。每条 binary connection 只传一个 sealed artifact。
binary framing 使用独立版本 gaovm.binary.v1，不增加现有 control method、
capability、event 或 outputReference 字段。

| 方案 | 代价/边界 |
|---|---|
| 同端口、独立 connection、版本化 binary preface（建议） | 增加一个有界 accept demultiplexer；不增加 VmSpec/driver port 字段 |
| 独立 binary port | 分流更直接，但需要先批准新的配置、传递和兼容契约 |
| 同一 control connection 内混入 bytes/base64 | 不采用：违反独立 binary stream 边界，也会阻塞控制面 |

控制面和 binary 面仍经过同一 VM、同一 driver generation 的 driver-owned bridge。
daemon 不调用 Virtualization.framework；public API 不暴露 bridge、stream handle 或 driver passthrough。

## 3. Trust 与 session binding

以下是已接受的授权模型，不是已验证的平台安全结论：

1. Swift driver 仅为已通过 per-generation token 验证的 daemon 建立私有 bridge；
   每个额外 bridge connection 也必须验证调用者，不能只认证最初的 driver RPC。
   bridge endpoint 必须属于该 VM/generation，不能使用其他 VM 的共享全局入口。
2. Linux guest 在读取 preface 前检查 native peer CID，只允许 VMADDR_CID_HOST。
   Linux UAPI 定义该值为 2；它标识 host，不标识 host 上的某个用户或进程。
   [Linux UAPI](https://raw.githubusercontent.com/torvalds/linux/master/include/uapi/linux/vm_sockets.h)
3. guest 必须已有完成双向 hello 的 control session。每次 control connection 建立一个
   内部 session epoch；所有 grant 和 active transfer 绑定 epoch、vm_id、
   driver_generation、operation_id、guest artifact_id。
4. grant 只能由该 session 已授权的 artifact.collect 或 terminal exec.status 响应产生，
   并在响应 flush 成功后生效。未完成/失败的响应不能发布可用 grant。
   host 在 flush/admission 的交界遇到未激活 grant 时，只能在原 operation deadline
   内有界重取 metadata/重试 transfer，不能重执行 exec.start。
5. stream_id 是 guest 生成的 32-byte CSPRNG 值的 64-character lowercase hex 表示，
   作为有界 registry handle；它不是密码，不替代 peer/bridge/session 授权，也不得公开到 public API。
6. binary handler 不接受路径，不扫描文件系统猜测 artifact，不访问任意 guest 文件。
   它只解析当前 grant 对应的 sealed spool。

host CID 检查本身不足以支持共享 CID 的任意第三方 host backend。若 driver-owned
私有 bridge 无法保证上述调用者身份隔离，必须先增加并批准显式 authentication/
channel-binding 契约，不能宣称本提案已解决该环境的进程级认证。

generic image 不预埋 VM ID/generation。guest 仅在没有 active control session 时，
从已验证 host peer 的第一个合法 host hello 接受 binding，再创建显式 Session、
flush host hello acknowledgement，并完成 guest hello。已有 binding 不能在原连接中重写。
`ControlSlot` 的 host-first bootstrap 已有独立 Unix socket 测试；现有 negotiate helper
本身不执行 native peer 检查或 binding adoption。`GuestResources::bootstrap` 现通过 counted
owned worker 在 guest hello/ACK 前初始化 core handler/resource；初始化失败不发 readiness
bytes，取消后同一 opening 不能换 framing halves/deadline 重试，真实 worker 与被丢弃的
engine result cleanup 完成前不能复用 slot。native coordinator 必须使用该初始化路径，
不能将协议 hello 完成或旧 `bind` 路径当作 service readiness。

## 4. Connection framing

### 4.1 Host → guest：open

```text
4 bytes: ASCII GAB1 (47 41 42 31)
4 bytes: unsigned big-endian JSON header length H
H bytes: UTF-8 open object
```

H 必须在 1..4096 bytes，且必须先验证 length 再分配/解析。
拒绝 duplicate/unknown fields、batch、非 object、无效 UTF-8、无效 correlation、
无效 selector 和 version。所有 header 的 encoded size 都使用同一 4096-byte 上限。

acceptor 只读前四 bytes：GAB1 进入 binary parser；合法 1..16 MiB control length
连同这四 bytes 交还 control decoder，不能丢弃 header。其他值直接关闭。
GAB1 的数值大于 control frame 上限，不存在合法 control length 冲突。
未知 GAB2 等 magic 不得降级成 control 或无版本 raw stream。

### 4.2 Guest → host：ready/body/end

```text
u32be H + H-byte ready JSON
repeated: u32be L + L raw bytes, where 1 <= L <= 8192
u32be 0: end marker
```

body 是原始 bytes，不是 JSON/base64。累计 body size 必须恰好等于 ready 的 size_bytes；
零字节 artifact 直接发送 end marker。host 在每个 chunk 前验证 length、remaining
budget，再读取固定上限 buffer；超过声明 size、提前 end、截断 chunk 都失败。
end 是 body 的终点，之后的 bytes 不属于 artifact；receiver 不解析或发布它们。
此 framing 不依赖 native socket half-close，也不等待 EOF 来判定 body 完成。

### 4.3 Host → guest：commit acknowledgement

host 收齐、验证并 durable publish 后，发送 u32be H + H-byte committed JSON。
guest 验证完整 correlation、stream_id、size 和 digest 后关闭该 transfer。
之后双方关闭 binary connection；control connection 不受正常 transfer 完成影响。
没有 committed acknowledgement，不能把传输视为 host 已接收。

open 失败时，guest 返回一个有界 error header 并关闭 connection，不发送 body。
body/verification/commit 阶段失败则关闭当前 binary connection，丢弃 host partial stage；
不能在失败连接上重同步。

## 5. 两种 source selector

所有 open/ready/committed object 只允许各自定义的字段，protocol_version 必须严格相等，
driver_generation 必须为正整数，operation_id 必须非 null；ID 语法复用 frozen guest schema。

### 5.1 artifact.collect

control response 保持 frozen artifactDescriptor 形状。例如 bytes 为 UTF-8 hello world：

```json
{
  "protocol_version": "gaovm.guest.v1",
  "kind": "response",
  "id": "collect-1",
  "method": "artifact.collect",
  "vm_id": "vm_01J00000000000000000000000",
  "driver_generation": 8,
  "operation_id": "op_01J00000000000000000000001",
  "result": {
    "artifacts": [{
      "artifact_id": "art_01J00000000000000000000002",
      "kind": "result",
      "content_type": "application/octet-stream",
      "size_bytes": 11,
      "digest": "sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
      "stream_id": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }]
  }
}
```

host 发起的 binary open：

```json
{
  "protocol_version": "gaovm.binary.v1",
  "kind": "open",
  "vm_id": "vm_01J00000000000000000000000",
  "driver_generation": 8,
  "operation_id": "op_01J00000000000000000000001",
  "artifact_id": "art_01J00000000000000000000002",
  "source": {
    "kind": "collection",
    "stream_id": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }
}
```

registry 必须同时匹配整个 binding 和 collection stream_id。返回的 ready.artifact
必须与 control descriptor 的所有字段一致，不能在传输时改成另一个 source 的 metadata。
source 只允许 kind、stream_id；不接受 paths。

### 5.2 Exec spill

frozen exec.status 仍只返回 outputReference。例如 inline threshold 小于 11 bytes：

```json
{
  "protocol_version": "gaovm.guest.v1",
  "kind": "response",
  "id": "exec-status-1",
  "method": "exec.status",
  "vm_id": "vm_01J00000000000000000000000",
  "driver_generation": 8,
  "operation_id": "op_01J00000000000000000000001",
  "result": {
    "state": "succeeded",
    "exit_code": 0,
    "stdout": {"mode": "artifact", "artifact_id": "art_01J00000000000000000000002", "size_bytes": 11},
    "stderr": {"mode": "inline", "text": "", "truncated": false, "size_bytes": 0},
    "duration_ms": 100,
    "timed_out": false,
    "signal": null
  }
}
```

binary side 负责解析 metadata，不添加 artifact.get control method 或 virtual path：

```json
{
  "protocol_version": "gaovm.binary.v1",
  "kind": "open",
  "vm_id": "vm_01J00000000000000000000000",
  "driver_generation": 8,
  "operation_id": "op_01J00000000000000000000001",
  "artifact_id": "art_01J00000000000000000000002",
  "source": {"kind": "exec_output", "output": "stdout"}
}
```

source 只允许 kind、output，output 仅 stdout/stderr。必须已有当前 session 的 terminal
exec.status grant，指定 output 必须为 artifact mode，且其 artifact_id/size 与 sealed
output 匹配。不能拿任意 op/artifact ID 查询全局存储，不能从 inline reference 下载。

guest 在 seal 阶段计算并保留 digest，不能在每次 transfer 临时重读源文件来掩盖
source 已变化。当前 library 的 `Executor::output_artifact` 已提供 capture-time SHA-256、
ID、kind、content type 和 size 的本地 metadata，并受原 session/VM/generation/op 检查约束。
它本身不是 wire descriptor，没有 stream_id。`grants::GrantRegistry` 现在仅在同一
opaque control epoch 的 terminal status response flush 成功后授权相应 output，并在
binary ready 中补充 CSPRNG stream handle；host publication 已有实现，native channel 认证与 installed acceptance 仍需验证。
返回 metadata：

```json
{
  "protocol_version": "gaovm.binary.v1",
  "kind": "ready",
  "vm_id": "vm_01J00000000000000000000000",
  "driver_generation": 8,
  "operation_id": "op_01J00000000000000000000001",
  "artifact": {
    "artifact_id": "art_01J00000000000000000000002",
    "kind": "stdout",
    "content_type": "application/octet-stream",
    "size_bytes": 11,
    "digest": "sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
    "stream_id": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }
}
```

ready.artifact 复用 frozen artifactDescriptor 形状；例子中的确定值仅供测试，
不是生产 CSPRNG 样本。exec metadata 来自同一已授权 binary peer，不是原 control
response 中已存在的独立 digest 承诺；其信任边界仍是第 3 节，SHA-256 不是 peer authentication。

## 6. Host publication 与 guest retirement

1. host 先做 per-VM/global admission，再写 owned private stage，使用固定 buffer 流式 hash。
   不把完整 artifact 载入内存；不使用 guest 文件路径作为 host publish 路径。
2. 验证完整 binding、声明 size、end marker、SHA-256、当前 generation/session ownership。
3. host 生成自己的 public art_ ULID；guest artifact_id 只是内部 correlation。
   durable mapping 包含 VM、generation、operation、guest artifact_id 和 digest，
   不能把跨 VM guest ID 当作全局 SQLite resource identity。
4. 使用 crash-consistent managed-file publication/reconciliation；resource metadata、
   operation/TestRun 引用、event/outbox 在对应 SQLite transaction 中一致提交。
   已验证的 guest terminal result 也必须先持久化，不能仅保存在待 ACK 的内存里。
5. 仅 committed rows 可供 public API 查询/下载。public reference 重写成 host artifact ID；
   GET /v1/artifacts/{artifact_id} 读取 host 已发布 bytes，不代理 live guest stream。
6. 提交成功后发送 acknowledgement；ACK 丢失不回滚已提交 artifact，也不导致重复创建。
   重试用 durable mapping 识别已发布的同一 source；metadata 冲突必须失败。

```json
{
  "protocol_version": "gaovm.binary.v1",
  "kind": "committed",
  "vm_id": "vm_01J00000000000000000000000",
  "driver_generation": 8,
  "operation_id": "op_01J00000000000000000000001",
  "artifact_id": "art_01J00000000000000000000002",
  "stream_id": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "size_bytes": 11,
  "digest": "sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
}
```

单个 ACK 只 retire 对应 transfer grant；不能调用整个 collection/job 的 release，
从而删除仍未确认的 sibling output。只有整组 artifact 与 result 已满足退休条件，
service 才调用现有内部 release。inline-only exec 的 terminal-result TTL/退休策略仍需
在 service lifecycle 中定义；本文不暗中增加 result.release wire RPC。
host artifact 保留期遵循 PRD，不因 guest spool retirement 或 control EOF 被删除。

## 7. 有界资源与失败语义（已接受值，部分组件已实施）

| 项目 | 契约 |
|---|---|
| metadata header | 1..4096 encoded bytes |
| body chunk | 1..8192 bytes；0 为 end，不是空 data chunk |
| artifact hard maximum | 256 MiB；实际 admission 取双方 policy、remaining budget 的更小值 |
| 默认 capture/collection limit | 保持当前 library 的 16 MiB；不因 binary transport 放宽 |
| 同一 guest active transfer / pending open | 2 / 8；超额拒绝，不无界排队 |
| guest aggregate retained spool | 默认 256 MiB，exec 与 collection 共享；运行 capture reservation、retained file、open reader 与真实 I/O worker 都占用同一 lifetime budget |
| open / body / commit-ACK deadline | 默认 5 / 30 / 30 秒；每阶段 absolute deadline，受外层 operation deadline 限制，不按每个 chunk 重置 |

Rust library 已实施 header/chunk/size/digest、post-flush grant、每 epoch 两个 active
transfer、单 grant reader、original open/30 秒 body/ACK deadline 和对应 ACK retirement。
registry descriptor cap 为当前默认 engine retention 推导的 4,160；不是 spool byte quota。
Linux-only `HostListener` 已有 native AF_VSOCK/getpeername host-CID admission、八个
pending open permit 和原始五秒 deadline；coordinator 必须保持同一 long-lived listener、
在 hello/grant admission 前持有 permit，不能按 preface 重置 deadline。该组件及 Linux-only
rejection tests 目前仅 cross-compile，未证明真实 GaoOS/VZ CID 或 quota 行为。
`ControlSlot` 已有 host-first binding 与 EOF/deadline/revocation fencing；cleanup owner
显式 finish 前不允许 replacement，真实 Unix fixture 验证先 revoke 并 join binary I/O。
`GuestDispatcher` 现已组合 P0 request、post-flush grant 与 sealed collection/stdout/stderr
source-provider；binary open 先通过完整 grant admission，再用已授权 operation 查原始
sealed source，不接受路径、不扫描 artifact、不重新执行 command。terminal exec metadata
先同步 snapshot 并释放 executor lock，再等待 entropy；real Unix regression 验证等待
entropy 不阻塞 health/cancel。跨 epoch 重用的 `GuestResources` 为 entropy/system.info
提供一个 shared owned blocking permit，caller cancel 也不提前释放真实 worker。
`GuestResources` 现还跨 epoch 共享默认 256 MiB `SpoolBudget`；exec 在 spawn 前预留
最大 combined capture，collection 在复制前预留 remaining capacity，capture seal 且真实
writer 完成后才返还未用容量。metadata 不为每个 artifact 保留 FD；reader 保有原始
readonly inode、private directory 和整组 reservation，release/drop 不会提前返还仍由
sibling/reader/worker 持有的容量。真实 subprocess 和跨 generation reader 测试验证
quota rejection 发生在 command side effect 前，以及旧 reader 关闭后才能重用容量。
collection copy、capture write/sync/inline read 和 binary source read 由共享 11 个 owned
blocking I/O permit 限制（4 exec × 2 stream + 1 collection + 2 transfer），不无界排队。
caller cancel 不提前归还 queued/running syscall 的 file/quota；被丢弃的 result 先关闭
file，再归还 worker permit。新 bootstrap 在 owned worker 执行初始化；旧 `bind`、
open/metadata/final unlink 仍含同步 filesystem 调用，这不是完整 filesystem latency 或
installed shutdown policy。
`shutdown` 先 revoke，再等待执行进程与 capture/metadata worker；真实 child 测试验证
正常 cleanup 路径。协调器仍必须 join transfer/capture task、关闭控制通道、drop context，
并通过 `GuestResources::quiesce`，才可 finish cleanup slot。缺失/替换对象或 removal
失败会保留 suspect spool、永久 quarantine 此 budget 并使 final barrier 失败；不能通过
new budget 隐藏未确认占用。当前没有 crash recovery scanner 或持久化 quota reconstruction。
inline file 的 final removal 发生在 reservation seal 前；cleanup fence 也阻止 seal 缩减
该 charge 或将未确认 cleanup 作为正常 terminal result，沿用 `GUEST_INTERNAL_ERROR`。
`GuestControl` library coordinator 现拥有 framing halves、最多八个 in-flight request 和
十个 binary job（八个 pending opening + 两个 active transfer），保留 listener 的 opening
permit/original deadline。control EOF/error/deadline 或 trusted local `stop` 先 revoke，
再 abort/join task、reap process、关闭 transport、drop dispatcher，并通过 final resource
barrier 才 finish slot；requested stop 不能掩盖 cleanup failure，weak session handle 不持有
dispatcher，也不能授权 replacement epoch。frame/request budget 由 caller 显式提供，
不新增 wire heartbeat 要求或 installed-service 默认值。Unix fixture 验证 real process stop、
stalled binary 下 health/EOF cleanup、sibling ACK，以及 drop-time removal failure 后 fresh
slot 也不能绕过同一 quarantined resource owner 广告 readiness。
Linux `gaovm-guestd` entrypoint 现组合 long-lived `HostListener`、`GuestAcceptor` 和同一
`GuestResources`。只有实际 native peer admission 后的 stream 进入 router；control prefix
带原 deadline 交回 decoder，已读取 GAB1 的 binary stream 不重复消费 magic。router 拥有
最多九个 connection task（一个 control owner + listener 的八个 opening），用 opaque
owner identity 防止旧 task 清除 replacement handle，且 resident loop 在没有新 connection
时也 supervise completion。SIGTERM/SIGINT 关闭 listener，再永久 stop admission、join
opening/control owner 并通过 actual worker barrier；取消 opening 不等于 initializer/result
cleanup 已完成。Unix fixture 验证这些 ownership 路径及 confirmed cleanup 后 replacement。
CLI 要求显式 absolute source/spool root 与 positive finite I/O budget，port 默认仍为 10777；
无 VM identity/root/budget 默认值。Linux path 仅 compile/lint，native signal/vsock/prctl
尚未执行。`PR_SET_NO_NEW_PRIVS` 继承到 child，但不移除现有 UID/capability，也不代替
unprivileged account/cgroup installation。authorized binary-open error header 现已组合：
仅 live published full binding/selector 匹配后才允许 bounded correlated error，无 body，
固定 diagnostics；quota check 排在 binding match 后，未知/未发布/过期/retired binding
即使 pool 已满也不回显 identity。source failure 不 retire grant，busy/quota failure 不
admit reader。error reply 保留 opening permit 到 flush/transport close，受原 opening、
operation、grant deadline 与 epoch revocation 约束；ready/body 后失败仍直接 close，
不追加 error frame。真实 Unix fixture 验证 source restoration/retry、full quota 下 foreign
binding silence，以及 stalled error 的 health/deadline/EOF cleanup。group/result
retirement、crash recovery、least-privilege image integration 与 installed/native acceptance 仍未完成；
guest quota/retirement 不暗中定义 host artifact retention policy。
`ControlEpoch` 只证明 wire hello/flush，
不证明 native peer CID；native acceptor 在读取 preface 前独立检查 kernel peer address。

open error header 字段严格为 protocol_version、kind=error、vm_id、
driver_generation、operation_id、artifact_id、error。error 只含 code、message、
retryable；message 为不超过 256 encoded bytes 的固定说明，不回显路径、payload 或 token。
无效/无法验证的 binding 在输出 header 前直接关闭，不能回显攻击者提供的 identity。
可用 code 复用 PROTOCOL_VERSION_MISMATCH、INVALID_REQUEST、ARTIFACT_NOT_FOUND、
ARTIFACT_LIMIT_EXCEEDED、GUEST_INTERNAL_ERROR 的名称，但不是 control error envelope。
retryable 不承诺自动重试；过期 grant 必须通过原 control operation 重取 metadata。

- open 时验证 epoch/VM/generation/op/artifact/source；同一 grant 最多一个 active reader，
  重入拒绝，不让两个 connection 共享可变 read offset。
- body 中断、超时或 cancel：终止当前 transfer，释放 transfer lease，host 不 publish partial bytes。
  retry 从 byte 0 开始，受 attempt/operation budget 限制；MVP 不支持 offset/resume/compression。
- control EOF、session replacement 或 generation change：先 invalidate grants，再 abort active
  binary transfer。late callback 不得写入新的 VM/session/operation state。
  已 durable committed 的 host artifact 保持有效；旧 generation 的迟到未提交结果默认丢弃。
- descriptor/checksum mismatch：失败，不截断成“成功的较小 artifact”，不重执行 guest command。
- binary congestion 不阻塞 control health/cancel，也不阻塞 Swift VZ runtime queue。
- guest ephemeral replay/retirement 不提供跨 restart 的 exactly-once 执行保证。
  daemon 持久 Operation 保持 authoritative；失联后的 unknown outcome 必须显式失败，
  不得因 artifact 下载失败而重发 side-effecting exec.start。

## 8. 接受后的实现顺序与验证门槛

1. Rust：typed header、accept demux、bounded chunk codec、grant registry、sealed exec digest；
   保留原 control schema 与 framing 回归，先做真实 Unix socket 成功/失败测试。
2. Rust service：native Linux vsock、peer CID、host-first binding bootstrap、bounded worker/
   spool/retention、signal/disconnect cleanup；全部 P0 handler/binary path 可用才 advertise core。
3. Swift/Dart：遵循已接受的 [private driver bridge 契约](GUEST_DRIVER_BRIDGE_V1.md)；VZ device 操作只在
   runtime queue，bytes pump 不占用该 queue；daemon per-VM guest session 使用该私有通路。
4. Host artifact service：durable mapping、stage/fsync/publication/recovery、Operation/TestRun
   引用与 outbox，并接入现有 public artifact endpoint。
5. Native gate：Apple Silicon VZ + 真实 GaoOS image 的 stdout/stderr spill、collection、
   两 VM isolation、cancel/disconnect、daemon restart 与公开 API download 验证。

必要的失败矩阵：

- fragmented/coalesced preface/header/chunk/end；empty 与 non-UTF-8 body；双方固定独立 fixture；
- unknown magic/version/field、duplicate keys、超长 metadata/chunk、错误 ID/selector；
- collection descriptor 不匹配、exec output 串线、未发布 grant、错误 peer、ready 前打开；
- old generation/epoch、同 grant 并发、retired/expired grant、control EOF 中的 active transfer；
- truncated body、early end、overlong body、digest mismatch、slow reader、open/body/ACK timeout；
- staged receive、verified stage、file publish、SQLite commit、ACK 之间各 crash boundary；
- ACK 丢失后重试不重复 publish；guest 不提前删除 sibling spool；
- binary backpressure 下 control health/cancel 仍响应，VM-B 不受 VM-A 失败影响；
- 真实 VZ vsock peer CID、driver bridge 每连接授权、guest bootstrap 与公开 artifact download。

Rust grant/transfer fixture 已验证 post-flush admission、完整 binding/ACK、reader/expiry
ownership、retry、sibling spool 保留与 stalled binary 下的 control health。其 ACK 由 fixture
发送，不证明 host durable commit；其 Unix socket 不证明 native CID/bridge authentication。
Dart [host stdout/stderr library](../GUEST_ARTIFACT_PUBLICATION.md) 现组合 original
control epoch/start-marker、durable complete terminal snapshot、bounded receive、
managed publication 与同一 transaction 的 mapping/event/outbox。真实 Unix/SQLite fixture
验证 commit 前不发 ACK、ACK 丢失保留 bytes、重试不重复 resource、public HTTP download、
共享 admission/cleanup barrier。另有 [真实 Rust guest → Dart host 检查](../GUEST_ARTIFACT_PUBLICATION.md#real-rust-guest-to-dart-host)，
验证 actual grant/ACK consumption、stdout/stderr sibling、raw collection/empty bytes、durable mapping
与公开 HTTP download，以及实际 Unix guest/exec shutdown 后 unknown recovery 不重放 command。
该 test-only private Unix bridge 不证明 native CID、VZ bridge 或 escaped-descendant containment。
[production worker/API](../GUEST_EXEC_DURABILITY.md) 与
[ordered TestRun steps](../TEST_RUN_STEPS.md) 已接入 daemon composition，并有 Unix/SQLite
fixture 验证。[host collection / TestRun diagnostics](../TEST_RUN_ARTIFACTS.md)
已有 one-shot SQLite marker、exact collection descriptor receive 与 production composition。
真实 guest retirement/recovery 与 installed/native 门槛仍待验证，不能因 library checks 通过视为完成。

## 9. 决策记录

用户于 2026-10-10 接受“同端口独立 connection + GAB1/gaovm.binary.v1 + binary-side exec metadata lookup +
chunk/end + durable commit ACK”及第 3 节 trust boundary。
若要求 shared-host 的独立进程级 guest authentication，先设计显式 session secret/channel
binding，而不是把 stream_id、public artifact_id 或日志中的 request_id 当作凭证。

此决定不批准任何尚未定义的 driver protocol schema 变更；第 8 节第 3 项遵循同日接受的独立 bridge 契约。
本文不把 M6、package 023 或 MVP 标记为完成。

## 10. 平台依据与证据边界

- Linux 的 host CID 常量依据上述 UAPI；native VZ/GaoOS 的实际 peer observation 尚未验证。
- Apple 提供 driver 内通过 VZVirtioSocketDevice.connect(toPort:completionHandler:) 建立 guest-port
  connection 的 API；这支持连接方向的设计，不证明 bridge、身份隔离或完整 transfer 已通过。
  [Apple API](https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice/connect(toport:completionhandler:))
- 本文不依赖 native half-close 作为 delimiter，也不把 CSPRNG stream handle 或 SHA-256 当作认证。
