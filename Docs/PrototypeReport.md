# V1.00 只读原型报告

检查日期：2026-10-18。本报告仅针对普通文件解析与隔离合成样本；不把结果扩展为 Windows 格式化卷兼容、真实硬件或写入安全证明。

## 本机环境

- macOS 27.0.1（26A434），arm64。
- Xcode 27.0（27A266a），Apple Swift 6.4。
- 编译目标：arm64-apple-macos14.0；最低 macOS 14。只在当前本机工具链编译，未在 macOS 14/15/26 或 Intel 机器运行。
- 实际有效 Apple Development 证书已核实并用于本地签名；没有 Developer ID 公证，没有申请 FSKit entitlement。

## 实际能力

固定 `O_RDONLY` 文件描述符，逐级 `openat + O_NOFOLLOW` 读取用户明确选取的普通文件，拒绝目录、符号链接、多硬链接、非当前用户拥有的输入和设备。读取前后以 FD 核对身份、大小、模式与时间；不能证明抵御恶意同用户并发修改。

可检查 NTFS / BitLocker OEM 标识、boot sector 几何与边界、FILE 记录 USA fixup、基本属性长度与标识、驻留 FILE_NAME / STANDARD_INFORMATION / VOLUME_INFORMATION、非压缩/非加密/非稀疏 MFT DATA 的有界 runlist。父引用只在已读范围内检查序列/目录类型和循环；不构造可信全路径，不跟随重解析点。

依据属性或文件标志报告 ADS、硬链接、EFS、压缩、稀疏、重解析点等“发现标识”；未发现均保持未知。复杂属性列表、扩展 MFT 记录、未知布局或超预算内容拒绝，不尝试兼容修复。BitLocker 只识别并停止，不要求密码。

全部 NTFS 报告 `status=partial`、`directoryInventoryComplete=false`；所有写、挂载、修复、格式化与写入安全验证能力为 false。没有读取目录索引、完整安全描述符、数据正文或日志，没有进行 Windows 往返。

## 安全预算

- 普通镜像最大 1 TiB，单次读取最大 1 MiB，总读取最大 64 MiB。
- 全文件 SHA-256 只对不超过 16 MiB 的源计算；更大镜像报告 `sourceSHA256=null`，清楚说明未计算全文件哈希。
- 最多检查 512 个 MFT 槽，单记录最大 64 KiB，单记录最多 256 属性，runlist 和父引用深度有界。
- 输出名称文本最多 1 MiB、名称引用最多 8192 项；字段/计数另受记录上限约束，避免无界报告对象。
- 10 秒是协作式检查截止时间；取消亦在检查点生效。网络/FUSE 或故障宿主文件系统上的阻塞 `pread` 不能由该时限硬中断，UI不得承诺硬超时。
- 报告导出最多 8 MiB，只新建目标：逐级父 FD、拒绝链接、0600、分块同 FD 回读、fsync 和无覆盖原子发布。任何已有目标（含源镜像或已移动源）均拒绝覆盖。

## 合成样本来源

测试程序自行生成最小 NTFS 结构；原创样本不包含用户正文、真实卷、Windows 安装映像或商业驱动。它只用于解析边界验证，不是完整 Windows 格式化文件系统。样本在隔离临时目录生成，来源、SHA-256 与解析结果由测试记录。主要 65536 字节样本的 SHA-256 为 `557b279bc9afa49cd0e266f233396bd6a338dd54eb3e398b92423c9d5d55e276`。坏样本仅做普通文件变异，不调用挂载或系统修复。

## 定向验证

最终执行结果和测试数量见本项目交付记录。测试入口为 `Scripts/test-core.sh`、`Scripts/test-export.sh` 及安装脚本隔离测试。核心覆盖合法结构、截断、签名、偏移/乘法溢出、属性/记录长度、父引用循环、重复标识、runlist重叠、超大字段、链接/设备拒绝、取消/源变化和只读前后摘要；导出覆盖已有文件保护与并发无覆盖。

源码通过 Swift 6 类型/并发检查；正式包签名、Info.plist/能力表、压缩包解压结果与安装内容另做静态核验。

未运行冒烟测试；未启动 App、浏览器、模拟器或测试 GUI。真实窗口、快捷键、用户选择/授权/保存面板、Windows NTFS 镜像、OS/架构矩阵和硬件行为均未验证。测试结果只支持对应实现边界。

## 结构依据与许可范围

2026-10-18 查阅 Microsoft 官方开发说明：[MFT](https://learn.microsoft.com/en-us/windows/win32/devnotes/master-file-table)、[FILE_RECORD_SEGMENT_HEADER](https://learn.microsoft.com/en-us/windows/win32/devnotes/file-record-segment-header)、[ATTRIBUTE_RECORD_HEADER](https://learn.microsoft.com/en-us/windows/win32/devnotes/attribute-record-header)。官方说明本身限定 NTFS 3.x，不能据此外推所有版本或恢复能力。本项目采用自行编写的有界 Swift 实现，没有链接或捆绑第三方 NTFS 引擎。

## 结论

可以交付普通文件只读研究工具，并继续补充独立参考镜像证据。当前不建议进入真实卷写入开发；设备、许可、权限语义与故障恢复门槛见下一阶段计划。
