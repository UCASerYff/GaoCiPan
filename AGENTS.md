# 搞磁盘

- 原生 SwiftUI + AppKit，GaoCiPan，com.gaoseries.GaoCiPan，V1.00 / build 1，Apple Silicon / macOS 14+。
- 用户于 2026-10-18 明确授权制作并安装 App，覆盖研究文档的「不创建 App/不安装」限制；真实介质写入、驱动、挂载、修复仍不在授权功能内。
- 唯一业务为有界只读解析普通 NTFS 镜像文件。固定 O_RDONLY FD，拒绝设备、链接和超预算内容；不包含挂载、格式化、修复、后台服务或高权限组件。
- 全部源码/文档/原创图标/隔离测试/最新版压缩发行包在本目录；只保留 /Applications/搞磁盘.app 一个展开程序。
- VERSION / BUILD 是版本来源；首次 1.00 / 1。未来正式更新 +0.01 / +1。
- Scripts/build.sh 构建并本地开发签名，Scripts/test-core.sh 为隔离定向测试，Scripts/install.py 不启动应用。默认不跑冒烟测试，不启动 App/浏览器/模拟器。
- 签名前通过 security find-identity 实际核实证书；Apple Development 不是 Developer ID 公证。可设置 GAOCIPAN_SIGN_IDENTITY；不可新增系统权限。
- 私有资料预留 ~/Library/Application Support/GaoSeries/GaoCiPan，长期备份相邻 GaoCiPan-Backups。V1 不创建业务库或保存扫描历史，报告和外观选择仅在内存；报告由用户明确导出。不读兄弟应用私有数据库，不采集钥匙串凭据。
- 安装前探测已有程序、私有根、容器与偏好，存在内容须备份并逐文件摘要核验；不可读或异常对象停止。无需迁移时不变更原资料。
- GaoAction V1 不新增磁盘动作，actions 为空；未声明接收 .gaoaction。真实卷和 GUI 未验证，报告不得称 NTFS 读写产品已完成。
- GitHub 只发布程序、源码、许可、报告与摘要；不含私有资料、备份、凭据或本机路径清单。精确登记本 Bundle，不全局重置。
