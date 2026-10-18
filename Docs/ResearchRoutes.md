# 搞磁盘：NTFS 路线与许可研究

检查日期：2026-10-18（Asia/Shanghai）。这是文档研究，未安装 NTFS 引擎、macFUSE、SDK、系统扩展或后台服务，未挂载镜像或真实介质，未进行任何真实磁盘读写。第三方产品宣传中的“安全”不等于本项目已证明安全。本文的“候选”也不表示已获许可、已取得 entitlement 或已通过实机验收。

## 结论

建议完成普通文件镜像的只读识别与有界元数据分析；目前不建议进入真实磁盘写入开发。写入路线还缺少指定引擎与兼容层的许可组合确认、实际签名配置、NTFS 语义覆盖、断电恢复证据及 Windows 往返硬件验收。

如以后继续，优先做“合法 NTFS 引擎 + 直接 FSKit 适配”的独立只读概念验证，再决定是否投入写入。若采用 NTFS-3G，必须接受相应 GPL 源码与分发义务；若希望使用商业闭源方案，应先取得 SDK 的 macOS/CPU/FSKit 适配与再分发合同。两者都不能用零售版驱动的个人许可证代替。上述建议是本项目的工程判断。

## 路线比较

| 路线 | 文档支持与版本 | 系统/CPU 范围 | 权限、签名与用户成本 | 本阶段判断 |
| --- | --- | --- | --- | --- |
| 自编只读普通文件分析器 | 本项目仅实现声明过的子集，不宣称完整 NTFS 驱动 | 以本项目构建配置为准；无第三方引擎的兼容承诺 | 用户选取普通文件；只读 FD；无 mount、无块设备、无 root、无系统扩展；普通 App 的签名/分发规则仍适用 | 可继续；只允许识别、检查与报告 |
| NTFS-3G + macFUSE kernel backend | NTFS-3G 最新官方可见 tag 为 **2026.7.7**；macFUSE 稳定版 **5.4.0**，另有 5.5.0 developer preview。[N1][M1] | macFUSE 5.4.0 下载页列 macOS 12+、Apple Silicon/Intel；这只是兼容层范围。NTFS-3G 上游列有 macOS，但没有为此组合公布完整最低 macOS/CPU 验收表。[N2][M2] | 需要另装 macFUSE。Apple Silicon 首次启用 kernel backend 要求恢复环境中的 Reduced Security 和允许已识别开发者内核扩展；Intel/Apple Silicon 均有用户批准与重启流程。官方包声明签名/公证；这不覆盖本项目自己的二进制。[M3] | 不选择；安装与内核成本高，未验证组合 |
| NTFS-3G + macFUSE FSKit backend | FSKit API 自 macOS 15.4 可用；macFUSE 官网把全用户态路线描述为 macOS 26。后端 wiki 说明默认仍为 VFS，FSKit 须显式选用。[A1][M1][M4] | 保守候选目标为 macOS 26+、Apple Silicon；5.4.0 包本身列 Apple Silicon/Intel，不能据此宣称 NTFS 组合已验证。15.4～15.x 的具体后端适用性待查证，不作支持承诺 | FSKit backend 不要求内核扩展或修改恢复模式安全设置，但仍要安装依赖并启用相应扩展。5.2.0 新增 MFMount.framework 沙箱路线，要求 `io.macfuse.mount` Mach lookup exception。[M3][M5] | 仅保留研究；兼容层仍有许可、能力和维护成本 |
| NTFS 引擎 + 直接 FSKit 适配 | Apple 公开 FSKit 扩展点，示例通过 App Extension 提供文件系统；FSKit **不是 NTFS 引擎**。[A1][A2] | 框架可用性基线 macOS 15.4；若使用更新 API 则按 API availability 提高。Apple 文档并未给出本项目 NTFS 的 Intel/Apple Silicon 支持矩阵；计划先限定 Apple Silicon | 扩展需要 `com.apple.developer.fskit.fsmodule`；按 Apple 示例需要用户在“文件系统扩展”中启用。扩展 provisioning、团队能力与直接分发均须用实际账户核验；文档出现 entitlement 不代表本机已经获准。[A2][A3] | 最值得继续做只读概念验证；尚不能启用真实盘 |
| Tuxera 商业引擎/SDK | 官方商业 NTFS 技术规格写明 proprietary/commercial，并提供定制适配和维护；未发现可直接据此发货的公开 macOS FSKit SDK 合同。[C1] | 精确 SDK 版本、最低 macOS、arm64/x86_64、FSKit 适配均待厂商书面确认，不能从零售 Mac 驱动外推 | 商业付费、再分发/OEM、升级/SLA/终止后维护需合同。零售 Mac 安装指南仍涉及 kernel extension 和重启；这不是 SDK 的部署保证。[C2][C3] | 未获 SDK 与合同前，不下载后随包发行 |
| Paragon UFSD/File System Link SDK | 官方列 SDK libraries、kernel/embedded modules 和终端应用三类；标准评估包可免费申请，商业许可型号按需求协商。[C4][C5] | 官方平台表含 Mac，但 HTML 勾选数据及具体 NTFS SDK build/最低 macOS/CPU 不足以建立支持矩阵，待厂商确认 | 实际 SDK 是否纯用户态、是否能适配 FSKit、签名/entitlement、重启与分发费用均未知；不能把 APFS SDK CE 或零售 NTFS App 许可当成 NTFS SDK 许可 | 可作为采购候选，不能据公开宣传直接产品化 |
| 保持只读/停止驱动开发 | 可保留证据研究、普通文件检查和失败报告 | 范围随只读分析器声明，不承诺系统卷兼容 | 无驱动依赖、无需降低安全或批准扩展 | 当前推荐的发布能力边界 |

“macFUSE 包 macOS 12+”“FSKit API 15.4+”“本项目建议 FSKit 组合以 26+ 为起点”是三个不同范围。没有把后两者混同为最低版本保证。macFUSE 当前 wiki 还列出 FSKit backend 的挂载位置、read/write 打开模式、通知 API、mount options 与性能限制；尤其不能仅凭 `ro` UI 开关声称底层已无法写入。[M4]

## FSKit 与 NTFS 的责任分界

FSKit 负责把文件系统扩展接入 macOS：资源探测、卷和目录/文件操作的协议及系统协调接口。Apple 的 passthrough 示例把操作转到已有宿主文件系统，未提供 NTFS 解析或恢复实现。[A2]

本项目若未来接入 NTFS，应由合法取得的 NTFS 引擎负责 boot/MFT/属性/runlist、空间分配、NTFS 日志与恢复、压缩/稀疏/ADS、ACL/SID、链接、名称和时间语义。适配层负责将引擎能力准确映射到 FSKit，拒绝不能无损表达的操作；I/O 协调层负责单卷锁、缓存一致性、顺序、刷盘、断连/睡眠/崩溃。FSKit 不会替代这些工作，也不会自动给某个引擎的崩溃恢复或数据完整性背书。这是由 API 责任划分得出的设计判断。

直接适配 NTFS-3G 的 GPL 库并不会消除 GPL 义务；包装到 Swift、静态/动态链接、另建 XPC 进程或改称“插件”，都不能未经分析就断言闭源分发成立。商业引擎也必须明确允许 FSKit 适配、向最终用户再分发、目标 CPU/OS 与灾难恢复用途。

## 分层许可、分发与退出设计

| 层 | 已确认的官方文本 | 发货前需要的具体证据 | 更新与退出 |
| --- | --- | --- | --- |
| NTFS-3G 引擎、ntfsprogs、libntfs-3g | 上游 README：GPL v2 或更新版本；fuse-lite 为 LGPLv2。[N2] | 锁定 tag/commit/hash；逐文件许可证与补丁清单；附许可证和版权；二进制对应完整源码、构建/安装脚本；修改声明；链接/衍生关系与分发条款相容性审查。GPL 允许商业分发，但须履行许可证义务。[N3] | 跟踪官方安全修复；停止写支持时保留只读导出与源码取得渠道；不自动捆绑 ntfsfix/mkntfs 等修复/格式化工具 |
| macFUSE 二进制、核心与库 | 当前 LICENSE 第 4 条限制随商业软件捆绑二进制，含该情境的自动下载/安装，须事先书面许可；还包含其他组件许可。[M6] | 不能把“部分源码可见”解释为全栈开源。官方说明 3.9 起部分组件（如 kernel extension）不再开源，商业捆绑/集成需付费许可。[M7] | 从官方版本渠道锁定依赖；核验 hash/签名；许可或维护中止时禁用该路线并提供迁移说明；不改装旧版来绕过限制 |
| 第三方 macOS 补丁/插件/压缩支持 | 未采用，也未核定任何 fork 的完整许可证、维护和 CPU/OS 支持 | 每个补丁独立来源、许可、构建与安全审计；上游声明支持压缩插件不等于具体插件可随包发行 | 未明确则不下载/不打包；不以网络教程替代官方支持 |
| 商业 SDK 与兼容层 | Tuxera 为 proprietary/commercial；Paragon 需协商许可。[C1][C5] | SDK build/ABI、二进制/源码权利、目标 OS/CPU、FSKit、并发/设备数/OEM 数量、版税、支持期、漏洞修复、修改权、最终用户条款、终止后既有用户权利、可再分发清单 | 约定长期只读/数据导出、版本冻结与安全更新、供应商退出/托管条款；未获合同不随 App 分发 |
| Apple Framework/SDK 与分发 | 系统提供 FSKit；本项目不分发 Apple framework。Apple 对店外分发的公开流程要求签名及公证，涵盖驱动/扩展。[A4] | 实际 Developer ID 或实际本地开发签名、hardened runtime、entitlement/profile 匹配、公证票据；本地开发签名不能声称公证 | SDK license/Developer Program 合约按实际账户；无签名/授权时停在普通文件分析器 |

未建立 SDK 价格保证；厂商没有公开适用于本项目的合同报价。免费评估、个人使用、商业使用、商业捆绑和 SDK 再分发是不同授权范围。

## 验证分级与下一步门槛

| 证据等级 | 本文状态 |
| --- | --- |
| 官方文档显示支持 | 已检索；仅支持上表明确写出的事实 |
| 本机编译/链接验证 | 本文未执行第三方引擎、macFUSE 或 FSKit 扩展的编译/链接；本项目自身检查以独立构建报告为准 |
| 实际 entitlement/provisioning 可得性 | 未核验 Apple 开发者账户中的 FSKit 能力；没有替用户申请或开启 |
| 真机扩展启用、挂载、Windows 往返、故障恢复 | 全部未验证；未运行冒烟测试 |

进入任何写入开发前必须冻结引擎/适配层版本和许可；取得指定空白外置盘及破坏性操作的明确授权；建立 Windows 参考系统与 OS/CPU 矩阵；先通过完全只读门槛；逐项证明 ACL/ADS/链接/名称/压缩/稀疏/日志能力；建立断电、满盘、崩溃、睡眠、并发与热拔插的失败判据。若无法证明日志/权限/缓存语义或恢复承诺，就保持只读。普通文件备份不能作为任意卷级更改的回滚保证。

## 原始来源

全部检查于 **2026-10-18**。只使用 Apple、上游项目与厂商官方来源；没有把搜索结果中的论坛用户说法当成厂商保证。部分 Apple 页面需 JavaScript；使用官方搜索索引可读取的正文核查，不能读取的细节明确留空。

- A1：Apple [macOS Sequoia 15.4 Release Notes — FSKit](https://developer.apple.com/documentation/macos-release-notes/macos-15_4-release-notes)。
- A2：Apple [Building a passthrough file system](https://developer.apple.com/documentation/FSKit/building-a-passthrough-file-system)。
- A3：Apple [com.apple.developer.fskit.fsmodule](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule)。
- A4：Apple [Distributing your app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)。
- N1：Tuxera [NTFS-3G tags](https://github.com/tuxera/ntfs-3g/tags)。
- N2：Tuxera [NTFS-3G 2026.7.7 README](https://raw.githubusercontent.com/tuxera/ntfs-3g/2026.7.7/README)。
- N3：Tuxera [NTFS-3G 2026.7.7 COPYING](https://raw.githubusercontent.com/tuxera/ntfs-3g/2026.7.7/COPYING)。
- M1：macFUSE [官网与稳定/预览版本](https://macfuse.github.io/)。
- M2：macFUSE [5.4.0 release notes](https://macfuse.github.io/2026/09/07/macfuse-5.4.0.html)。
- M3：macFUSE [Getting Started](https://github.com/macfuse/macfuse/wiki/Getting-Started)。
- M4：macFUSE [FUSE Backends](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)，页面标记更新于 2026-10-16。
- M5：macFUSE [5.2.0 release notes](https://macfuse.github.io/2026/04/09/macfuse-5.2.0.html)。
- M6：macFUSE [当前 LICENSE](https://raw.githubusercontent.com/macfuse/macfuse/release/macfuse/LICENSE.txt)。
- M7：macFUSE [Open Source Status](https://github.com/macfuse/macfuse/wiki/Open-Source-Status)。
- C1：Tuxera [Microsoft NTFS 技术规格](https://www.tuxera.com/app/uploads/2025/06/Tuxera_NTFS_tech_specs_public_20240725.pdf)（官方索引正文可读，直接获取 PDF 返回 403；因此未检查合同附件或二进制）。
- C2：Tuxera [2026 Quick Start Guide](https://ntfsformac.tuxera.com/wp-content/uploads/2026/04/NTFS-for-Mac-Quick-Start-Guide.pdf)。
- C3：Tuxera [多台 Mac 的许可证范围](https://macsupport.tuxera.com/hc/en-gb/articles/360021071500-What-if-I-own-several-Macs-Can-I-use-the-same-license-for-all-of-my-computers)。
- C4：Paragon [File System Link](https://www.paragon-software.com/technologies/file-system-link-business/)。
- C5：Paragon [Technology Center — evaluation and licensing](https://www.paragon-software.com/technologies/)。
