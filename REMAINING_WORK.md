# 剩余工作：Apple Silicon 首版验收

交接日期：2026-10-16。代码基线以本文件所在提交及其历史为准。

2026-10-16 Apple Silicon 实测与本机候选包见 [首版验收检查点](docs/FIRST_RELEASE_ACCEPTANCE.md)；其中明确区分已通过、环境阻塞和未运行场景。

## 当前决定与工作边界

- 用户已结束 Intel 本机的功能开发，下一步在自己的 Apple Silicon 机器验证首版。
- 项目尚未发布版本。本次不继续开发升级/回滚，不把它们的未完成项作为首版验收的前置开发任务。
- 核心代码已进入验收收尾；这不表示所有测试或原生 VM 场景已经通过。
- 不做 Chrome integration，不追加 Flutter UI、MCP、VM clone 等 P1/Beta 功能。
- 默认使用新的私有测试状态和测试镜像；不替换已安装 app，不复用重要数据，不自动注册服务。
- 2026-10-19 用户确认 GaoOS 尚不存在。先推进通用 ARM64 Linux 的独立原生验收；GaoOS 镜像下的 Guest/TestRun 实测保留为未完成项，本次没有批准缩减 PRD 发布门槛。当天两轮只读清点仍各有 13 个 unresolved PID，原生 VM 验收继续等待宿主清点恢复，见 [最新复核](docs/FIRST_RELEASE_ACCEPTANCE.md#2026-10-19-补充与复核)。
- 旧的 [验收账本](docs/MVP_ACCEPTANCE.md) 保留了历史完整目标和扩展工作记录。继续工作时遵循本次首版验收范围，不因其中仍列有升级/回滚缺口而恢复扩展开发。

## 1. 切机后的准备

在 Apple Silicon macOS 14+ 上拉取 `main`，记录 `git rev-parse HEAD`。
重新安装/解析依赖并构建，不复制 Intel 的 `.build`、`.dart_tool`、`target` 或 AOT 可执行文件。
准备 Xcode command-line tools、Dart **3.9.0**，Rust 检查使用仓库 CI 固定的 **1.96.1**。

以下命令均从仓库根目录开始；依赖解析失败时先停止，不更新锁文件来绕过失败：

```sh
git pull --ff-only origin main
git rev-parse HEAD
uname -m
sw_vers
swift --version
mise exec dart@3.9.0 -- dart --version

for gaovm_package in libs/gaovm_models libs/gaovm_rpc libs/gaovm_api_client daemon/gaovmd clients/gaovm_cli; do
  (cd "$gaovm_package" && mise exec dart@3.9.0 -- dart pub get --enforce-lockfile) || break
done
```

`uname -m` 应为 `arm64`。原生 VM 需要可启动的 ARM64 Linux/GaoOS kernel、可选 initrd 和现有 raw disk；使用绝对路径、静止输入和可丢弃副本。

## 2. 先复核两个已知启动失败

```sh
(cd daemon/gaovmd && mise exec dart@3.9.0 -- dart test test/daemon_application_test.dart --concurrency=1)
```

之前实际失败、尚未复核通过的两个用例是：

- `installed daemon completes a pre-cancelled TestRun without client polling`
- `installed daemon serves the VM catalog over HTTP UDS`

名字虽含 installed，它们启动的是临时私有状态下的 source Dart daemon，不是真实安装服务。
Intel 上的检查在原有 10 秒 readiness deadline 失败；独立诊断还观察到
`process inventory contains unresolved executables`，有四个同用户进程无法解析 executable。
这不是已证明解决的问题，也不能只归结为机器慢；详见 [原始诊断结论](docs/MVP_ACCEPTANCE.md#2026-10-16-sealed-validation-checkpoint-recovery) 前一节。

若 Apple Silicon 仍失败，保留原始 stdout/stderr、退出码和进程清点证据后定位。
不要过滤掉测试、延长 deadline、放松认证/generation/census 检查，或杀死无关进程来制造通过。

## 3. 跑组件测试和 CI 对照

[CI](.github/workflows/ci.yml) 与 [Tests](.github/workflows/test.yml) 是命令入口依据；
它们的普通组件检查不等于实际 VM/GaoOS 验收。

```sh
(cd drivers/vz_macos && swift build && swift test)
(cd services/macos_service && swift build && swift test)
(cd guest/gaovm_guestd && cargo +1.96.1 test --locked && cargo +1.96.1 build --all-targets --locked)

export GAOVM_GUEST_FIXTURE="$PWD/guest/gaovm_guestd/target/debug/examples/host_publication_fixture"
for gaovm_package in libs/gaovm_models libs/gaovm_rpc libs/gaovm_api_client daemon/gaovmd clients/gaovm_cli; do
  (cd "$gaovm_package" && mise exec dart@3.9.0 -- dart analyze && mise exec dart@3.9.0 -- dart test) || break
done
```

逐项确认退出码；某一项失败后不要继续把后续结果汇总为全绿。
完整/default-concurrency Dart suite 和推送后的 CI 尚未确认全绿，需要在目标机器/对应 workflow 留存结果。
UI 的既有格式提示未在本次修复；UI 锁文件已补齐共享 API client 所需的 `ffi 2.2.0` 传递依赖。
如需验证 Beta UI，请使用符合 [UI SDK 约束](clients/gaovm_ui/pubspec.yaml) 的 Flutter/Dart，不能用控制平面的 Dart 3.9.0 运行 UI。

## 4. 原生 VM 验收顺序

先阅读 [原生 smoke 操作说明](docs/NATIVE_VM_SMOKE.md)。脚本会构建并签名一个新的私有 driver 副本，
保留测试状态，不注册服务；不要把组件测试或 `doctor` 通过当成 VM 已能启动。

```sh
KERNEL_PATH=/absolute/test-images/kernel \
INITRD_PATH=/absolute/test-images/initrd \
DISK_PATH=/absolute/test-images/root.raw \
mise exec dart@3.9.0 -- bash scripts/e2e_macos14_happy_path.sh

KERNEL_PATH=/absolute/test-images/kernel \
DISK_PATH=/absolute/test-images/root.raw \
mise exec dart@3.9.0 -- bash scripts/e2e_macos14_happy_path.sh --multi-vm
```

不需要 initrd 时去掉 `INITRD_PATH`；第二条命令若需要 initrd，也必须显式提供。
三 VM 场景需要三份 writable disk 空间，以及至少支持两个各 2 CPU/2 GiB VM 的运行预算。

需要补齐的实际观察：

- 单 VM 启停、显示开关、手动关窗后 VM 继续运行、serial 输出；操作完成与实际 generation 一致。
- 三 VM 独立磁盘、两个同时运行；停 A 不影响 B，C 未启动，不残留 driver。
- driver crash 后只恢复所属 VM；旧 generation 回调被拒绝；daemon 重启能恢复状态/Operation，无孤儿进程。
- public API/CLI 的幂等重试、revision 冲突、event cursor resume 和私有 UDS/token 权限。
- 没有 Guest Agent 的通用 Linux 仍能正常运行，并给出明确的 Guest unavailable 错误。

现有 smoke 只自动覆盖其中一部分。其余按 [PRD AC-01 至 AC-10](docs/PRD.md) 和
[验收场景索引](docs/MVP_ACCEPTANCE.md#milestone-and-acceptance-scenario-boundaries) 留存证据，不把脚本收据扩写成全场景通过。
如果 cleanup 失败，先确认原有测试 VM/driver 的身份与退出，再决定下一次运行，不自动清理或盲目重跑。

## 5. GaoOS Guest / TestRun 闭环

- 使用实际包含 [Guest service](guest/gaovm_guestd/README.md) 的 GaoOS 镜像；Mac 上的 Rust 测试程序不是 Linux Guest service。
- 按 [默认关闭的 Guest 开发验收入口](docs/GUEST_DEVELOPMENT_ACCEPTANCE.md) 显式开启 `--guest-development-acceptance true`，保留 UID、token、hello、capability、generation 检查。
- VM spec 也必须启用匹配的 `guest_agent` 和 port；driver 须按 [构建说明](README.md#building-source-components) 具备 virtualization entitlement。
- 先验证真实 `guest_agent_ready`，再按 [Guest exec](docs/GUEST_EXEC_CLI.md)、[TestRun](docs/TEST_RUNS.md)、[steps](docs/TEST_RUN_STEPS.md) 和 [产物收集](docs/TEST_RUN_ARTIFACTS.md) 验证。
- 至少覆盖：成功执行、非零退出、timeout/cancel、输出 spill、两 VM 隔离、成功清理、失败保留，以及公开下载后的实际 bytes/digest。
- HTTP 202、capability 广告、bridge 建立、VZ running 都不等于 Guest 命令或 TestRun 已完成。

首次 app 组装/手动安装验收另按 [打包](docs/MACOS_PACKAGING.md) 与 [服务说明](docs/MACOS_SERVICE.md) 执行；
签名、entitlement、私有目录和服务启动均需在实际设备观察，不自动注册/启动服务。
本次不进行旧版升级、降级或回滚测试。

## 6. 本次交接保留的状态与限制

- 本轮已有 395 个去重的选定检查通过，涉及 15 个测试文件；不是整个仓库 suite，也不是 Apple Silicon/VZ/GaoOS 通过证明。
- 本机 daemon 格式/分析已通过；之前的 AOT 产物是 x86_64，只能证明 Intel 构建入口，不能带到 ARM64 当测试产物。
- 已有升级/回滚代码随提交保留，避免丢失工作；最终提交阶段目前仅有内部 API，`rollback-upgrade` 命令和提交检查点恢复并未完成。下一位不应据此继续扩展这些功能。
- 本机临时目录中的日志/失败现场不随 Git 同步。可用的结论已记录在本说明及相关文档；目标机器应重新产生自己的证据。
- 原始失败保留为失败；未运行、环境阻塞和实测通过分开记录。验收结果应包括 commit、架构/系统/工具版本、命令、退出码、VM/Operation/generation 和脱敏日志路径。

## Suggested skills

- `diagnose`：仅在目标机器复现失败后定位原因。
- `tdd`：确需修复首版验收缺陷时，先补回归检查，再做最小修改。
- `agent-note`：需要召回项目知识时使用已声明的 `gao-vm`；没有服务不阻塞验收。
- `cmd-git-commit`：获准提交验收修复时分组提交；未经授权不发布版本或操作其他机器/服务。
