# Apple Silicon 首版验收检查点

日期：2026-10-16。**已生成本机开发候选包，尚未达到首版发布门槛。** 本检查点续接
[REMAINING_WORK.md](../REMAINING_WORK.md)，不扩大到升级/回滚、Flutter UI、MCP 或 clone；不做 Chrome integration。

## 基线、环境与证据

- 代码基线：`c1ee3ce546a21930f1ab6236f74b171ba923b596`；分支：`codex/first-release-acceptance`。
- 本机：Apple Silicon `arm64`，macOS **27.0.1 / 26A434**，32 GiB RAM、10 CPU，`kern.hv_support=1`。
- Dart **3.9.0**，使用校验过 SHA-256 的独立 macOS ARM64 SDK；五个控制平面包均已通过 `pub get --enforce-lockfile`，没有更新锁文件。
- Apple Swift **6.4**（`swiftlang-6.4.0.34.1`）；Rust **1.96.1**（`31fca3adb`，host `aarch64-apple-darwin`）。
- 持久证据目录：`.dart_tool/releases/0.1.0-arm64/acceptance/`。原始收据保留执行时的 `/tmp/gva-1016-8hwW7s` 路径；迁移映射见 `relocation.json`，已保存的 SDK 与镜像 hash 复核见 `preservation-verification.json`。
- 当前代码修改仅涉及测试：SwiftPM 通过 `--show-bin-path` 定位真实 ARM64 service helper 和本机 debug driver；fragmented-prefix fixture 先确认发送 worker 就绪再开始原有 deadline。生产认证、generation、census 和运行时 deadline 均未修改。

## 已验证结果

以下为各自命令的实际结果，不把重复运行累加成新的覆盖数：

| 检查 | 本次结果 | 证据目录内入口 |
| --- | --- | --- |
| JSON Schema / OpenAPI | 通过 | `contracts.*` |
| Dart models | 103 通过 | `models-tests/` |
| Dart RPC | 5 通过 | `rpc-tests/` |
| Dart API client | 87 通过 | `api-client-tests/` |
| Dart CLI | 166 通过、2 跳过 | `cli-tests/` |
| Swift driver | 146 通过 | `native/driver-test-fixed.*` |
| Swift service helper | 17 通过 | `native/service-test.*` |
| Swift 6.2.3 strict lint | driver、service 两个完整 CI scope 通过 | `pinned-swift-format/` |
| Rust guest crate | 195 通过 | `native/rust-test.*` |
| 真实 ARM64 service helper 组装 | 1 通过、0 跳过 | `real-service-assembly-fixed/` |
| 真实 Swift driver 定向集成 | 3 通过、0 跳过 | `native-driver-discovery/targeted-fixed/` |
| driver manager / supervisor 两个完整文件 | 55 通过、0 跳过 | `native-driver-discovery/both-files/` |
| Legacy migration 文件 | 15 通过 | `legacy-native-baseline/` |
| daemon 启动文件 | 3 通过、2 失败 | `daemon-startup-baseline/` |
| daemon 默认并发全套（driver 路径修复前） | **2171 通过、4 跳过、2 失败；退出码 1** | `daemon-tests-default/` |

CLI 的两项跳过是“拒绝不支持的 native host”检查；当前 ARM64 macOS 属于支持的 host。
daemon 全套耗时 1558.232 秒；只有下述两个启动用例失败。四项跳过包括一项 Linux-only 检查，
以及后来已修复并实际通过的三个真实 driver 用例。路径修复后的两个完整文件已复跑，
尚未重跑最终 checkout 的全套，不能把后续定向结果改写为原始全套全绿。汇总见 `daemon-result-summary.json`。
五个控制平面包的 Dart 格式与分析通过。Rust format、clippy、`--all-targets --locked` 构建及
`aarch64-unknown-linux-gnu` 类型检查通过；Linux 类型检查没有生成或运行已安装的 Linux Guest service。
Swift driver/service 的本机与 ARM64 release 构建完成。另在私有目录构建了未经修改的官方
`swift-6.2.3-RELEASE` formatter 源码，实际版本为 `6.2.3`；变更测试及两个 Swift package 的
`lint --strict --recursive Package.swift Sources Tests` 均通过。源码、依赖 commit、archive hash 与
命令保存在 `pinned-swift-format/`；这没有替代远端 Xcode workflow 的实际通过证据。

Swift fixture 已保留延迟发送的失败复现，以及修复后的 50 次通过和最终 146 项通过。
真实 helper 的旧测试在已经成功构建后仍跳过，修改后实际组装并验证签名通过。
三个真实 driver 用例也因硬编码旧 build 路径而跳过；改为 SwiftPM 路径查询后，
Guest 开发开关、无 VM 的 stop/exit 和 transitional v1.2 启动检查均实际通过，已确认相应用例子进程退出。
这些结果没有证明真实 VM、Guest、安装服务或发布验收通过。

## 当前阻塞：完整 native process census

两个 source-daemon 启动用例仍失败：

- `installed daemon completes a pre-cancelled TestRun without client polling`
- `installed daemon serves the VM catalog over HTTP UDS`

独立 source-daemon 启动在约 2 秒后以退出码 `1` 结束，原始错误为：

```text
gaovmd startup failed: Bad state: process inventory contains unresolved executables
```

两次独立 census 都观察到 **13 个既存、同用户进程**无法解析 executable，
`proc_pidpath` 返回 `errno = 2`。已映射的 executable 路径均不存在；该现象与机器慢的解释不同。
没有匹配到此次 driver 不等于能证明所有未解析进程均非 driver，因此完整清点屏障继续拒绝启动。
证据为 `inventory.json`、`unresolved-process-evidence.json`、`unresolved-executable-paths.json` 和
`source-startup-diagnostics/`，没有把失败改记为通过。
全套结束后再运行两轮 census，仍是同一组 13 个既存 PID，没有新增 unresolved PID；
`census-after-tests/` 保留退出码 `2` 与完整结果。原始测试、日志、SDK 和镜像现均已持久保存，迁移无待完成项。

需要宿主环境所有者处理这些既存进程的失效 executable 映射状态，取得完整清点后再继续。
本次没有修改 census、认证或 generation 检查，也没有调整 readiness deadline 或操作这些既存进程。

## 本机候选包与测试镜像

本机开发候选暂用版本 **0.1.0**、bundle ID **`org.gaoos.GaoVM`**，正式分发身份尚未确认：

- `.dart_tool/releases/0.1.0-arm64/package/GaoVM.app`
- `.dart_tool/releases/0.1.0-arm64/GaoVM-0.1.0-arm64-development.zip`
- `.dart_tool/releases/0.1.0-arm64/candidate-manifest.json`

四个组件均为 ARM64；app 的 `codesign --verify --deep --strict`、已签名组件信息、daemon/CLI/service
的 help 与 service 的只读 status 探测通过。status 观察到 `notFound`，没有注册服务。
manifest 明确标记 `release_ready: false`。签名仅为 **ad-hoc development**；driver 仅具
virtualization entitlement，Dart daemon/CLI 仅具已接受的 executable-memory exception，service 无 entitlement。
这不证明完整 packaged-daemon startup、launchd 生命周期、Developer ID 签名、notarization 或 Gatekeeper 接受。
ZIP 的 CRC 检查、独立提取后的严格签名及四个组件 hash 均通过，收据见 `archive-validation.json`。
archive SHA-256 为 `e9d5bfdb0cd0462d5deb44c1d4495bd82b510d681504efdf057925ced6b7d7f3`。

另已用固定 Rust 工具链交叉链接 Linux Guest 开发产物：
`.dart_tool/releases/0.1.0-arm64/guest-linux/gaovm-guestd`，目标 `aarch64-unknown-linux-musl`。
ELF header 确认为 ARM64、静态链接、无动态 interpreter 或 `DT_NEEDED`；构建退出码为 `0`。
SHA-256 为 `f7d5aa16de081e262bd7222851e7aacf1aa8d362fdd55681f054a5a22d8bcf3d`。
同目录 `manifest.json` 和 `acceptance/guest-linux-build/` 保存工具链、锁文件 hash 与原始构建日志。
它尚未在 Linux 运行或装入 GaoOS，不能据此认定 vsock、Guest readiness 或 TestRun 已通过。

通用 Linux 输入已准备在证据目录的 `images/`，**从未启动 VM**：

| 输入 | 相对 `acceptance/` 的路径 |
| --- | --- |
| 未压缩 ARM64 kernel | `images/Image` |
| 匹配 initrd | `images/noble-server-cloudimg-arm64-initrd-generic` |
| 独立 whole-root ext4 disk | `images/ubuntu-root.raw` |
| 来源、命令、退出码、派生 hash | `images/preparation-receipt.json` |

来源为 Canonical Ubuntu 24.04 LTS ARM64 cloud build `20260926`；三个原始下载均匹配固定 SHA-256。
QCOW2 无 backing，GPT 主备 CRC、partition bounds 和 ARM64 Image header 已核对。
从实际 root partition 提取 ext4，保留 root label/UUID，仅在可丢弃副本内停用独立 `/boot`、`/boot/efi`
挂载；修改前后 `e2fsck -f -n` 均通过。输入保持只读、静止，供 public import 再创建 managed writable copy。
准备脚本的一次 whitespace-parser 失败与修正后的成功收据均已保留。Ubuntu 仅供无 Agent 的通用 Linux 验收，
不能代替实际 GaoOS/Guest/TestRun 输入或通过证明。

## 恢复顺序与命令

以下从仓库根目录执行。先核对候选 manifest、证据 relocation manifest、SDK 与输入 hash；
若 checkout 或宿主环境变化，重新确认依赖、工具链和基线。先取得完整 process census，再复核启动文件：

```sh
gaovm_repo="$PWD"
gaovm_acceptance="$gaovm_repo/.dart_tool/releases/0.1.0-arm64/acceptance"
gaovm_dart="$gaovm_acceptance/sdk/dart-sdk/bin/dart"
"$gaovm_dart" --version
"$gaovm_dart" --packages="$gaovm_repo/daemon/gaovmd/.dart_tool/package_config.json" \
  "$gaovm_acceptance/census.dart"
```

此只读 probe 执行两轮同用户 executable 清点；退出码 `2` 表示仍有 unresolved PID，
需要继续处理宿主环境，不能进入 VM 验收。`/bin/cat` 仅为 probe 的匹配目标；零匹配不证明不存在 driver。
完整清点返回 `0` 后，再执行启动测试：

```sh
(cd daemon/gaovmd && "$gaovm_dart" test test/daemon_application_test.dart --concurrency=1)
```

取得完整清点且启动文件通过后，重新保留最终 checkout 的默认并发全套结果：

```sh
(cd daemon/gaovmd && \
  GAOVM_GUEST_FIXTURE="$gaovm_repo/guest/gaovm_guestd/target/debug/examples/host_publication_fixture" \
  "$gaovm_dart" test --reporter expanded)
```

启动屏障通过后，按 [native smoke](NATIVE_VM_SMOKE.md) 分别运行单 VM 和三 VM。
每次保留完整 stdout/stderr、打印的私有 state 路径与退出码；只有前一次清理已确认完成才运行下一次。
脚本创建新的短私有状态和已签名 driver 副本，不使用候选 app 的默认用户状态：

```sh
DART_BIN="$gaovm_dart" \
KERNEL_PATH="$gaovm_acceptance/images/Image" \
INITRD_PATH="$gaovm_acceptance/images/noble-server-cloudimg-arm64-initrd-generic" \
DISK_PATH="$gaovm_acceptance/images/ubuntu-root.raw" \
bash scripts/e2e_macos14_happy_path.sh
```

第一轮成功且确认清理后，使用相同四个环境变量执行：

```sh
DART_BIN="$gaovm_dart" \
KERNEL_PATH="$gaovm_acceptance/images/Image" \
INITRD_PATH="$gaovm_acceptance/images/noble-server-cloudimg-arm64-initrd-generic" \
DISK_PATH="$gaovm_acceptance/images/ubuntu-root.raw" \
bash scripts/e2e_macos14_happy_path.sh --multi-vm
```

首版尚需以下真实证据，按 [PRD AC-01 至 AC-10](PRD.md#12-产品验收场景) 逐项记录：

- Linux 实际 boot/serial、framebuffer/input、手动关窗后 VM 存活、双 VM 显示与独立磁盘/driver 生命周期。
- 单 VM driver crash 与旧 generation 拒绝、双 VM daemon restart、无 orphan；幂等 retry、revision 冲突、event cursor resume 及私有 UDS/token 默认值。
- 实际包含 resident Guest service 的 GaoOS 镜像来源与构建；按 [Guest development acceptance](GUEST_DEVELOPMENT_ACCEPTANCE.md) 显式开启入口，在匹配 VM spec/port 下先观察 `guest_agent_ready`。
- GaoOS exec 成功/非零退出、timeout/cancel、输出 spill、两 VM 隔离，以及 TestRun 成功清理/失败保留和公开下载的实际 bytes/digest。
- 具体 app 的手动安装、service 同意/启动/重启/卸载验收，以及所选分发方式需要的签名验证（需要公证时另做 notarization）；现有组装与只读 status 不覆盖这些动作。
- 清点和启动恢复后，最终 checkout 的 daemon 默认并发全套通过结果，以及对应候选版本的远端 CI/Tests 通过证据。

基线远端 [CI 38871778044](https://github.com/Gao-OS/Gao-VM/actions/runs/38871778044) 的 legacy census fixture
发生 broken pipe；[Tests 38871778273](https://github.com/Gao-OS/Gao-VM/actions/runs/38871778273) 的 Swift
fragmented-prefix fixture 发送失败。本机结果与修复已分开记录，尚无修复后远端 workflow 通过证明。
