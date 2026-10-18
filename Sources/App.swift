import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class DiskModel: ObservableObject {
    @Published var report: NTFSReport?
    @Published var busy = false
    @Published var error: String?
    @Published var filter = ""
    @Published var section = DiskSection.analysis
    @Published var appearance = 0
    @Published var exportNotice = false
    @Published var selectedResearchDocument = "ResearchRoutes"
    private var cancellation: CancellationFlag?
    private var inspectedAt = Date()
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.00" }
    var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    var title: String { "搞磁盘 V\(version)" }
    var colorScheme: ColorScheme? { appearance == 1 ? .light : appearance == 2 ? .dark : nil }
    var entries: [NTFSFileEntry] {
        guard let report else { return [] }
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return report.files.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || String($0.recordNumber).contains(query) }
    }
    func chooseImage() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择普通 NTFS 原始镜像"
        panel.message = "仅支持文件系统从偏移 0 开始的原始镜像；不接受设备、链接、压缩 DMG 或分区整盘镜像。"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "只读分析"
        if panel.runModal() == .OK, let url = panel.url { analyze(url) }
    }
    func analyze(_ url: URL) {
        guard !busy else { return }
        guard url.isFileURL else { error = "请选择本机普通镜像文件。"; return }
        let flag = CancellationFlag()
        cancellation = flag; busy = true; error = nil; report = nil; filter = ""; section = .analysis
        let accessed = url.startAccessingSecurityScopedResource()
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<NTFSReport, Error> in
                Result { try NTFSAnalyzer.analyze(url: url, cancelled: { flag.isCancelled }) }
            }.value
            if accessed { url.stopAccessingSecurityScopedResource() }
            busy = false; cancellation = nil
            if flag.isCancelled { error = "分析已取消。源镜像保持只读。"; return }
            switch result {
            case .success(let value): report = value; inspectedAt = Date()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
    func cancel() { cancellation?.cancel() }
    func exportReport() {
        guard let report, !busy else { return }
        let panel = NSSavePanel()
        panel.title = "导出分析报告"
        panel.message = "报告包含镜像名称、记录名称和元数据。请选择新文件名；为保护源镜像，导出不会覆盖任何已有文件。"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "搞磁盘-分析报告.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            struct Export: Encodable {
                let schemaVersion = 1
                let appVersion: String
                let analyzedAt: Date
                let scope = "普通文件只读解析；不是完整 NTFS 一致性检查或写入安全证明"
                let report: NTFSReport
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
            let bytes = try encoder.encode(Export(appVersion: version, analyzedAt: inspectedAt, report: report))
            try SafeReportWriter.writeNew(data: bytes, to: url)
            exportNotice = true
        } catch { self.error = error.localizedDescription }
    }
}
struct UIError: LocalizedError { let message: String; init(_ value: String) { message = value }; var errorDescription: String? { message } }

enum DiskSection: String, CaseIterable, Identifiable {
    case analysis = "镜像分析", capabilities = "能力与边界", research = "研究资料"
    var id: String { rawValue }
    var icon: String { switch self { case .analysis: "externaldrive"; case .capabilities: "checkmark.shield"; case .research: "doc.text.magnifyingglass" } }
}

@main
struct GaoCiPanApp: App {
    @StateObject private var model = DiskModel()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model).preferredColorScheme(model.colorScheme)
                .frame(minWidth: 980, minHeight: 680)
                .background(WindowTitle(title: model.title))
                .onOpenURL { model.analyze($0) }
        }
        .defaultSize(width: 1160, height: 790)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("选择镜像…") { model.chooseImage() }.keyboardShortcut("o").disabled(model.busy)
                Button("导出分析报告…") { model.exportReport() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.report == nil || model.busy)
            }
            CommandGroup(replacing: .appInfo) {
                Button("关于搞磁盘") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "搞磁盘", .applicationVersion: "V\(model.version) / build \(model.build)", .credits: NSAttributedString(string: "原生 NTFS 只读镜像分析\n开发签名，未公证\n不包含真实磁盘写入、挂载或驱动")])
                }
            }
        }
        Settings { SettingsView().environmentObject(model).preferredColorScheme(model.colorScheme) }
    }
}

struct WindowTitle: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { DispatchQueue.main.async { view.window?.title = title } }
}

struct ContentView: View {
    @EnvironmentObject var model: DiskModel
    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                Section("工作空间") {
                    ForEach(DiskSection.allCases) { section in Label(section.rawValue, systemImage: section.icon).tag(section) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 175, ideal: 195, max: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("只读 · 无驱动", systemImage: "lock.shield").font(.callout.weight(.medium))
                    Text("镜像中的任何内容都不会被改写。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        } detail: {
            Group {
                switch model.section {
                case .analysis: AnalysisView()
                case .capabilities: CapabilityView()
                case .research: ResearchView()
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.busy { Button("取消", systemImage: "xmark.circle", action: model.cancel) }
                    Button("选择镜像", systemImage: "plus", action: model.chooseImage).disabled(model.busy).help("选择普通 NTFS 原始镜像（⌘O）")
                    Button("导出报告", systemImage: "square.and.arrow.up", action: model.exportReport).disabled(model.report == nil || model.busy)
                }
            }
        }
        .alert("分析提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("报告已导出并核验", isPresented: $model.exportNotice) { Button("好", role: .cancel) {} } message: { Text("输出仅包含分析报告；源镜像没有改动。") }
    }
}

struct AnalysisView: View {
    @EnvironmentObject var model: DiskModel
    var body: some View {
        if model.busy {
            VStack(spacing: 18) {
                ProgressView().controlSize(.large)
                Text("正在只读分析镜像").font(.title3.weight(.semibold))
                Text("核验普通文件、引导扇区和有界 MFT 记录。\n读取量有上限，并进行协作式超时检查。")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("取消分析", action: model.cancel)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let report = model.report {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        Image(systemName: "doc.zipper").font(.system(size: 30)).foregroundStyle(.secondary).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(report.imageName).font(.title2.weight(.semibold)).textSelection(.enabled).lineLimit(2)
                            Text(report.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 10)
                        Text("仅只读解析").font(.caption.weight(.semibold)).padding(.horizontal, 11).padding(.vertical, 7)
                            .background(Color.accentColor.opacity(0.10), in: Capsule())
                    }
                    HStack(spacing: 12) {
                        MetricCard(title: "识别格式", value: report.format, icon: "externaldrive")
                        MetricCard(title: "镜像大小", value: byteString(report.sourceBytes), icon: "internaldrive")
                        MetricCard(title: "累计读取", value: byteString(report.inspectedBytes), icon: "eye")
                        MetricCard(title: "记录名称", value: String(report.files.count), icon: "list.bullet.rectangle")
                    }
                    Label("结果为有界抽样，不代表完整目录、卷健康或可安全写入。", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(22)
                Divider()
                TabView {
                    FileRecordsView().tabItem { Label("记录", systemImage: "list.bullet") }
                    ReportDetailsView(report: report).tabItem { Label("探测结果", systemImage: "checklist") }
                }.padding(.top, 10)
            }
        } else {
            VStack(spacing: 18) {
                Image(systemName: "externaldrive.badge.magnifyingglass").font(.system(size: 65, weight: .light)).foregroundStyle(.secondary)
                Text("从一个镜像开始").font(.system(size: 27, weight: .semibold))
                Text("查看 NTFS 引导信息、MFT 记录和已识别特性。\n选择普通原始镜像，分析全程只读。")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(5)
                Button("选择镜像…", action: model.chooseImage).buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut("o")
                Text("支持 .img / .ntfs / .raw 等普通原始文件\n不支持压缩 DMG、分区整盘镜像或加密卷解锁")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 4)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

func byteString(_ count: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file) }
struct MetricCard: View {
    let title: String; let value: String; let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 21, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct FileRecordsView: View {
    @EnvironmentObject var model: DiskModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.entries.count) 项名称记录").font(.callout).foregroundStyle(.secondary)
                Spacer()
                TextField("筛选名称或记录号", text: $model.filter).textFieldStyle(.roundedBorder).frame(width: 230).accessibilityLabel("筛选 MFT 记录")
            }.padding(.horizontal, 22).padding(.vertical, 12)
            Table(model.entries) {
                TableColumn("名称") { entry in
                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc").textSelection(.enabled)
                }.width(min: 160, ideal: 230)
                TableColumn("MFT 记录") { Text(String($0.recordNumber)).monospacedDigit() }.width(min: 70, ideal: 90)
                TableColumn("父记录") { Text($0.parentRecordNumber.map(String.init) ?? "未知").monospacedDigit() }.width(min: 65, ideal: 80)
                TableColumn("特性") { Text($0.flags.map(featureName).joined(separator: " · ")).foregroundStyle(.secondary) }.width(min: 120, ideal: 240)
                TableColumn("数据流") { Text($0.streamNames.isEmpty ? "未观测" : $0.streamNames.joined(separator: ", ")).foregroundStyle(.secondary) }.width(min: 80, ideal: 120)
            }
            .overlay { if model.entries.isEmpty { Text("当前范围没有可显示的记录").foregroundStyle(.secondary) } }
            Text("仅列出有限 MFT 中的名称；不会遍历、打开或导出文件内容。父编号不等于已验证的完整路径。")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
    }
}

struct ReportDetailsView: View {
    let report: NTFSReport
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("读取与摘要范围") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(report.hashScope).foregroundStyle(.secondary)
                        if let digest = report.sourceSHA256 { Text(digest).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        Text("完整目录核验：未执行　　真实卷写能力：关闭").font(.callout)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("结构与特性观测") {
                    VStack(alignment: .leading, spacing: 13) {
                        ForEach(report.features) { observation in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(observation.feature).fontWeight(.medium); Spacer(); Text(stateName(observation.state)).font(.caption).foregroundStyle(.secondary) }
                                Text(observation.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            if observation.id != report.features.last?.id { Divider() }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if let geometry = report.geometry {
                    GroupBox("引导参数") {
                        VStack(spacing: 9) {
                            LabeledContent("每扇区字节", value: String(geometry.bytesPerSector))
                            LabeledContent("每簇扇区", value: String(geometry.sectorsPerCluster))
                            LabeledContent("簇大小", value: byteString(geometry.clusterBytes))
                            LabeledContent("声明卷大小", value: byteString(geometry.volumeBytes))
                            LabeledContent("MFT 起始簇", value: String(geometry.mftCluster))
                            LabeledContent("记录大小", value: byteString(UInt64(geometry.recordBytes)))
                            LabeledContent("声明 MFT 大小", value: byteString(geometry.declaredMFTBytes))
                            LabeledContent("已检查记录槽", value: "\(report.examinedRecordSlots) / 上限 \(report.recordSlotLimit)")
                        }.font(.callout).textSelection(.enabled).padding(8)
                    }
                }
                GroupBox("边界与警告") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in Label(warning, systemImage: "exclamationmark.triangle").fixedSize(horizontal: false, vertical: true) }
                        if report.warnings.isEmpty { Text("未发现额外可报告的问题；未验证的特性仍保持未知。") }
                    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }.padding(22)
        }
    }
}
func stateName(_ value: String) -> String {
    switch value {
    case "identified": "已发现标识"
    case "bounded": "有界只读"
    case "partial": "部分观测"
    case "notSetInObservedField": "所读字段未设置"
    default: "未知 / 未验证"
    }
}
func featureName(_ value: String) -> String {
    switch value {
    case "hardLinks": "硬链接"
    case "reparsePoint": "重解析点"
    case "compressed": "压缩"
    case "sparse": "稀疏"
    case "securityDescriptor": "安全描述符"
    case "standardInformation": "标准属性"
    case "directory": "目录"
    default: value
    }
}

struct CapabilityView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("清楚知道每一次分析的范围").font(.title2.weight(.semibold))
                Text("V1.00 提供普通原始镜像的有界只读分析。NTFS 是复杂的文件系统，单个结构可读不能证明卷一致性。")
                    .foregroundStyle(.secondary)
                GroupBox("当前可用") {
                    VStack(alignment: .leading, spacing: 14) {
                        FeatureRow(icon: "doc.viewfinder", title: "引导与记录观测", detail: "核验 NTFS 引导参数、有限 MFT 记录及已支持的属性结构。")
                        FeatureRow(icon: "lock", title: "只读文件入口", detail: "拒绝块设备、字符设备、目录和链接；所有写能力均关闭。")
                        FeatureRow(icon: "timer", title: "有界执行与取消", detail: "长度、偏移、计数和读取量受限；协作式超时检查，异常输入停止。宿主 I/O 阻塞可能延迟取消。")
                        FeatureRow(icon: "square.and.arrow.up", title: "明确导出", detail: "报告仅在内存，用户主动选择位置后才保存 JSON。")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                GroupBox("能力未启用") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("真实磁盘访问 · 挂载与卸载 · NTFS 写入 · 格式化与修复 · 驱动与系统扩展")
                        Text("BitLocker / EFS 解密、完整目录与内容导出、ACL 保真、日志恢复和写入安全认证均不支持。")
                            .foregroundStyle(.secondary)
                        Text("不会收集系统密码，也不会改变 SIP、启动安全、磁盘权限或系统文件系统设置。")
                            .foregroundStyle(.secondary)
                    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                Label("遇到解析错误请保留镜像与报告。解析失败不构成格式化或修复原盘的理由。", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 900, alignment: .leading)
        }
    }
}
struct FeatureRow: View {
    let icon: String; let title: String; let detail: String
    var body: some View { HStack(alignment: .top, spacing: 12) { Image(systemName: icon).frame(width: 22).foregroundStyle(Color.accentColor); VStack(alignment: .leading, spacing: 4) { Text(title).fontWeight(.medium); Text(detail).font(.callout).foregroundStyle(.secondary) } } }
}

struct ResearchView: View {
    @EnvironmentObject var model: DiskModel
    let documents = [("ResearchRoutes", "技术路线与许可"), ("SafetyDesign", "安全与恢复设计"), ("PrototypeReport", "原型验证报告"), ("NextStage", "后续设备验收计划")]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("NTFS 可行性研究").font(.title2.weight(.semibold))
                Text("检查日期：2026-10-18。文档支持、编译验证与真实设备验证分别记录。")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("研究文档", selection: $model.selectedResearchDocument) { ForEach(documents, id: \.0) { key, title in Text(title).tag(key) } }.pickerStyle(.segmented)
            }.padding(22)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(document).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    .lineSpacing(5).frame(minWidth: 680, maxWidth: .infinity, alignment: .leading).padding(24)
            }
        }
    }
    var document: String {
        guard let url = Bundle.main.url(forResource: model.selectedResearchDocument, withExtension: "md", subdirectory: "Docs"),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return "研究文档缺失，请检查安装包完整性。" }
        return value
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: DiskModel
    var body: some View {
        TabView {
            Form {
                LabeledContent("分析模式", value: "普通镜像 · 只读")
                Text("不打开真实块设备，不安装驱动，也不申请管理员权限。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("扫描采用固定安全预算；复杂、不支持或异常结构会停止或返回部分观测。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(26).tabItem { Label("业务功能", systemImage: "externaldrive") }
            Form {
                Picker("外观", selection: $model.appearance) { Text("跟随系统").tag(0); Text("浅色").tag(1); Text("深色").tag(2) }
                Text("外观选择仅用于当前会话，重新打开后跟随系统。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(26).tabItem { Label("外观", systemImage: "circle.lefthalf.filled") }
            Form {
                Text("分析结果只保存在内存中。关闭应用后不保留扫描历史。")
                Text("需要保存时使用“导出分析报告”。导出包含名称和元数据，不含文件正文。")
                Text("本版没有业务数据库、凭据或自动后台任务；不会覆盖预留私有资料目录内的已有内容。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(26).tabItem { Label("数据", systemImage: "externaldrive.badge.checkmark") }
            Form {
                LabeledContent("版本", value: "V\(model.version) / build \(model.build)")
                LabeledContent("开发方式", value: "SwiftUI + AppKit · Apple Silicon")
                LabeledContent("发行签名", value: "Apple Development · 未公证")
                Text("只读原型完成不代表 NTFS 读写产品完成。详细研究与设备验收计划见主窗口“研究资料”。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(26).tabItem { Label("关于", systemImage: "info.circle") }
        }.frame(width: 540, height: 280)
    }
}
