# CoreGate Pro

> 全机型适配的 Android 锁核 / 限频内核门控模块（Magisk / KernelSU / APatch 通用）。

**锁核与限频是独立重写的，不是 CoreGate 那套逻辑。** 本版的限频按百分比走、动态枚举全部 CPU cluster，
并带 PSI 负载 / 温度 / 充电 / 电量自适应；锁核走请求日志与互斥锁做增量切换。

- 面向**骁龙 8 Gen 5 以外**的机型。8 Gen 5 请用 [CoreGate](https://github.com/zimky180/CoreGate)。
- 配套管理 App：[CoreGate-App](https://github.com/zimky180/CoreGate-App)。
- 最新版本：**v2.4.2-pro**，发布说明见 [RELEASE-NOTES.md](RELEASE-NOTES.md)，历史见 [CHANGELOG.md](CHANGELOG.md)。

> ⚠️ 本版为**全机型适配开发版**（`module.prop` 标注为「全机型适配开发版；基于 CoreGate v2.3.0，兼容性仍在开发」）。
> 硬件枚举是通用的，但不同 SoC 的节点命名、档位结构、热区命名差异很大，遇到不适配的机型请提 Issue 并附 `service.sh --hardware-status` 输出。

---

## 与 CoreGate（标准版）的区别

这是本仓库最需要先说清楚的一件事：**两个模块的同名功能，实现是两套完全不同的代码。**

| 维度 | CoreGate（标准版） | **CoreGate Pro（本仓库）** |
|---|---|---|
| 适配机型 | 仅骁龙 8 Gen 5 | 通用，按 sysfs 动态枚举 |
| CPU cluster | 固定 `policy0` / `policy6` | `cg_cpu_policies()` 遍历 `policy*`，按最大频率排序分 BIG / MID2 / MID / LITTLE 四档 |
| 限频方式 | 固定 MHz 常量 | **百分比**（`cpu_pct_*`、`gpu_pct`）换算成 MHz，再取不超过目标的最高可用频点 |
| 频率档位 | 硬编码档位表 | 读 `scaling_available_frequencies`（回落 `time_in_state`），实时枚举 |
| 自适应 | 无 | PSI 负载 / 温度 / 充电 / 电量四路自适应叠加 |
| 锁核切换 | 静态名单遍历 | `core.lock` 目录互斥 + `core.request` 请求日志，只对新旧差集做增量 `set_cpu` |
| GPU 节点 | 单一路径 | KGSL / devfreq / mali 三类自动识别 |

如果你的机型是骁龙 8 Gen 5，用标准版更省事。其他机型用本版。

---

## 它解决什么问题

旗舰 SoC 的调度器倾向于「多开核换流畅」，代价是待机功耗与发热。
CoreGate Pro 反过来做：**平时只保留必要核心，只在真正需要时把核心放出来，并且按实时负载动态微调频率上限。**

| 场景 | 行为 |
|---|---|
| 日常使用 | 只封锁最高频的那一个（或你设定的 N 个）大核 |
| 打开游戏（命中 `packages.txt`） | 立即恢复全部核心；自适应临时交还给系统（`GAME_ACTIVE=1` 时跳过自适应提升） |
| 开始录屏 / 打开相机 | 自动恢复全部核心（`capture_boost` 开启时） |
| 息屏 / 亮屏 | 自动锁核 / 自动恢复 |
| CPU 压力升高（PSI） | 在 `adapt_up_max` 上限内抬高百分比 |
| 温度升高 | 按 `th_high` / `th_low` / `th_step` / `th_max` 逐步压低百分比 |
| 充电中 | `chg_uncap` 开启时下限抬到 `chg_pct`，放开限频 |
| 电量低 | `batt_low` / `batt_crit` 触发进一步削减 |
| 想彻底停手 | 一键恢复原始状态 |

**关闭 App 后模块照常运行，卸载 App 也不影响锁核。** 逻辑全在模块里，App 只是遥控器。

---

## 安装

### 要求

- 已刷入 **Magisk / KernelSU / APatch** 任一，并能正常获取 root。
- Android 13（API 33）及以上。
- 设备**不是**骁龙 8 Gen 5（是的话请用 [CoreGate](https://github.com/zimky180/CoreGate)）。

### 步骤

1. 从 [Releases](../../releases) 下载 `CoreGate-v2.4.2-pro.zip`。
2. 在 KernelSU / Magisk / APatch 管理器中「从本地安装」该 zip。
3. 重启设备。
4. 打开 [CoreGate-App](https://github.com/zimky180/CoreGate-App) 进行配置。

> **首次安装是「全关」状态。** 安装脚本只做初始化，不会自动开始锁核；必须进 App 打开 `enabled` 并选择要封锁的核心。
> 这是刻意设计——先让你确认硬件拓扑被正确识别，再开始动手。

安装过程中脚本会打印检测到的核心拓扑与建议封锁的高频大核，可以对照确认。

### 装完先验一件小事

```sh
su -c '/data/adb/modules/CoreGate/service.sh --hardware-status'
```

这会输出 Pro 的硬件枚举报告（cluster 划分、可用频率档、GPU 节点、温度源）。
**如果这里枚举不对，先别开限频**，把输出贴到 Issue 里。自适应全部建立在枚举正确的前提上。

### 安装脚本做了什么

- 清理旧版残留：旧 `daemon.pid`、旧日志、`state`、`crash_flag`、`corectl.state`、`log/`。
- 解压模块文件（排除 `META-INF`），按 755 / 644 设置权限，`service.sh`、`uninstall.sh`、`action.sh`、`bin/coregated` 赋 755，`hardware.sh` 赋 644。
- 首次安装把 `config.example.json` 复制为 `/data/adb/CoreGate/config.json`，**不覆盖已有配置**。
- 迁移旧版 `game_packages` 到 `packages.txt`；没有则写入内置默认游戏列表。
- 写入默认 `capture.txt`（录屏 / 相机包名）。
- 执行 `migrate-config.sh` 清理已删除功能残留字段，留 `config.json.pre-v230.bak` 备份。
- 检测核心拓扑，打印高频大核与建议。

---

## 使用

日常操作全部在 App 里：

- **锁核运行状态**：当前封锁的核心、前台包名、模块存活状态。
- **封锁核心**：选择要封锁的核心，附「建议再封锁一个」的组合建议。
- **策略**：录屏 / 相机自动恢复、息屏自动锁核、充电策略、温度策略。
- **日常限频**：小核 / 中核 / 大核 / GPU 百分比限频。
- **调试设置**：轮询间隔、自适应参数、配置直改、状态导出。

### 没有安装 App 时

KernelSU 模块页点「执行」，或直接命令行：

```sh
# 硬件枚举报告（排查适配问题第一手资料）
su -c '/data/adb/modules/CoreGate/service.sh --hardware-status'

# 手动锁一次 / 恢复
su -c '/data/adb/modules/CoreGate/service.sh --lock-once'
su -c '/data/adb/modules/CoreGate/service.sh --unlock'

# 冻结状态报告
su -c '/data/adb/modules/CoreGate/service.sh --freeze-status'
```

---

## 配置

配置文件：`/data/adb/CoreGate/config.json`
游戏名单：`/data/adb/CoreGate/packages.txt`（一行一个包名）
录屏 / 相机名单：`/data/adb/CoreGate/capture.txt`

完整字段见 [`config.example.json`](config.example.json)。

### 基础开关

| 字段 | 说明 | 默认 |
|---|---|---|
| `enabled` | 模块总开关 | `false` |
| `lock_cores` | 要封锁的核心，`auto` 为自动选最高频大核 | `"auto"` |
| `auto_lock_count` | 自动模式封锁几个核 | — |
| `disable_core_ctl` | 是否一并接管核心控制 | — |
| `no_lock_charging` | 打开后充电时不锁核 | 关 |
| `poll_interval` | 主循环间隔秒数 | `10` |
| `limit_freq` | 是否启用限频 | `false` |
| `capture_boost` | 录屏 / 相机自动恢复全部核心 | `false` |

### 限频（百分比）

Pro 用百分比而不是固定 MHz，这样才可能跨机型通用。

| 字段 | 说明 |
|---|---|
| `cpu_pct_big` / `cpu_pct_mid2` / `cpu_pct_mid` / `cpu_pct_little` | 各档 cluster 的频率上限百分比 |
| `gpu_pct` | GPU 频率上限百分比 |

cluster 分档规则：`cg_cpu_policies()` 枚举所有 `policy*`，按 `cg_cpu_max`（该簇最高可用频率）从高到低排序，
依次映射为 **BIG → MID2 → MID → LITTLE**。机型只有两簇时 MID/MID2 自然空置，不会报错。

**回退机制**：若某档没有配置百分比，则回退到老的固定值 `cap_little_mhz` / `cap_big_mhz` / `cap_gpu_mhz` / `cap_gpu_pwrlevel`。
所以你可以百分比和固定值混用。

换算后的 MHz 会经 `cg_cpu_target()` 取**不超过目标的最高可用频点**，并夹在 `scaling_min_freq` 之上，写前 `cg_cpu_save_one()` 快照、写后回读校验。

### 自适应

`adapt_enabled` 是总开关，以下是四路各自的分项。

#### PSI 负载自适应

读 `/proc/pressure/cpu`，用 `total` 与 `avg10` 计算 stall。

| 字段 | 说明 |
|---|---|
| `psi_adapt` | 是否启用 | 
| `psi_gain` | 压力换算增益 |
| `psi_step` | 每次调整步进 |
| `psi_hold` | 高压保持多少轮不回退 |
| `psi_back` | 回退判定窗口 |

#### 温度自适应

遍历 `thermal_zone*`，取名字含 `cpu` / `gpu` / `soc` 且不含 `trip` 的**最高温**。

| 字段 | 说明 |
|---|---|
| `th_cap` | 是否启用温度限制 |
| `th_high` | 高于此温度开始压低（默认 75℃） |
| `th_low` | 低于此温度开始回退（默认 68℃） |
| `th_step` | 每次调整步进 |
| `th_max` | 最多压低多少百分比 |
| `th_back` | 回退步进 |

#### 充电自适应

| 字段 | 说明 |
|---|---|
| `chg_uncap` | 充电时是否放开限频 |
| `chg_pct` | 放开时把百分比下限抬到这里 |

#### 电量自适应

| 字段 | 说明 |
|---|---|
| `batt_step` | 是否启用 |
| `batt_low` | 低电量阈值（默认 20） |
| `batt_low_cut` | 低于 `batt_low` 时削减的百分比 |
| `batt_crit` | 危险电量阈值（默认 10） |
| `batt_crit_cut` | 低于 `batt_crit` 时削减的百分比 |

#### 总体约束

| 字段 | 说明 |
|---|---|
| `adapt_up_max` | 自适应最多往上抬多少（默认 15） |
| `adapt_down_max` | 自适应最多往下压多少（默认 30） |

四路结果汇总成 `ADAPT_DELTA`，叠加到各百分比后夹在 1~100 之间。
充电且 `chg_uncap` 开启时，下限额外抬到 `chg_pct`。

### 温度策略（锁核侧）

| 字段 | 说明 | 默认 |
|---|---|---|
| `temperature_enabled` | 温度策略总开关 | — |
| `temperature_mode` | `lock`（高温锁核）/ `unlock`（高温解封） | `"lock"` |
| `temperature_threshold` | 阈值 ℃，可调 35~60 | `40` |
| `temperature_lock_cores` | 高温锁核时的目标核心 | — |

> `temperature_threshold` 读的是 **CPU / SoC 传感器温度**，不是机身表面温度。表面 35℃ 时传感器常有 45~50℃。
> 注意这个字段与上面的 `th_high` 是**两套不同机制**：前者是「温度到了就锁核」，后者是「温度到了就压频率」。

### 冻结分组

`freeze_grp_log` / `media` / `cloud` / `diag` / `ad` / `self` / `ai` / `voice` / `games` / `themes` / `search` 共 11 组，默认全关。

### 游戏名单

`game_lock_cores` / `temperature_lock_cores` 分别指定游戏态、温度态下要锁的核心集合。

---

## 锁核实现（为什么需要互斥锁）

Pro 的锁核不是简单遍历名单，而是**请求日志 + 目录互斥 + 增量切换**：

1. 拿 `core.lock` 目录互斥，带 pid 存活检测，最多重试 15 次，避免上一轮 daemon 挂掉留下死锁。
2. 把本次目标和上次目标都写进 `core.request`，格式 `locked:<cpu列表>`。
3. **只对差集调用 `set_cpu`**。已经是目标状态的核不动，避免反复上下线。
4. 结果逐核记进 `LOCK_STATE`，标记 ok / fail。
5. 解锁时写 `unlocked`。

为什么这么做：主循环 10 秒一轮，如果每轮都全量 `echo 0/1` 一遍，核心会在开关之间反复抖动，
既费电又有概率在关键时刻把核关了。增量切换把写入次数降到最低。

---

## 文件结构

```
CoreGate-Pro/
├── module.prop           模块元信息（version=v2.4.2-pro, versionCode=242）
├── customize.sh          安装脚本
├── service.sh            主入口，校验 lib 完整性后加载并跑主循环
├── hardware.sh           硬件抽象层：CPU cluster / 频率 / GPU / 温度源 枚举与写入
├── uninstall.sh          卸载清理（恢复原始状态）
├── action.sh             KernelSU 模块页「执行」按钮
├── migrate-config.sh     旧配置迁移
├── sepolicy.rule         SELinux 规则
├── update.json           模块内检查更新用
├── config.example.json   配置模板
├── packages.txt          游戏包名名单
├── capture.txt           录屏 / 相机包名名单
├── bin/coregated         守护进程二进制
└── lib/
    ├── config.sh         配置读写（awk 就地改写 JSON）
    ├── hardware.sh       CPU 在线控制封装（set_cpu / online_count）
    ├── freeze.sh         冻结管理
    ├── cores.sh          锁核：互斥 + 请求日志 + 增量切换
    ├── frequency.sh      限频：百分比换算 + 调自适应
    ├── probe.sh          前台包名 / 状态探测
    ├── runtime.sh        运行时状态
    ├── thermal.sh        温度读取与策略
    ├── adapt.sh          PSI / 温度 / 充电 / 电量自适应
    ├── lifecycle.sh      安装、卸载、启停生命周期
    └── commands.sh       命令行入口分发
```

`service.sh` 会**逐一校验上面 11 个 lib 文件存在**，缺一个直接退出。这不是可选的。

两个 `hardware.sh` 分工不同，别搞混：
- 顶层 `hardware.sh`（389 行）是**硬件抽象层**，负责 sysfs 枚举与写入，`service.sh` 最先 source 它。
- `lib/hardware.sh`（100 行）是**CPU 在线控制封装**，提供 `all_cpus()` / `set_cpu()` / `online_count()`，供锁核逻辑调用。

### 关键常量（顶层 `hardware.sh`，均可用环境变量覆盖）

| 变量 | 默认值 |
|---|---|
| `CG_CPU_ROOT` | `/sys/devices/system/cpu` |
| `CG_CPUFREQ_ROOT` | `$CG_CPU_ROOT/cpufreq` |
| `CG_KGSL_ROOT` | KGSL 节点根 |
| `CG_DEVFREQ_ROOT` | devfreq 节点根 |
| `CG_THERMAL_ROOT` | thermal 节点根 |
| `CG_POWER_ROOT` | power_supply 节点根 |

可用环境变量覆盖，方便在非标准机型上调试。

### GPU 写入的坑（已在 Pro 处理）

`cg_gpu_write()` 对 KGSL 做特殊处理：写完后回读，如果值不对就 `+800000` 重试一次（kgsl 的频率单位对齐坑），
结束后 `chmod 444` 锁住节点，防止系统调度器改回去。`cg_gpu_restore_caps()` 还原时会连权限位一起还原。

GPU 支持三种指定方式：`gpu_pct`（百分比）、`cap_gpu_mhz`（固定 MHz）、`cap_gpu_pwrlevel`（pwrlevel 索引）到 `-1` 表示不接管。

### 运行时文件

| 路径 | 用途 |
|---|---|
| `/data/adb/CoreGate/config.json` | 配置 |
| `/data/adb/CoreGate/packages.txt` | 游戏名单 |
| `/data/adb/CoreGate/capture.txt` | 录屏相机名单 |
| `/data/adb/CoreGate/state` | 上次前台包名 |
| `/data/adb/CoreGate/daemon.pid` | 守护进程 pid |
| `/data/adb/CoreGate/corectl.state` | 核心控制备份 |
| `/data/adb/CoreGate/manual_off` | 手动关闭标记 |
| 模块目录 `log/coregate.log` | 运行日志（不可写时回落 `/data/adb/CoreGate/log`） |

日志超过 262144 B 自动截断，保留最后 500 行。

---

## 安全与可逆性

**全程只改运行时 sysfs，不写任何系统分区，重启即完全还原。**

- 配置存在 `/data/adb/CoreGate/`（用户数据区），不在系统分区。
- 卸载模块执行 `uninstall.sh`，恢复核心在线状态与频率上限（含 GPU 权限位）。
- `cpu0` **永不下线**，避免把自己锁死。
- 锁核有目录互斥 + pid 存活检测，不会因 daemon 异常退出而永久卡死。
- 频率写入前快照、写入后回读校验，写不进去会记录失败而不是假装成功。

### 刷入翻车了怎么救（保命三条）

1. 删除 `/data/adb/modules/CoreGate/` 与 `/data/adb/CoreGate/`，重启即恢复。
2. 在模块目录 `touch disable` 做空载验证，确认没问题再放开。
3. 进 Recovery 删掉模块目录，100% 有效。

---

## 常见问题

**Q：装完没反应？**
首次安装默认全关，需要在 App 里打开 `enabled` 并选择核心。

**Q：限频没效果？**
先跑 `service.sh --hardware-status` 确认 cluster 和频率档枚举对不对。枚举错了百分比怎么算都写不进去。

**Q：为什么限频是百分比而不是填 MHz？**
因为要跨机型。同一档 MHz 在不同 SoC 上意义完全不同，百分比才对得上「压到 80% 性能」这个意图。
如果你就是想填死值，`cap_*_mhz` 仍然保留可用。

**Q：自适应会不会乱调？**
调幅受 `adapt_up_max` / `adapt_down_max` 双向夹住（默认 +15 / -30），且有 `psi_hold` 保持窗口防抖。
实在不放心可以关掉 `adapt_enabled`，只剩静态百分比。

**Q：前台包名显示空 / `-`？**
ColorOS 系 `dumpsys` 有时取不到焦点窗口，属于已知现象。

**Q：我的机型枚举不出 GPU 节点？**
Pro 认 KGSL / devfreq / mali 三类。不在其中的节点命名需要提 Issue 补适配，请附 `--hardware-status` 输出。

**Q：本版能装在骁龙 8 Gen 5 上吗？**
能装，但没有意义。那个平台用 [CoreGate](https://github.com/zimky180/CoreGate) 标准版，档位是对着它调的。

---

## 相关仓库

| 仓库 | 说明 |
|---|---|
| [CoreGate](https://github.com/zimky180/CoreGate) | 骁龙 8 Gen 5 专用标准版 |
| **CoreGate-Pro**（本仓库） | 全机型适配版，锁核与限频独立重写 |
| [CoreGate-App](https://github.com/zimky180/CoreGate-App) | 配套 Android 管理 App（开源） |

## 溯源与许可

- 本模块部分冻结相关实现参考上游项目，见 [`FREEZE-UPSTREAM.txt`](FREEZE-UPSTREAM.txt)。
- 场景配置参考上游，见 [`SCENE-UPSTREAM.txt`](SCENE-UPSTREAM.txt) 与 [`SCENE-LICENSE.txt`](SCENE-LICENSE.txt)。
- 构建与来源信息见 [`PROVENANCE.json`](PROVENANCE.json)。
- 本仓库代码：MIT，见 [LICENSE](LICENSE)。

作者：zimky