# 搞磁盘 V1.00

原生 SwiftUI + AppKit 的 NTFS 普通镜像只读分析 App，Apple Silicon / macOS 14+，build 1。当前版本不提供真实磁盘访问、挂载、写入、解密、修复或格式化能力，也不安装驱动。

用户此次明确要求开发并本机安装，因此交付可安装只读 App；原始需求中的研究、安全和真实介质边界继续有效。研究完成不等于 NTFS 读写产品完成。

## 使用

选择普通 NTFS 原始镜像（文件系统从偏移 0 开始），查看引导几何、有限 MFT 名称/父引用/属性标识，并导出 JSON 报告。结果始终标为部分观测；尚未实现目录索引和全卷一致性检查。支持筛选与取消，独立设置窗口使用 ⌘,。

分析结果仅在内存，不保存历史或私密路径日志。报告由用户主动导出，包含名称与元数据；只能以新文件名创建，不覆盖任何已有文件。源文件固定只读打开，拒绝设备、目录、链接和多硬链接文件。大于 16 MiB 的镜像不生成全文件摘要，并在报告中明确标出。

## 构建与定向测试

```sh
Scripts/test-core.sh
Scripts/test-export.sh
python3 -m unittest discover -s Tests -p 'test_install.py'
GAOCIPAN_SIGN_IDENTITY='已验证的签名身份' Scripts/build.sh
python3 Scripts/install.py
```

构建仅生成 `dist/GaoCiPan-1.00-macOS-arm64.zip` 等压缩发行文件。只有 `/Applications/搞磁盘.app` 长期保留为展开程序，避免启动台重复入口。安装脚本先核验包、备份已有本应用程序/资料/设置，再原子安装、逐文件摘要与签名核验；失败回滚程序。不会启动 App。

当前使用本机实际可用的 Apple Development 证书，未做 Developer ID 公证；不声明获得 FSKit 或系统扩展授权。版本源为 VERSION 和 BUILD，未来正式更新按十进制 +0.01 / build +1。

## 范围与证据

- [路线与许可](Docs/ResearchRoutes.md)：Apple、上游与厂商官方来源，检查日期 2026-10-18。
- [安全设计](Docs/SafetyDesign.md)：语义/拒写矩阵、状态机、模块边界和恢复设计。
- [原型报告](Docs/PrototypeReport.md)：实际编译、合成样本与定向测试。
- [下一阶段](Docs/NextStage.md)：独立授权后的空白介质、Windows 往返与故障验收计划，不作为自动执行指令。
- [交付记录](Docs/Delivery.md)：本机安装、版本、发行与验证边界。

按用户偏好没有执行冒烟测试；没有自动启动 App、浏览器、模拟器或测试窗口。真实 GUI、授权交互、Windows NTFS 实盘、热拔插、睡眠及 Intel 未验证。只读原型不能证明任何写入安全性。

## 数据与跨 App

私有资料预留路径是 `~/Library/Application Support/GaoSeries/GaoCiPan/`，长期安装备份为相邻 `GaoCiPan-Backups/`。V1 不创建业务数据库，不读取兄弟 App 私有资料，不处理钥匙串凭据。安装记录与既有资料备份不纳入源码或发行。

已只读核对搞操作的 GaoAction V1 模型/交接实现/文档及搞文件消费者；本版 `GaoCapabilities.json` 的 actions 为空，不新增磁盘动作，也不注册 `.gaoaction` 入口。

## 许可

本项目原创源码和图标构图采用 MIT。图标为透明外围、860×860 纯灰 #777777 圆角色块、白色竖排“磁盘”，以系统楷体轮廓渲染；不分发字体文件。未捆绑 NTFS-3G、macFUSE、商业 SDK 或第三方 NTFS 驱动代码。
