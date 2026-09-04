---
project: GaoVM
title: GaoVM 产品需求文档
document: prd
status: accepted
m0_contract: frozen
target_release: Multi-VM Agent Testing MVP
updated: 2026-09-04
tags:
  - gaovm
  - prd
  - multi-vm
  - agent-api
  - gaoos-testing
---

# GaoVM 产品需求文档（PRD）

## 1. 产品概述

GaoVM 是一个面向 macOS Apple Silicon 的通用本地虚拟机管理器。

产品形态类似 UTM，但首个版本聚焦于：

- Apple `Virtualization.framework`；
- ARM64 Linux Guest；
- 多 VM 管理；
- GaoOS 多版本并行运行与测试；
- API-first、Agent-first 自动化；
- CLI 与后续 Flutter GUI；
- 本地单用户、可靠、可观察的 VM 控制面。

GaoOS 是首个重点 Guest Profile，而不是 GaoVM 唯一支持的系统。通用 VM 生命周期、存储、网络和 API 必须保持 Guest 无关；GaoOS 特定的 readiness、测试、版本识别和 artifact 采集位于 profile 和 test orchestration 层。

---

## 2. 问题陈述

当前 GaoOS 开发与测试需要反复完成：

1. 准备特定版本的 kernel、initrd 和 root disk；
2. 创建隔离 VM；
3. 启动并确认系统真正 ready；
4. 执行测试命令；
5. 收集 serial、service、测试结果和失败证据；
6. 同时比较 stable、nightly、feature build；
7. 测试后停止、删除或保留失败环境。

仅有图形化 VM 启停不能满足该流程。AI coding/test agent 还需要：

- 稳定 API；
- 结构化资源与错误；
- 幂等操作；
- 条件等待；
- 异步 operation；
- 可恢复事件；
- Guest 内命令执行；
- 测试产物；
- 可预测的清理语义。

当前单 VM 原型无法表达多版本并行测试，也不能安全地让多个 agent/client 并发操作不同 VM。

---

## 3. 产品愿景

> GaoVM 应成为 GaoOS 开发环境中的本地虚拟化控制面：开发者可以像使用桌面 VM 管理器一样管理 VM，AI Agent 也可以像调用测试基础设施一样创建、运行、观察和销毁 VM。

---

## 4. 目标用户

### 4.1 GaoOS 开发者

需要：

- 保存多个 GaoOS 版本；
- 快速创建测试 VM；
- 查看显示窗口与 serial log；
- 手工启动、停止、克隆和诊断；
- 保留失败环境。

### 4.2 AI coding/test agent

需要：

- 发现可用 image 与 VM；
- 根据 labels 精确定位资源；
- 幂等创建和操作 VM；
- 等待 guest ready；
- 在 Guest 中执行命令；
- 获取结构化结果和 artifact；
- 在连接中断后恢复 operation/event 状态。

### 4.3 通用 ARM64 Linux 用户

需要：

- 导入 Linux kernel/initrd/raw disk；
- 创建多个独立 VM；
- 使用 NAT 或无网络模式；
- headless 或 display 模式运行；
- 通过 CLI/API 管理。

---

## 5. 产品原则

1. **Multi-VM by design**：多 VM 是基础模型，不是后续补丁。
2. **One public API**：UI、CLI、MCP 与 Agent 共享同一 API。
3. **Operations, not blocking calls**：长动作返回 operation。
4. **Declarative lifecycle**：desired/observed state 分离。
5. **Failure is observable**：失败必须留下状态、事件、日志和 artifact。
6. **Generic core, GaoOS profile**：GaoOS 优先但不污染通用 core。
7. **Safe local defaults**：默认 HTTP/1.1 Unix socket、单用户、无公网监听。
8. **No hidden passthrough**：Agent 不直接调用 runtime driver 内部方法。
9. **Deterministic cleanup**：成功、失败、取消时都必须有明确资源清理结果。
10. **Schema before UI**：API/domain 稳定后再构建完整 GUI。

---

## 6. 版本范围

本文定义的目标里程碑称为：

```text
Multi-VM Agent Testing MVP
```

### 6.1 MVP 包含

- macOS 14+；
- Apple Silicon；
- ARM64 Linux；
- 多 VM catalog；
- 多 VM 并行运行；
-每运行 VM 独立 Swift driver；
- Linux kernel boot；
- raw managed/external disk；
- shared NAT 与 none 网络模式；
- headless 与可重开 display；
- serial log；
- image/bundle import；
- public HTTP/JSON API；
- HTTP/1.1 over Unix Domain Socket；
- OpenAPI；
-异步 operations；
- durable events/SSE；
- CLI；
- GaoOS Guest Agent；
- guest readiness 与 exec；
- TestRun；
- artifact collection；
- daemon/driver crash recovery；
- macOS packaging、codesign 和 launchd。

### 6.2 MVP 不包含

- x86 模拟；
- QEMU backend；
- macOS/Windows Guest；
- bridged network；
- snapshot；
- suspend/resume；
- USB passthrough；
- VirtioFS/shared folders；
-远程多用户服务；
- RBAC；
-公网 API；
-分布式 scheduler；
-完整 UTM feature parity。
-基于已有 VM 的 clone API；
- Flutter UI 与 MCP Adapter（Beta 交付，不阻塞 MVP）。

---

## 7. 关键使用场景

### UC-01：并行比较 GaoOS 版本

开发者或 Agent：

1. 导入 GaoOS stable 与 nightly image；
2. 各创建一台 VM；
3. 同时启动；
4. 等待 Guest Agent ready；
5. 执行相同测试；
6. 获取两个 TestRun 结果与 artifacts；
7. 删除成功 VM，保留失败 VM。

### UC-02：Agent 创建临时测试环境

Agent 使用 idempotency key 创建 VM，启动后等待：

```text
guest_agent_ready
```

然后执行命令并在 timeout 前得到：

```text
exit_code
stdout artifact
stderr artifact
duration
```

即使 Agent 连接中断，也能通过 operation ID 继续查询。

### UC-03：用户手工调试失败 VM

TestRun 失败后：

- VM 保持运行；
- 用户通过 CLI/public API 打开 display（Beta 后也可通过 Flutter UI）；
- 查看 serial log；
- 使用 CLI 查询状态；
- 修复后手工删除。

### UC-04：单 VM driver 崩溃

VM-A driver 崩溃时：

- VM-B 保持运行；
- VM-A 产生 durable event；
- 按 restart policy 重启；
- operation/test run 获得明确状态；
- 不产生 orphan driver。

### UC-05：daemon 重启

daemon 重启后：

- 恢复 VM catalog；
- 恢复未完成 operation；
- 清理 stale runtime；
- desired=`running` 的 VM 重新 reconcile；
- event sequence 不回退。

### UC-06：运行无 Guest Agent 的通用 Linux

用户仍可：

- 创建、启动、停止 VM；
- 使用 display；
- 获取 serial log；
- 查询 VZ runtime 状态。

只有 guest readiness、guest exec 和高级 test 功能被标记为 unavailable。

---

## 8. 功能需求

优先级：

- **P0**：MVP 发布阻塞；
- **P1**：Beta 需要；
- **P2**：后续扩展。

M0 冻结以下 scope 解释：Guest protocol v1 的 `hello/capabilities`、health、system info、guest exec、timeout/cancel 和 artifact spill 是 P0；file transfer、service/log convenience API 和 guest reboot/shutdown 是 P1。`VM-010` 的“基于已有 VM clone”是 P1，不阻塞 MVP；从 managed image 为新 VM 创建隔离 writable disk（`IMG-005`/`IMG-006`）仍是 P0。Flutter UI 与 MCP Adapter 全部是 P1/Beta，不属于 MVP 发布依赖。

### 8.0 P0 追踪

下表按 requirement ID 前缀覆盖每个 P0 条目。实现 PR 必须在描述中列出满足的具体 ID、对应测试和验证命令；只有表中“发布证据”全部存在时，相关 P0 才可视为完成。

| P0 ID 范围 | 主里程碑 | 发布证据 |
|---|---|---|
| VM-001..009 | M1、M2、M4、M5 | repository/controller/API contract tests；migration/restart E2E |
| RUN-001..011 | M2、M3 | reducer/fake-driver invariants；Apple Silicon multi-VM/crash E2E |
| SPEC-001..012 | M0、M1、M3 | VmSpec schema tests；VZ configure/boot tests |
| IMG-001..007 | M5 | atomic import、managed-disk isolation、reference/crash tests |
| API-001..012 | M0、M4 | OpenAPI validation/contract tests；HTTP/1.1-over-UDS integration；SSE resume |
| OP-001..007 | M1、M2、M4 | repository/reconciliation/cancel/conflict tests |
| EVT-001..006 | M1、M4 | transactional-outbox, cursor-resume and non-blocking-log tests |
| GST-001..007 | M0、M3、M6 | guest protocol contract tests；GaoOS readiness/exec E2E |
| TST-001..010 | M1、M6 | TestRun state-machine, cleanup, artifact and GaoOS E2E |
| SCH-001..005 | M1、M2 | admission/lease/recovery tests |
| CLI-001..008 | M7 | CLI-to-public-API integration；JSON/exit-code contract tests |

## 8.1 VM Catalog

| ID | 优先级 | 需求 |
|---|---:|---|
| VM-001 | P0 | 系统必须为每台 VM 分配不可变、带资源前缀的 ULID。 |
| VM-002 | P0 | 支持 create、list、get、patch、delete。 |
| VM-003 | P0 | VM 名称不作为唯一身份；同名可以被拒绝或按配置约束，但 API 始终以 ID 操作。 |
| VM-004 | P0 | VM 支持 labels 和 selector 查询。 |
| VM-005 | P0 | VM spec 必须版本化并进行强类型 schema 校验。 |
| VM-006 | P0 | VM status 必须包含 desired state、observed phase、spec generation、driver generation 和 last error。 |
| VM-007 | P0 | 删除是异步 operation；运行中的 VM 必须先停止。 |
| VM-008 | P0 | 外部磁盘默认不随 VM 删除。 |
| VM-009 | P0 | daemon 重启后 catalog 完整恢复。 |
| VM-010 | P1 | 支持基于已有 VM clone。 |

## 8.2 多 VM Runtime

| ID | 优先级 | 需求 |
|---|---:|---|
| RUN-001 | P0 | 多台 VM 可以并行启动和运行。 |
| RUN-002 | P0 | 每台运行 VM 使用独立 driver process、socket、token、PID 和日志。 |
| RUN-003 | P0 | 一个 VM 的 driver crash 不得影响其他 VM。 |
| RUN-004 | P0 | 同一 VM 的 lifecycle command 严格串行。 |
| RUN-005 | P0 | 不同 VM 的 operation 可以并行。 |
| RUN-006 | P0 | start、stop、restart、kill 必须是幂等或返回稳定冲突语义。 |
| RUN-007 | P0 | driver callback 必须按 vm_id 和 generation 校验。 |
| RUN-008 | P0 | VM runtime state 必须通过 driver event 主动更新，而非仅在 status 请求时轮询。 |
| RUN-009 | P0 | heartbeat 连续失败必须触发 unhealthy recovery。 |
| RUN-010 | P0 | restart policy 支持 never、on_failure、always。 |
| RUN-011 | P0 | restart 必须有次数和时间窗口限制；预算耗尽后必须设置 desired=`stopped`、phase=`failed` 并发出 `vm.permanent_failure`。 |
| RUN-012 | P1 | 支持 per-VM autostart。 |

## 8.3 VM Spec 与设备

| ID | 优先级 | 需求 |
|---|---:|---|
| SPEC-001 | P0 | 支持 ARM64 Linux kernel boot。 |
| SPEC-002 | P0 | 支持 kernel、initrd、command line。 |
| SPEC-003 | P0 | CPU/memory 必须根据 host/VZ 实际上下限校验。 |
| SPEC-004 | P0 | memory 必须满足 VZ 对齐要求。 |
| SPEC-005 | P0 | 支持一个或多个 Virtio block disk。 |
| SPEC-006 | P0 | 支持 managed disk 与 external disk。 |
| SPEC-007 | P0 | 支持 shared NAT 与 none 网络模式。 |
| SPEC-008 | P0 | NIC 使用稳定 MAC。 |
| SPEC-009 | P0 | 支持 graphics enabled/disabled。 |
| SPEC-010 | P0 | 支持 serial output capture。 |
| SPEC-011 | P0 | runtime 不允许热更新的字段必须 staging，并明确 restart required。 |
| SPEC-012 | P0 | disk resize 不得伪装成已立即应用的普通 config patch。 |
| SPEC-013 | P1 | 支持 EFI boot。 |
| SPEC-014 | P2 | bridged network。 |

## 8.4 Image 与 VM Bundle

| ID | 优先级 | 需求 |
|---|---:|---|
| IMG-001 | P0 | 支持导入 kernel、initrd、raw disk 和 GaoOS bundle。 |
| IMG-002 | P0 | Image 必须有 digest、architecture、type 和 immutable manifest。 |
| IMG-003 | P0 | GaoOS image 记录 version、build_id、channel。 |
| IMG-004 | P0 | image import 必须 atomic；失败不能留下可见的半成品。 |
| IMG-005 | P0 | 创建 VM 时可以从 managed image 生成独立 writable disk。 |
| IMG-006 | P0 | APFS 上优先使用 clonefile；不支持时可靠 fallback copy。 |
| IMG-007 | P0 | Image 被 VM 引用时不得直接删除。 |
| IMG-008 | P1 | 支持 VM template。 |
| IMG-009 | P1 | 支持导出/导入 `.gaovm` bundle。 |
| IMG-010 | P2 | snapshot 与 backing chain。 |

## 8.5 Public API

| ID | 优先级 | 需求 |
|---|---:|---|
| API-001 | P0 | 提供 `/v1` HTTP/JSON API。 |
| API-002 | P0 | MVP 公共 API 使用 HTTP/1.1，默认且仅监听 Unix Domain Socket。 |
| API-003 | P0 | 提供 OpenAPI JSON。 |
| API-004 | P0 | 所有响应包含或可关联 request ID。 |
| API-005 | P0 | 长操作返回 `202 + operation_id`。 |
| API-006 | P0 | 创建和 action 支持 `Idempotency-Key`。 |
| API-007 | P0 | spec patch 支持 revision/If-Match。 |
| API-008 | P0 | 错误提供稳定 `code`、HTTP status、retryable 和 details。 |
| API-009 | P0 | 列表支持分页、labels selector 和稳定排序。 |
| API-010 | P0 | 提供 wait API，并要求显式 timeout。 |
| API-011 | P0 | 提供 durable event stream 与 cursor resume。 |
| API-012 | P0 | CLI 使用公共 API，而不是单独业务路径。 |
| API-013 | P1 | 提供官方 Dart client library。 |
| API-014 | P1 | 提供可选 loopback TCP endpoint。 |
| API-015 | P2 | 远程 mTLS endpoint。 |

## 8.6 Operation

| ID | 优先级 | 需求 |
|---|---:|---|
| OP-001 | P0 | Operation 状态支持 pending/running/succeeded/failed/cancelled。 |
| OP-002 | P0 | Operation 持久化，daemon 重启后可查询。 |
| OP-003 | P0 | Operation 记录 resource、request、deadline、result 和 error。 |
| OP-004 | P0 | 可取消的 operation 提供 cancel API。 |
| OP-005 | P0 | 不可取消阶段必须明确返回 `OPERATION_NOT_CANCELLABLE`。 |
| OP-006 | P0 | operation completion 发出 durable event。 |
| OP-007 | P0 | 同一 VM 的冲突 operation 必须排队、合并或稳定拒绝，不得竞态执行。 |
| OP-008 | P1 | 支持 progress 与 step detail。 |

## 8.7 Event 与日志

| ID | 优先级 | 需求 |
|---|---:|---|
| EVT-001 | P0 | Event 有单调递增 sequence。 |
| EVT-002 | P0 | Event 持久化并可按 VM、operation、TestRun 过滤。 |
| EVT-003 | P0 | SSE 断开后可从 sequence 恢复。 |
| EVT-004 | P0 | 日志包含 vm_id、operation_id、driver_generation 和 request_id。 |
| EVT-005 | P0 | 每 VM driver/serial log 独立。 |
| EVT-006 | P0 | 日志 rotation 不得阻塞 VM control path。 |
| EVT-007 | P1 | 提供日志 tail/stream API。 |
| EVT-008 | P1 | 提供基础 metrics。 |

## 8.8 Guest Agent

| ID | 优先级 | 需求 |
|---|---:|---|
| GST-001 | P0 | GaoOS 提供可选 `gaovm-guestd`。 |
| GST-002 | P0 | host 与 guest 使用 virtio-vsock。 |
| GST-003 | P0 | 提供 health 与 system.info。 |
| GST-004 | P0 | 提供 guest exec，返回 exit code、stdout、stderr、duration。 |
| GST-005 | P0 | guest exec 支持 timeout 和 cancel。 |
| GST-006 | P0 | 大输出转存 artifact，不得无限占用 daemon memory。 |
| GST-007 | P0 | Guest Agent 不可用时 VM 基础 lifecycle 仍可工作。 |
| GST-008 | P1 | 文件 upload/download。 |
| GST-009 | P1 | service status 与日志采集。 |
| GST-010 | P1 | guest reboot/shutdown。 |

## 8.9 TestRun

| ID | 优先级 | 需求 |
|---|---:|---|
| TST-001 | P0 | Agent 可以创建持久化 TestRun。 |
| TST-002 | P0 | TestRun 可以从 image 自动创建临时 VM；从 template 创建属于 P1。 |
| TST-003 | P0 | 支持 readiness condition 和 timeout。 |
| TST-004 | P0 | 支持有序 guest exec steps。 |
| TST-005 | P0 | 每个 step 有结构化状态和结果。 |
| TST-006 | P0 | 测试结束自动采集 serial、driver、stdout/stderr 和结果 artifact。 |
| TST-007 | P0 | 支持 delete_on_success、always_delete、retain 三种 cleanup policy。 |
| TST-008 | P0 | 支持 retain_on_failure。 |
| TST-009 | P0 | TestRun cancel 必须停止后续 step 并执行 cleanup policy。 |
| TST-010 | P0 | 同一 image 可以并行产生多台测试 VM。 |
| TST-011 | P1 | 支持 matrix 测试多个 GaoOS 版本。 |
| TST-012 | P1 | 支持结果 comparison/report。 |

## 8.10 Scheduler

| ID | 优先级 | 需求 |
|---|---:|---|
| SCH-001 | P0 | 启动 VM 前进行 memory/CPU/disk admission check。 |
| SCH-002 | P0 | 支持可配置最大运行 VM 数。 |
| SCH-003 | P0 | 支持可配置最大并发 boot 数。 |
| SCH-004 | P0 | lease 必须在 crash recovery 后重新校验。 |
| SCH-005 | P0 | 资源不足返回稳定、可重试错误。 |
| SCH-006 | P1 | 支持队列等待资源。 |

## 8.11 CLI

| ID | 优先级 | 需求 |
|---|---:|---|
| CLI-001 | P0 | 支持 VM create/list/get/update/delete。 |
| CLI-002 | P0 | 支持 start/stop/restart/kill/wait。 |
| CLI-003 | P0 | 支持 image import/list。 |
| CLI-004 | P0 | 支持 operation get/wait/cancel。 |
| CLI-005 | P0 | 支持 guest exec。 |
| CLI-006 | P0 | 支持 test run/status/artifacts。 |
| CLI-007 | P0 | 所有命令支持稳定 JSON 输出。 |
| CLI-008 | P0 | 非成功结果使用稳定 exit code。 |
| CLI-009 | P1 | 支持 YAML/JSON declarative spec 文件。 |

## 8.12 Flutter UI

| ID | 优先级 | 需求 |
|---|---:|---|
| UI-001 | P1 | 显示 VM 列表、状态、版本和 labels。 |
| UI-002 | P1 | 创建、编辑、删除 VM。 |
| UI-003 | P1 | start/stop/restart。 |
| UI-004 | P1 | 打开/关闭 display，不影响 VM lifecycle。 |
| UI-005 | P1 | 查看 operation、events、driver/serial logs。 |
| UI-006 | P1 | 查看 TestRun 与 artifacts。 |
| UI-007 | P1 | UI 只调用公共 API。 |

## 8.13 MCP Adapter

| ID | 优先级 | 需求 |
|---|---:|---|
| MCP-001 | P1 | 提供独立 `gaovm-mcp` adapter。 |
| MCP-002 | P1 | MCP tool 只调用公共 API。 |
| MCP-003 | P1 | tool 返回 resource/operation ID 和结构化错误。 |
| MCP-004 | P1 | 不暴露 `driver.exec`。 |
| MCP-005 | P1 | 为高频测试流程提供 `test_run` 等高层 tool，同时保留 VM primitive。 |

---

## 9. API 语义

### 9.1 VM create

请求：

```json
{
  "metadata": {
    "name": "gaoos-nightly",
    "labels": {
      "gaoos.channel": "nightly"
    }
  },
  "spec": {
    "backend": "vz",
    "architecture": "arm64",
    "guest_profile": "gaoos",
    "cpu": 4,
    "memory_bytes": 4294967296,
    "boot": {
      "type": "linux_kernel",
      "kernel_image_id": "img_01J00000000000000000000001",
      "initrd_image_id": "img_01J00000000000000000000002"
    },
    "disks": [
      {
        "id": "root",
        "source": {
          "type": "managed_image",
          "image_id": "img_01J00000000000000000000003"
        },
        "writable": true
      }
    ],
    "networks": [
      {
        "id": "net0",
        "mode": "shared"
      }
    ]
  }
}
```

响应：

```text
202 Accepted
```

返回 resource ID 与 operation ID。

### 9.2 Start

重复提交 start：

- VM 已 running：返回成功/no-op operation；
- 正在 starting：返回已有 operation 或等价状态；
- VM failed 但可 retry：创建新 operation；
-资源不足：operation failed，错误 `HOST_RESOURCE_EXHAUSTED`。

### 9.3 Wait

Agent 可以等待：

```text
phase == running
guest_agent == ready
operation == completed
test_run == completed
```

wait 必须有 timeout，timeout 不改变资源本身。

### 9.4 Guest exec

不得接受未经拆分的 shell 字符串作为唯一接口。标准请求使用：

```json
{
  "argv": ["gaoos-test", "network"],
  "cwd": "/",
  "env": {},
  "timeout_seconds": 600,
  "capture": {
    "stdout": true,
    "stderr": true,
    "max_inline_bytes": 65536
  }
}
```

需要 shell 时显式：

```json
{
  "argv": ["/bin/sh", "-lc", "..."]
}
```

---

## 10. 非功能需求

## 10.1 Reliability

- daemon crash 不损坏 VM catalog；
- driver crash 不影响其他 VM；
-不得存在无法追踪的 orphan driver；
- image import/create/delete crash 后可恢复或可靠回滚；
-每个 operation 最终进入 terminal state；
-重复请求不得重复创建 VM 或执行危险 action。

## 10.2 Consistency

- 同一 VM 的写操作线性化；
-跨 VM 允许并行；
-资源 revision 单调递增；
-event sequence 单调递增；
- DB state、operation、durable event 与待发布记录通过同一个 SQLite transactional outbox 事务保持一致。

## 10.3 Performance

不包含 VM 实际 boot 时间时：

- 本地 CRUD API P95 小于 250 ms；
- status/list P95 小于 250 ms；
- driver event 到 durable event 的 P95 小于 1 s；
- 100 台已定义但停止的 VM 不应产生 100 个常驻 driver process；
-系统应支持至少 100 个已定义 VM；
-实际同时运行数量由 host resource budget 控制，而非写死。

## 10.4 Resource control

- daemon 为每个 guest exec 设置输出上限；
- event/log subscriber 不能通过 backpressure 阻塞 controller；
- image/disk 操作使用 streaming I/O；
-不能把完整大型 artifact 载入内存。

## 10.5 Security

-默认 HTTP/1.1 Unix socket `0600`；
-state dir `0700`；
-driver token 不写日志；
-loopback TCP 默认关闭；
-不提供公网监听；
- external path 经过 realpath/ownership 校验；
- Guest 输出永不作为 host command 自动执行。

## 10.6 Compatibility

- 公共 API 在 `/v1` 内保持向后兼容；
-字段新增默认向后兼容；
-breaking change 使用新 API version；
-driver protocol 与 public API 独立版本；
-VmSpec 使用显式 schema version。

---

## 11. 数据保留

默认建议：

- resource/event：保留 30 天或可配置；
- operation：保留 30 天；
- successful ephemeral TestRun artifact：保留 7 天；
- failed TestRun artifact：保留 30 天；
- retained VM：直到显式删除；
- image：直到无引用且显式删除；
- log rotation：按大小和数量配置。

清理过程本身必须产生 event，并不得删除仍被引用的 image/artifact。

---

## 12. 产品验收场景

### AC-01 多 VM 独立性

创建三台 VM，启动其中两台：

- 两台拥有不同 driver PID/socket/generation；
-停止 VM-A 不影响 VM-B；
- VM-C 不产生 driver。

### AC-02 Driver crash recovery

注入 VM-A driver crash：

- VM-B 保持 running；
- VM-A 产生 `driver.exited`；
-按 `on_failure` 重启；
-新 generation 大于旧 generation；
-旧回调不能覆盖新状态。

### AC-03 幂等 start

使用同一 Idempotency-Key 重复提交 start：

-只执行一次；
-返回同一 operation；
- VM 最终只有一个 driver。

### AC-04 daemon restart

在两台 desired=running 的 VM 场景重启 daemon：

-旧 driver 最终退出；
-daemon 恢复 catalog；
-重新启动两台 VM；
- event sequence 继续递增；
-没有 stale socket/orphan。

### AC-05 GaoOS Guest readiness

启动 GaoOS VM：

- VZ running 不等价于 guest ready；
- Guest Agent 建连后状态变为 ready；
- wait API 在 ready 时成功；
-timeout 时返回 `WAIT_TIMEOUT`，VM 保持原状态。

### AC-06 TestRun

TestRun 创建临时 VM，执行成功：

-步骤结果可查询；
-产生 stdout/stderr/serial artifact；
-根据 `delete_on_success` 删除 VM；
- TestRun 最终为 succeeded。

### AC-07 TestRun failure retention

测试命令失败：

- TestRun 为 failed；
- VM 按 `retain_on_failure` 保留；
- artifacts 可访问；
-失败原因包含 guest exit code，不只是通用 internal error。

### AC-08 无 Guest Agent

Generic Linux VM 不带 Guest Agent：

-可以正常 start/stop/display；
- guest exec 返回 `GUEST_AGENT_UNAVAILABLE`；
-不会把 VM 标记为 runtime failure。

### AC-09 API event resume

SSE 连接在 sequence N 断开并恢复：

-客户端从 N+1 继续；
-不遗漏已持久化事件；
-不会重新发出小于等于 N 的事件。

### AC-10 安全默认值

全新安装：

- API 使用 HTTP/1.1 且只监听 UDS；
-socket/state 权限正确；
-TCP 未开启；
-driver token 不在 process args 或日志中。

---

## 13. 发布门槛

Multi-VM Agent Testing MVP 只有在以下条件全部满足时才能发布：

1. 所有 P0 需求完成或有明确批准的 scope change。
2. public OpenAPI 与实现 contract test 一致。
3. Dart unit/integration tests 全部通过。
4. Swift driver unit tests 全部通过。
5. self-hosted Apple Silicon macOS E2E 通过。
6. 至少完成：
   - 多 VM 并行测试；
   - driver crash recovery；
   - daemon restart recovery；
   - GaoOS guest exec；
   - TestRun artifact；
   - idempotency；
   - event resume。
7. driver 已正确 codesign 并具备 virtualization entitlement。
8. launchd 安装/卸载/升级路径通过测试。
9. 不存在公开的 `driver.exec`。
10. README、PRD、OpenAPI、VmSpec 和 driver protocol 版本一致。

---

## 14. 成功指标

MVP 成功不是以“能打开 VM 窗口”为标准，而是：

- Agent 可以不依赖 GUI 完成 GaoOS 测试闭环；
-同一台 Mac 可同时管理和运行多个 GaoOS 版本；
-单 VM 故障不影响其他 VM；
-测试失败留下可复现环境或完整 artifact；
-用户可以通过 CLI/public API 接管 Agent 创建的 VM（Beta 后也可通过 UI）；
-所有自动化动作都有 resource ID、operation ID、event 和结构化结果。

---

## 15. 后续路线

### Beta

- Flutter manager UI；
- MCP adapter；
- VM template；
- guest file transfer；
- matrix TestRun；
- image registry/sync；
- richer metrics。

### 后续版本

- EFI；
- snapshot；
- suspend/resume；
- bridged networking；
- shared folders；
- QEMU backend；
- Hyper-V/bhyve backend；
-远程 mTLS 管理；
- Agent Plugin 打包；
-测试结果比较和历史趋势。
