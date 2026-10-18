import Foundation
import Darwin
import CryptoKit

/// A deliberately bounded, read-only metadata examiner for ordinary NTFS image files.
/// It is not an NTFS driver, a directory index implementation, or a filesystem checker.
public struct NTFSGeometry: Codable, Sendable {
    public let bytesPerSector: UInt16
    public let sectorsPerCluster: UInt8
    public let clusterBytes: UInt64
    public let volumeBytes: UInt64
    public let mftCluster: UInt64
    public let recordBytes: UInt32
    public let declaredMFTBytes: UInt64
}

public struct NTFSNameLink: Codable, Sendable {
    public let name: String
    public let namespace: UInt8
    public let parentRecordNumber: UInt64
    public let parentSequence: UInt16
}

public struct NTFSFileEntry: Codable, Sendable, Identifiable {
    public let recordNumber: UInt64
    public let sequenceNumber: UInt16
    public var id: String { "\(recordNumber):\(sequenceNumber)" }
    public let parentRecordNumber: UInt64?
    public let name: String
    public let isDirectory: Bool
    public let hardLinkCount: UInt16
    public let streamNames: [String]
    public let flags: [String]
    public let nameLinks: [NTFSNameLink]
}

public struct NTFSFeatureObservation: Codable, Sendable, Identifiable {
    public let feature: String
    public let state: String
    public let detail: String
    public var id: String { feature }
}

public struct NTFSWriteCapabilities: Codable, Sendable {
    public let canWrite = false
    public let canMount = false
    public let canRepair = false
    public let canFormat = false
    public let writeSafetyValidated = false
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case canWrite, canMount, canRepair, canFormat, writeSafetyValidated
    }
    public init() {}
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        for key in CodingKeys.allCases {
            if try container.decode(Bool.self, forKey: key) {
                throw DecodingError.dataCorruptedError(forKey: key, in: container,
                    debugDescription: "只读报告不得声明写入、挂载、修复或格式化能力")
            }
        }
    }
}

public struct NTFSReport: Codable, Sendable {
    public let imageName: String
    public let format: String
    public let status: String
    public let summary: String
    public let sourceBytes: UInt64
    public let inspectedBytes: UInt64
    public let sourceSHA256: String?
    public let hashScope: String
    public let geometry: NTFSGeometry?
    public let files: [NTFSFileEntry]
    public let features: [NTFSFeatureObservation]
    public let warnings: [String]
    public let writeCapabilities: NTFSWriteCapabilities
    public let directoryInventoryComplete: Bool
    public let examinedRecordSlots: Int
    public let recordSlotLimit: Int
    public let sourceUnchanged: Bool
}

public enum NTFSAnalysisError: Error, LocalizedError, Sendable {
    case rejected(String)
    case malformed(String)
    case unsupported(String)
    case budget(String)
    case cancelled
    case changed
    case io(String)
    public var errorDescription: String? {
        switch self {
        case .rejected(let text): return "已拒绝输入：\(text)"
        case .malformed(let text): return "镜像结构异常：\(text)。未执行修复。"
        case .unsupported(let text): return "当前只读原型不支持：\(text)"
        case .budget(let text): return "达到安全预算：\(text)"
        case .cancelled: return "分析已取消；源文件未被写入。"
        case .changed: return "源文件在检查期间发生变化，结果已作废。"
        case .io(let text): return "读取失败：\(text)"
        }
    }
}

public enum NTFSAnalyzer {
    public static let maximumImageBytes: UInt64 = 1 << 40
    public static let maximumReadBytes: UInt64 = 64 << 20
    public static let maximumHashBytes: UInt64 = 16 << 20
    public static let maximumRecordSlots = 512
    public static let maximumOutputNameBytes: UInt64 = 1 << 20
    public static let maximumOutputNameLinks = 8192

    public static func analyze(url: URL,
        cancelled: @escaping @Sendable () -> Bool = { false }) throws -> NTFSReport {
        let source = try NTFSReadOnlyImage(url: url, cancelled: cancelled)
        do {
            let report = try inspect(source, name: url.lastPathComponent)
            try source.verifyUnchanged()
            return report
        } catch {
            try source.verifyUnchanged()
            throw error
        }
    }

    private static func inspect(_ source: NTFSReadOnlyImage, name: String) throws -> NTFSReport {
        let boot = try NTFSBytes(source.read(offset: 0, count: 512))
        let oem = try boot.slice(3, 8)
        let bitLocker = oem == Array("-FVE-FS-".utf8)
        guard bitLocker || oem == Array("NTFS    ".utf8) else {
            throw NTFSAnalysisError.unsupported("未发现 NTFS 或 BitLocker OEM 标识；只接收从引导扇区开始的普通卷镜像，不扫描分区表")
        }
        guard try boot.u16(510) == 0xAA55 else {
            throw NTFSAnalysisError.malformed("引导扇区结束签名无效")
        }
        var digest: String?
        if source.size <= maximumHashBytes { digest = try source.fullSHA256() }
        let hashScope = digest == nil
            ? "未计算源文件摘要：超过 16 MiB 全文件哈希预算；不得把检查范围当成全镜像哈希"
            : "完整普通源文件 SHA-256；不包含外部卷、宿主目录或附件"
        if bitLocker {
            return NTFSReport(imageName: name, format: "BitLocker", status: "unsupported",
                summary: "识别到 BitLocker 标识；已停止解析，不采集密码或解密。", sourceBytes: source.size,
                inspectedBytes: source.bytesRead, sourceSHA256: digest, hashScope: hashScope,
                geometry: nil, files: [], features: [NTFSFeatureObservation(feature: "BitLocker",
                    state: "identified", detail: "依据 OEM 标识，未验证加密元数据或完整性")],
                warnings: ["不具备解密、挂载、写入或修复能力。"], writeCapabilities: .init(),
                directoryInventoryComplete: false, examinedRecordSlots: 0,
                recordSlotLimit: maximumRecordSlots, sourceUnchanged: true)
        }
        let bps = try boot.u16(11)
        let spc = try boot.u8(13)
        guard [512, 1024, 2048, 4096].contains(bps), spc > 0, spc <= 128,
              spc & (spc - 1) == 0 else {
            throw NTFSAnalysisError.malformed("扇区或簇尺寸无效")
        }
        let clusterBytes = try ntfsMultiply(UInt64(bps), UInt64(spc))
        let sectors = try boot.u64(40)
        guard sectors > 0 else { throw NTFSAnalysisError.malformed("卷扇区计数为零") }
        let volumeBytes = try ntfsMultiply(sectors, UInt64(bps))
        guard volumeBytes <= source.size, volumeBytes >= 512, sectors % UInt64(spc) == 0 else {
            throw NTFSAnalysisError.malformed("声明卷尺寸超出源文件或簇边界")
        }
        let clusters = sectors / UInt64(spc)
        let mftCluster = try boot.u64(48)
        let mirrorCluster = try boot.u64(56)
        guard mftCluster > 0, mftCluster < clusters, mirrorCluster > 0,
              mirrorCluster < clusters else { throw NTFSAnalysisError.malformed("MFT 或镜像位置越界") }
        let recordBytes = try blockSize(try boot.u8(64), clusterBytes: clusterBytes)
        _ = try blockSize(try boot.u8(68), clusterBytes: clusterBytes)
        guard recordBytes >= UInt64(bps), recordBytes % UInt64(bps) == 0 else {
            throw NTFSAnalysisError.malformed("MFT 记录长度不符合扇区边界")
        }
        let mftOffset = try ntfsMultiply(mftCluster, clusterBytes)
        guard try ntfsAdd(mftOffset, recordBytes) <= volumeBytes else {
            throw NTFSAnalysisError.malformed("首个 MFT 记录越界")
        }
        let context = NTFSParseContext(bytesPerSector: Int(bps), clusterBytes: clusterBytes,
            volumeClusters: clusters, recordBytes: Int(recordBytes), checkBudget: { try source.checkBudget() })
        let first = try context.record(source.read(offset: mftOffset, count: Int(recordBytes)), expectedID: 0)
        guard first.inUse, let mft = first.unnamedData else {
            throw NTFSAnalysisError.unsupported("MFT 首记录没有可用的非驻留、未命名 DATA 属性")
        }
        guard mft.realBytes >= recordBytes, mft.initializedBytes >= recordBytes,
              mft.realBytes % recordBytes == 0, mft.initializedBytes % recordBytes == 0,
              mft.realBytes <= volumeBytes,
              let firstRun = mft.runs.first, firstRun.logicalCluster == 0,
              firstRun.physicalCluster == mftCluster else {
            throw NTFSAnalysisError.malformed("MFT 数据长度或首个数据运行与引导扇区不一致")
        }
        let initializedSlots = mft.initializedBytes / recordBytes
        let scannedSlots = Int(min(initializedSlots, UInt64(maximumRecordSlots)))
        var entries: [NTFSFileEntry] = []
        var seenIDs = Set<UInt64>()
        var volumeFlags: UInt16?
        var volumeVersion: String?
        var outputNameBytes: UInt64 = 0
        var outputNameLinks = 0
        var warnings = ["只检查有界 MFT 记录前缀；没有读取目录索引、位图、日志或全部文件内容。",
            "未证明文件系统一致性，也未证明任何写入、挂载、修复、恢复或完整目录能力。",
            "源文件前后身份、大小及时间戳一致仅是变化检查；不能证明不受恶意并发修改。",
            "10 秒是合作式执行预算，不是硬超时；网络或用户态文件系统的宿主读取仍可能阻塞。"]
        for index in 0..<scannedSlots {
            try source.checkBudget()
            let parsed: NTFSParsedRecord
            if index == 0 { parsed = first }
            else {
                let logicalOffset = try ntfsMultiply(UInt64(index), recordBytes)
                let data = try mft.read(source: source, offset: logicalOffset,
                    count: Int(recordBytes), clusterBytes: clusterBytes)
                if data.allSatisfy({ $0 == 0 }) { continue }
                parsed = try context.record(data, expectedID: UInt64(index))
            }
            guard parsed.inUse else { continue }
            guard seenIDs.insert(parsed.id).inserted else { throw NTFSAnalysisError.malformed("重复 MFT 标识") }
            let preferred = parsed.names.first(where: { $0.namespace == 1 || $0.namespace == 3 }) ?? parsed.names.first
            let displayName = preferred?.name ?? "（记录 \(parsed.id)，无已解析文件名）"
            outputNameBytes = try ntfsAdd(outputNameBytes, UInt64(displayName.utf8.count))
            for name in parsed.names { outputNameBytes = try ntfsAdd(outputNameBytes, UInt64(name.name.utf8.count)) }
            for stream in parsed.streamNames { outputNameBytes = try ntfsAdd(outputNameBytes, UInt64(stream.utf8.count)) }
            outputNameLinks += parsed.names.count
            // Include the repeated primary-name field. Separately cap link objects,
            // whose JSON keys could dominate even when their names are very short.
            guard outputNameBytes <= maximumOutputNameBytes else {
                throw NTFSAnalysisError.budget("报告名称与数据流 UTF-8 字段合计超过 1 MiB")
            }
            guard outputNameLinks <= maximumOutputNameLinks else {
                throw NTFSAnalysisError.budget("报告 FILE_NAME 引用超过 8192 项")
            }
            if let info = parsed.volumeInfo {
                guard parsed.id == 3, volumeFlags == nil else {
                    throw NTFSAnalysisError.malformed("卷信息出现在异常记录或重复出现")
                }
                volumeVersion = "\(info.major).\(info.minor)"
                volumeFlags = info.flags
                guard info.major == 3 && info.minor == 1 else {
                    throw NTFSAnalysisError.unsupported("NTFS 卷版本 \(volumeVersion ?? "未知")；原型只解释 3.1 记录布局")
                }
            }
            entries.append(NTFSFileEntry(recordNumber: parsed.id, sequenceNumber: parsed.sequence,
                parentRecordNumber: preferred?.parentRecordNumber, name: displayName,
                isDirectory: parsed.directory, hardLinkCount: parsed.linkCount,
                streamNames: parsed.streamNames, flags: parsed.features.sorted(), nameLinks: parsed.names))
        }
        try checkParents(entries, source: source)
        if UInt64(scannedSlots) < initializedSlots { warnings.append("MFT 已初始化记录超过 \(maximumRecordSlots) 个，只检查前 \(maximumRecordSlots) 个。") }
        if mft.initializedBytes < mft.realBytes { warnings.append("MFT 声明中有尚未初始化的范围，未读取该范围。") }
        let identified = Set(entries.flatMap(\.flags))
        func observation(_ title: String, flag: String, unknown: String) -> NTFSFeatureObservation {
            let found = identified.contains(flag)
            return NTFSFeatureObservation(feature: title, state: found ? "identified" : "unknown",
                detail: found ? "已在检查范围发现标识；未解释完整语义或验证保留能力" : unknown)
        }
        var features: [NTFSFeatureObservation] = [
            .init(feature: "只读访问", state: "bounded", detail: "固定只读文件描述符；不请求设备、挂载、修复或写入接口"),
            .init(feature: "完整目录", state: "unknown", detail: "只枚举 MFT 中的 FILE_NAME，未读取 INDEX_ROOT / INDEX_ALLOCATION，结果不是完整目录"),
            .init(feature: "卷脏标志", state: volumeFlags == nil ? "unknown" : ((volumeFlags! & 1) != 0 ? "identified" : "notSetInObservedField"),
                detail: volumeFlags.map { "VOLUME_INFORMATION 版本 \(volumeVersion ?? "未知")，flags=0x\(String($0, radix: 16))；未验证日志或一致性" } ?? "未在检查范围读取到卷信息"),
            observation("ADS", flag: "ADS", unknown: "检查范围未发现；不能排除其他记录或扩展属性中的 ADS"),
            observation("硬链接", flag: "hardLinks", unknown: "未证明所有硬链接及引用计数完整"),
            observation("重解析点 / 符号链接", flag: "reparsePoint", unknown: "未识别全部重解析点；不跟随重解析点"),
            observation("EFS", flag: "EFS", unknown: "检查范围未发现 EFS 标志；未检查全部安全或加密元数据"),
            observation("压缩文件", flag: "compressed", unknown: "检查范围未发现；不读取压缩数据"),
            observation("稀疏文件", flag: "sparse", unknown: "检查范围未发现；不读取稀疏数据"),
            observation("ACL / SID", flag: "securityDescriptor", unknown: "未解析 $Secure、安全描述符或 SID；不声明权限保留能力"),
            observation("STANDARD_INFORMATION", flag: "standardInformation", unknown: "检查范围未找到已解释的标准属性"),
            .init(feature: "休眠 / Fast Startup", state: "unknown", detail: "未检查 hiberfil.sys 内容，不能排除休眠或快速启动状态"),
            .init(feature: "卷日志 / 配额 / 坏簇", state: "unknown", detail: "未校验 $LogFile、$UsnJrnl、配额或 $BadClus"),
            .init(feature: "Unicode / 大小写", state: "partial", detail: "严格解码 UTF-16 文件名；不规范化、不导出路径，未实现 $UpCase / 名称冲突语义")
        ]
        if let flags = volumeFlags, flags & ~UInt16(0xC03F) != 0 {
            features.append(.init(feature: "未知卷功能位", state: "identified", detail: "存在未解释的卷标志；禁止将此报告作为写入资格证明"))
        }
        return NTFSReport(imageName: name, format: "NTFS", status: "partial",
            summary: "完成有界只读检查：\(scannedSlots) 个记录槽、\(entries.count) 个在用记录；目录与安全语义仍不完整。",
            sourceBytes: source.size, inspectedBytes: source.bytesRead, sourceSHA256: digest,
            hashScope: hashScope, geometry: .init(bytesPerSector: bps, sectorsPerCluster: spc,
                clusterBytes: clusterBytes, volumeBytes: volumeBytes, mftCluster: mftCluster,
                recordBytes: UInt32(recordBytes), declaredMFTBytes: mft.realBytes),
            files: entries, features: features, warnings: warnings, writeCapabilities: .init(),
            directoryInventoryComplete: false, examinedRecordSlots: scannedSlots,
            recordSlotLimit: maximumRecordSlots, sourceUnchanged: true)
    }

    private static func blockSize(_ raw: UInt8, clusterBytes: UInt64) throws -> UInt64 {
        let signed = Int(Int8(bitPattern: raw))
        let value: UInt64
        if signed < 0 {
            guard signed >= -16 && signed <= -9 else { throw NTFSAnalysisError.malformed("记录尺寸指数越界") }
            value = UInt64(1) << UInt64(-signed)
        } else {
            guard signed > 0 else { throw NTFSAnalysisError.malformed("记录尺寸为零") }
            value = try ntfsMultiply(UInt64(signed), clusterBytes)
        }
        guard value <= 65_536 else { throw NTFSAnalysisError.budget("单记录超过 64 KiB") }
        return value
    }

    private static func checkParents(_ entries: [NTFSFileEntry], source: NTFSReadOnlyImage) throws {
        let table = Dictionary(uniqueKeysWithValues: entries.map { ($0.recordNumber, $0) })
        var marks: [UInt64: UInt8] = [:]
        func visit(_ id: UInt64, depth: Int) throws {
            try source.checkBudget()
            guard depth <= 128 else { throw NTFSAnalysisError.budget("父引用深度超过 128") }
            if marks[id] == 2 { return }
            if marks[id] == 1 { throw NTFSAnalysisError.malformed("MFT 父引用存在循环") }
            marks[id] = 1
            if let entry = table[id] {
                for link in entry.nameLinks {
                    if id == 5 && link.parentRecordNumber == 5 { continue }
                    if let parent = table[link.parentRecordNumber] {
                        guard parent.isDirectory, parent.sequenceNumber == link.parentSequence else {
                            throw NTFSAnalysisError.malformed("父引用序列号或目录类型不一致")
                        }
                        try visit(parent.recordNumber, depth: depth + 1)
                    }
                }
            }
            marks[id] = 2
        }
        for entry in entries { try visit(entry.recordNumber, depth: 0) }
    }
}

private final class NTFSReadOnlyImage {
    private let fd: Int32
    private let original: stat
    private let cancelled: @Sendable () -> Bool
    private let deadline = ProcessInfo.processInfo.systemUptime + 10
    let size: UInt64
    private(set) var bytesRead: UInt64 = 0

    init(url: URL, cancelled: @escaping @Sendable () -> Bool) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw NTFSAnalysisError.rejected("需要本机普通镜像文件")
        }
        let path = url.path
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0) else { throw NTFSAnalysisError.rejected("无效路径或路径超过 4096 字节预算") }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, components.count <= 256, !components.contains("."), !components.contains("..") else {
            throw NTFSAnalysisError.rejected("不接受路径穿越或根目录")
        }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw NTFSAnalysisError.io("无法打开路径根目录") }
        defer { Darwin.close(directory) }
        for component in components.dropLast() {
            let next = component.withCString { Darwin.openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { throw NTFSAnalysisError.rejected("路径含符号链接、不可读目录或路径已变化") }
            Darwin.close(directory)
            directory = next
        }
        let leaf = components.last!
        var before = stat()
        guard leaf.withCString({ Darwin.fstatat(directory, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw NTFSAnalysisError.io("无法读取源文件身份")
        }
        try Self.checkRegular(before)
        let opened = leaf.withCString { Darwin.openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard opened >= 0 else { throw NTFSAnalysisError.rejected("无法以只读、拒绝链接的方式打开源文件") }
        var after = stat()
        guard Darwin.fstat(opened, &after) == 0 else {
            Darwin.close(opened)
            throw NTFSAnalysisError.io("无法核验固定文件描述符")
        }
        do {
            try Self.checkRegular(after)
            guard Self.same(before, after) else { throw NTFSAnalysisError.changed }
        } catch { Darwin.close(opened); throw error }
        fd = opened
        original = after
        size = UInt64(after.st_size)
        self.cancelled = cancelled
    }

    deinit { Darwin.close(fd) }

    private static func checkRegular(_ info: stat) throws {
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else {
            throw NTFSAnalysisError.rejected("只接受独立普通文件；拒绝目录、符号链接、硬链接和设备")
        }
        guard info.st_uid == geteuid() else { throw NTFSAnalysisError.rejected("源文件必须由当前用户拥有") }
        guard info.st_size >= 512 else { throw NTFSAnalysisError.malformed("源文件短于引导扇区") }
        guard UInt64(info.st_size) <= NTFSAnalyzer.maximumImageBytes else {
            throw NTFSAnalysisError.budget("镜像声明大小超过 1 TiB")
        }
    }

    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
        a.st_nlink == b.st_nlink && a.st_uid == b.st_uid && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    func verifyUnchanged() throws {
        var now = stat()
        guard Darwin.fstat(fd, &now) == 0 else { throw NTFSAnalysisError.io("无法完成源文件复核") }
        guard Self.same(original, now) else { throw NTFSAnalysisError.changed }
    }

    func checkBudget() throws {
        if cancelled() { throw NTFSAnalysisError.cancelled }
        guard ProcessInfo.processInfo.systemUptime <= deadline else { throw NTFSAnalysisError.budget("执行时间超过 10 秒") }
    }

    func read(offset: UInt64, count: Int) throws -> [UInt8] {
        try checkBudget()
        guard count >= 0, count <= 1 << 20, try ntfsAdd(offset, UInt64(count)) <= size else {
            throw NTFSAnalysisError.malformed("读取范围超出源文件或单次读取预算")
        }
        let updated = try ntfsAdd(bytesRead, UInt64(count))
        guard updated <= NTFSAnalyzer.maximumReadBytes else { throw NTFSAnalysisError.budget("累计读取超过 64 MiB") }
        bytesRead = updated
        var data = [UInt8](repeating: 0, count: count)
        var consumed = 0
        while consumed < count {
            try checkBudget()
            let actual = data.withUnsafeMutableBytes { buffer in
                Darwin.pread(fd, buffer.baseAddress!.advanced(by: consumed), count - consumed,
                    off_t(offset + UInt64(consumed)))
            }
            if actual < 0 && errno == EINTR { continue }
            guard actual > 0 else { throw NTFSAnalysisError.io("源文件读取中断、截断或宿主 I/O 错误") }
            consumed += actual
        }
        return data
    }

    func fullSHA256() throws -> String {
        guard size <= NTFSAnalyzer.maximumHashBytes else { throw NTFSAnalysisError.budget("全文件哈希超过 16 MiB") }
        var hasher = SHA256()
        var offset: UInt64 = 0
        while offset < size {
            let count = Int(min(UInt64(1 << 20), size - offset))
            hasher.update(data: Data(try read(offset: offset, count: count)))
            offset += UInt64(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct NTFSBytes {
    var raw: [UInt8]
    init(_ raw: [UInt8]) throws { self.raw = raw }
    func slice(_ start: Int, _ count: Int) throws -> [UInt8] {
        guard start >= 0, count >= 0, start <= raw.count, count <= raw.count - start else {
            throw NTFSAnalysisError.malformed("字段偏移或长度越界")
        }
        return Array(raw[start..<(start + count)])
    }
    func u8(_ p: Int) throws -> UInt8 { try slice(p, 1)[0] }
    func u16(_ p: Int) throws -> UInt16 { let b = try slice(p, 2); return UInt16(b[0]) | UInt16(b[1]) << 8 }
    func u32(_ p: Int) throws -> UInt32 {
        let b = try slice(p, 4); return b.enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) }
    }
    func u64(_ p: Int) throws -> UInt64 {
        let b = try slice(p, 8); return b.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
    func utf16(_ p: Int, count: Int) throws -> String {
        _ = try slice(p, count * 2)
        var values: [UInt16] = []
        for index in 0..<count { values.append(try u16(p + index * 2)) }
        var position = 0
        while position < values.count {
            let value = values[position]
            guard value != 0 else { throw NTFSAnalysisError.malformed("名称含空字符") }
            if (0xD800...0xDBFF).contains(value) {
                guard position + 1 < values.count, (0xDC00...0xDFFF).contains(values[position + 1]) else {
                    throw NTFSAnalysisError.malformed("名称包含未配对 UTF-16 代理项")
                }
                position += 2
            } else {
                guard !(0xDC00...0xDFFF).contains(value) else { throw NTFSAnalysisError.malformed("名称包含未配对 UTF-16 代理项") }
                position += 1
            }
        }
        return String(decoding: values, as: UTF16.self)
    }
}

private func ntfsAdd(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
    let result = a.addingReportingOverflow(b)
    guard !result.overflow else { throw NTFSAnalysisError.malformed("无符号偏移加法溢出") }
    return result.partialValue
}

private func ntfsMultiply(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
    let result = a.multipliedReportingOverflow(by: b)
    guard !result.overflow else { throw NTFSAnalysisError.malformed("声明尺寸乘法溢出") }
    return result.partialValue
}

private struct NTFSRun {
    let logicalCluster: UInt64
    let physicalCluster: UInt64
    let count: UInt64
}

private struct NTFSDataRuns {
    let runs: [NTFSRun]
    let realBytes: UInt64
    let initializedBytes: UInt64

    func read(source: NTFSReadOnlyImage, offset: UInt64, count: Int, clusterBytes: UInt64) throws -> [UInt8] {
        guard try ntfsAdd(offset, UInt64(count)) <= initializedBytes else {
            throw NTFSAnalysisError.malformed("MFT 逻辑读取越过初始化长度")
        }
        var result: [UInt8] = []
        var cursor = offset
        while result.count < count {
            try source.checkBudget()
            guard let run = try runs.first(where: {
                let start = try ntfsMultiply($0.logicalCluster, clusterBytes)
                let end = try ntfsAdd(start, ntfsMultiply($0.count, clusterBytes))
                return cursor >= start && cursor < end
            }) else { throw NTFSAnalysisError.malformed("MFT 逻辑范围没有对应运行") }
            let logicalStart = try ntfsMultiply(run.logicalCluster, clusterBytes)
            let runBytes = try ntfsMultiply(run.count, clusterBytes)
            let inside = cursor - logicalStart
            let length = Int(min(UInt64(count - result.count), runBytes - inside))
            let physical = try ntfsAdd(ntfsMultiply(run.physicalCluster, clusterBytes), inside)
            result.append(contentsOf: try source.read(offset: physical, count: length))
            cursor = try ntfsAdd(cursor, UInt64(length))
        }
        return result
    }
}

private struct NTFSParsedRecord {
    let id: UInt64
    let sequence: UInt16
    let inUse: Bool
    let directory: Bool
    let linkCount: UInt16
    let names: [NTFSNameLink]
    let streamNames: [String]
    let features: Set<String>
    let unnamedData: NTFSDataRuns?
    let volumeInfo: (major: UInt8, minor: UInt8, flags: UInt16)?
}

private struct NTFSParseContext {
    let bytesPerSector: Int
    let clusterBytes: UInt64
    let volumeClusters: UInt64
    let recordBytes: Int
    let checkBudget: () throws -> Void

    func record(_ raw: [UInt8], expectedID: UInt64) throws -> NTFSParsedRecord {
        try checkBudget()
        var bytes = try NTFSBytes(raw)
        guard raw.count == recordBytes, try bytes.slice(0, 4) == Array("FILE".utf8) else {
            throw NTFSAnalysisError.malformed("MFT FILE 签名或记录长度无效")
        }
        let usaOffset = Int(try bytes.u16(4))
        let usaCount = Int(try bytes.u16(6))
        let attrStart = Int(try bytes.u16(20))
        let inUse = try bytes.u16(22) & 1 != 0
        guard usaOffset >= 48, usaOffset % 2 == 0, usaCount == recordBytes / bytesPerSector + 1,
              usaOffset + usaCount * 2 <= recordBytes,
              !inUse || usaOffset + usaCount * 2 <= attrStart else {
            throw NTFSAnalysisError.malformed("MFT USA 数组边界或计数无效")
        }
        let usn = try bytes.u16(usaOffset)
        guard usn != 0 else { throw NTFSAnalysisError.malformed("MFT USA 序列字为零") }
        for sector in 1..<usaCount {
            let trailer = sector * bytesPerSector - 2
            guard try bytes.u16(trailer) == usn else { throw NTFSAnalysisError.malformed("MFT USA 扇区尾校验失败") }
            bytes.raw[trailer] = try bytes.u8(usaOffset + sector * 2)
            bytes.raw[trailer + 1] = try bytes.u8(usaOffset + sector * 2 + 1)
        }
        let used = Int(try bytes.u32(24))
        let allocated = Int(try bytes.u32(28))
        let flags = try bytes.u16(22)
        let id = UInt64(try bytes.u32(44))
        let sequence = try bytes.u16(16)
        let linkCount = try bytes.u16(18)
        guard allocated == recordBytes, used <= allocated, used >= 48,
              flags & ~UInt16(0x0003) == 0 else {
            throw NTFSAnalysisError.malformed("MFT 头部边界或标志无效")
        }
        // Unused records may have sequence 0 and stale attributes. Validate only
        // their FILE/USA/basic header, then skip; never interpret deleted content.
        if !inUse {
            return NTFSParsedRecord(id: expectedID, sequence: sequence, inUse: false,
                directory: false, linkCount: linkCount, names: [], streamNames: [],
                features: [], unnamedData: nil, volumeInfo: nil)
        }
        guard id == expectedID else { throw NTFSAnalysisError.malformed("MFT 记录标识重复或与物理记录槽不符") }
        guard used >= attrStart + 8, attrStart >= 48, attrStart % 8 == 0,
              sequence != 0 else { throw NTFSAnalysisError.malformed("MFT 头部边界、标志或序列号无效") }
        guard try bytes.u64(32) == 0 else { throw NTFSAnalysisError.unsupported("扩展 MFT 记录；不拼接基记录或 ATTRIBUTE_LIST") }
        var cursor = attrStart
        var attrIDs = Set<UInt16>()
        var names: [NTFSNameLink] = []
        var nameKeys = Set<String>()
        var streamNames: [String] = []
        var streamKeys = Set<String>()
        var features = Set<String>()
        var unnamedData: NTFSDataRuns?
        var volumeInfo: (major: UInt8, minor: UInt8, flags: UInt16)?
        var finished = false
        var hasStandardInformation = false
        if linkCount > 1 { features.insert("hardLinks") }
        for _ in 0..<256 {
            try checkBudget()
            guard cursor <= used - 4 else { throw NTFSAnalysisError.malformed("属性终止符越界") }
            let type = try bytes.u32(cursor)
            if type == 0xFFFFFFFF { finished = true; break }
            guard type >= 0x10, type <= 0x100, type % 0x10 == 0, cursor <= used - 24 else {
                throw NTFSAnalysisError.malformed("属性类型或头部范围无效")
            }
            let length = Int(try bytes.u32(cursor + 4))
            guard length >= 24, length % 8 == 0, length <= used - cursor else {
                throw NTFSAnalysisError.malformed("属性长度异常、溢出或未对齐")
            }
            let attr = try NTFSBytes(bytes.slice(cursor, length))
            let nonresident = try attr.u8(8)
            guard nonresident <= 1 else { throw NTFSAnalysisError.malformed("属性驻留标志无效") }
            let nameCount = Int(try attr.u8(9))
            let nameOffset = Int(try attr.u16(10))
            let attrFlags = try attr.u16(12)
            let attrID = try attr.u16(14)
            guard attrIDs.insert(attrID).inserted else { throw NTFSAnalysisError.malformed("属性 ID 重复") }
            guard attrFlags & ~UInt16(0xC001) == 0 else { throw NTFSAnalysisError.unsupported("未知属性标志") }
            let header = nonresident == 1 ? 64 : 24
            guard length >= header else { throw NTFSAnalysisError.malformed("属性头部截断") }
            if nameCount > 0 {
                guard nameOffset >= header, nameOffset % 2 == 0, nameCount * 2 <= length - nameOffset else {
                    throw NTFSAnalysisError.malformed("属性名称偏移无效")
                }
            }
            let attrName = nameCount == 0 ? "" : try attr.utf16(nameOffset, count: nameCount)
            if type == 0x20 { throw NTFSAnalysisError.unsupported("ATTRIBUTE_LIST，未实现跨记录属性拼接") }
            if attrFlags & 1 != 0 { features.insert("compressed") }
            if attrFlags & 0x4000 != 0 { features.insert("EFS") }
            if attrFlags & 0x8000 != 0 { features.insert("sparse") }
            if type == 0xC0 { features.insert("reparsePoint") }
            if type == 0x50 { features.insert("securityDescriptor") }
            if type == 0x80 {
                guard streamKeys.insert(attrName).inserted else { throw NTFSAnalysisError.malformed("DATA 流名称重复或出现多段未支持属性") }
                streamNames.append(attrName.isEmpty ? "（默认数据流）" : attrName)
                if !attrName.isEmpty { features.insert("ADS") }
            }
            if nonresident == 0 {
                guard attrFlags == 0 else { throw NTFSAnalysisError.unsupported("带压缩、稀疏或加密标志的驻留属性") }
                let valueLength = Int(try attr.u32(16))
                let valueOffset = Int(try attr.u16(20))
                guard valueOffset >= header, valueLength <= length - valueOffset,
                      nameCount == 0 || nameOffset + nameCount * 2 <= valueOffset else {
                    throw NTFSAnalysisError.malformed("驻留值偏移、长度或名称重叠异常")
                }
                let value = try NTFSBytes(attr.slice(valueOffset, valueLength))
                if type == 0x30 {
                    guard valueLength >= 66 else { throw NTFSAnalysisError.malformed("FILE_NAME 值截断") }
                    let count = Int(try value.u8(64))
                    let namespace = try value.u8(65)
                    guard count > 0, namespace <= 3, valueLength == 66 + count * 2 else {
                        throw NTFSAnalysisError.malformed("FILE_NAME 长度或命名空间无效")
                    }
                    let name = try value.utf16(66, count: count)
                    guard !name.contains("/"), !name.contains("\\"), name != ".." else {
                        throw NTFSAnalysisError.malformed("文件名含路径穿越字符")
                    }
                    let ref = try value.u64(0)
                    let parent = ref & 0x0000FFFFFFFFFFFF
                    let parentSequence = UInt16(ref >> 48)
                    guard parentSequence > 0 else { throw NTFSAnalysisError.malformed("文件名父引用序列号为零") }
                    let key = "\(parent):\(namespace):\(name)"
                    guard nameKeys.insert(key).inserted else { throw NTFSAnalysisError.malformed("FILE_NAME 引用重复") }
                    names.append(.init(name: name, namespace: namespace,
                        parentRecordNumber: parent, parentSequence: parentSequence))
                    try identifyFileFlags(value.u32(56), features: &features)
                } else if type == 0x10 {
                    guard !hasStandardInformation else { throw NTFSAnalysisError.malformed("STANDARD_INFORMATION 属性重复") }
                    hasStandardInformation = true
                    guard [48, 72].contains(valueLength) else { throw NTFSAnalysisError.unsupported("未知 STANDARD_INFORMATION 长度") }
                    features.insert("standardInformation")
                    try identifyFileFlags(value.u32(32), features: &features)
                } else if type == 0x70 {
                    guard valueLength == 12, volumeInfo == nil else { throw NTFSAnalysisError.malformed("VOLUME_INFORMATION 长度或重复值异常") }
                    volumeInfo = (try value.u8(8), try value.u8(9), try value.u16(10))
                }
            } else {
                guard type != 0x10, type != 0x30, type != 0x70 else {
                    throw NTFSAnalysisError.unsupported("非驻留的关键元数据属性")
                }
                guard attrFlags == 0 else {
                    throw NTFSAnalysisError.unsupported("压缩、稀疏或加密非驻留属性；已拒绝读取对应运行")
                }
                let data = try parseRuns(attr, nameCount: nameCount, nameOffset: nameOffset)
                if type == 0x80 && attrName.isEmpty { unnamedData = data }
            }
            cursor += length
        }
        guard finished else { throw NTFSAnalysisError.budget("单记录属性超过 256 个或缺少终止符") }
        return NTFSParsedRecord(id: id, sequence: sequence, inUse: flags & 1 != 0,
            directory: flags & 2 != 0, linkCount: linkCount, names: names,
            streamNames: streamNames, features: features, unnamedData: unnamedData, volumeInfo: volumeInfo)
    }

    private func identifyFileFlags(_ flags: UInt32, features: inout Set<String>) {
        if flags & 0x200 != 0 { features.insert("sparse") }
        if flags & 0x400 != 0 { features.insert("reparsePoint") }
        if flags & 0x800 != 0 { features.insert("compressed") }
        if flags & 0x4000 != 0 { features.insert("EFS") }
    }

    private func parseRuns(_ bytes: NTFSBytes, nameCount: Int, nameOffset: Int) throws -> NTFSDataRuns {
        let lowVCN = try bytes.u64(16)
        let highVCN = try bytes.u64(24)
        let runOffset = Int(try bytes.u16(32))
        let compressionUnit = try bytes.u16(34)
        let allocated = try bytes.u64(40)
        let real = try bytes.u64(48)
        let initialized = try bytes.u64(56)
        guard lowVCN == 0 else { throw NTFSAnalysisError.unsupported("非首段属性运行") }
        guard highVCN < volumeClusters, runOffset >= 64, runOffset < bytes.raw.count,
              nameCount == 0 || nameOffset + nameCount * 2 <= runOffset,
              compressionUnit == 0, initialized <= real, real <= allocated,
              allocated % clusterBytes == 0 else {
            throw NTFSAnalysisError.malformed("非驻留属性范围、压缩单元或长度无效")
        }
        var cursor = runOffset
        var logical: UInt64 = 0
        var physical: Int64 = 0
        var runs: [NTFSRun] = []
        var finished = false
        for _ in 0..<128 {
            try checkBudget()
            let marker = try bytes.u8(cursor)
            cursor += 1
            if marker == 0 { finished = true; break }
            let countBytes = Int(marker & 0xF)
            let offsetBytes = Int(marker >> 4)
            guard (1...8).contains(countBytes), (1...8).contains(offsetBytes) else {
                throw NTFSAnalysisError.unsupported("稀疏运行或非法 runlist 字段宽度")
            }
            let countRaw = try bytes.slice(cursor, countBytes)
            let offsetRaw = try bytes.slice(cursor + countBytes, offsetBytes)
            cursor += countBytes + offsetBytes
            let count = countRaw.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
            var unsigned = offsetRaw.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
            if offsetBytes < 8 && offsetRaw.last! & 0x80 != 0 { unsigned |= UInt64.max << (offsetBytes * 8) }
            let delta = Int64(bitPattern: unsigned)
            let sum = physical.addingReportingOverflow(delta)
            guard count > 0, !sum.overflow, sum.partialValue >= 0 else {
                throw NTFSAnalysisError.malformed("runlist 零长度、负地址或有符号偏移溢出")
            }
            physical = sum.partialValue
            let end = try ntfsAdd(UInt64(physical), count)
            let nextLogical = try ntfsAdd(logical, count)
            guard end <= volumeClusters, nextLogical <= highVCN + 1 else {
                throw NTFSAnalysisError.malformed("runlist 超出卷或 VCN 范围")
            }
            for prior in runs {
                let priorEnd = try ntfsAdd(prior.physicalCluster, prior.count)
                guard end <= prior.physicalCluster || UInt64(physical) >= priorEnd else {
                    throw NTFSAnalysisError.malformed("runlist 物理范围重复或形成回指重叠")
                }
            }
            runs.append(.init(logicalCluster: logical, physicalCluster: UInt64(physical), count: count))
            logical = nextLogical
        }
        guard finished, !runs.isEmpty, logical == highVCN + 1,
              try ntfsMultiply(logical, clusterBytes) == allocated else {
            throw NTFSAnalysisError.malformed("runlist 未终止、VCN 不连续或分配长度不匹配")
        }
        return NTFSDataRuns(runs: runs, realBytes: real, initializedBytes: initialized)
    }
}
