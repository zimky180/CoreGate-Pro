# CoreGate pro

面向全机型适配的 CoreGate 开发仓库，由 zimky 维护。

当前为开发基线，尚未完成全机型适配。基于 CoreGate v2.3.0 最新冻结修复提交：
https://github.com/zimky180/CoreGate/commit/040d71f493b8a29d5b07010f94977374d1b9271a

## 当前内容

- 完整继承最新版模块源码及冻结、解冻修复，保留原许可及来源说明。
- 显示名称为 CoreGate pro，开发版本为 v2.3.0-pro-dev。
- 模块 id 与数据目录继续使用 CoreGate，以保持现有 App 命令接口兼容。当前与普通版不能并行安装，刷入会替换同 id 模块。
- App 继续使用现有 CoreGate-App，本仓库当前维护模块，不复制或改动 App 源码。
- 尚未完成其他机型验证，基线包不代表已支持所有 CPU、GPU 或厂商系统。

## 适配方向

1. CPU：动态枚举 policy*、核心拓扑及真实可用频率档位，替换固定簇路径和专用频率。
2. GPU：分别处理 Adreno、Mali / Immortalis，读取可用节点及档位；不支持时跳过对应控制。
3. 温度：探测传感器类型、单位与可用性，明确温度来源。
4. 冻结：按系统能力识别支持情况，核实各厂商包名和恢复行为。
5. 能力状态：逐项报告锁核、CPU 限频、GPU 限频和温度支持情况，后续与 App 配套展示。

原版说明与历史更新保存在 [UPSTREAM-README.md](UPSTREAM-README.md)。

## 下载与关联项目

- 开发包：https://github.com/zimky180/CoreGate-Pro/releases
- 原版模块：https://github.com/zimky180/CoreGate
- 现有 App：https://github.com/zimky180/CoreGate-App

开发基线只完成项目拆分和命名，尚未改变运行时硬件控制逻辑。
