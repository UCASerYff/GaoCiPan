import Foundation
import Darwin
import CryptoKit

// Original, deliberately minimal synthetic bytes. This is not a Windows-formatted
// filesystem and must never be mounted or described as one. No third-party image
// or Windows files are included. It exercises the parser's chosen structures only.
enum SyntheticNTFS {
    static let sourceNote = "原创最小合成结构；不构成完整 Windows 格式化卷；禁止挂载或写入真实设备"
    static let mftOffset = 4 * 512
    static let recordBytes = 1024

    static func put<T: FixedWidthInteger>(_ value: T, at offset: Int, into bytes: inout [UInt8]) {
        for index in 0..<MemoryLayout<T>.size { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    static func text(_ value: String) -> [UInt8] {
        value.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
    }
    static func resident(type: UInt32, id: UInt16, value: [UInt8], name: String = "") -> [UInt8] {
        let nameBytes = text(name)
        let valueOffset = (24 + nameBytes.count + 7) & ~7
        let length = (valueOffset + value.count + 7) & ~7
        var attr = [UInt8](repeating: 0, count: length)
        put(type, at: 0, into: &attr)
        put(UInt32(length), at: 4, into: &attr)
        attr[9] = UInt8(nameBytes.count / 2)
        put(UInt16(24), at: 10, into: &attr)
        put(id, at: 14, into: &attr)
        put(UInt32(value.count), at: 16, into: &attr)
        put(UInt16(valueOffset), at: 20, into: &attr)
        attr.replaceSubrange(24..<(24 + nameBytes.count), with: nameBytes)
        attr.replaceSubrange(valueOffset..<(valueOffset + value.count), with: value)
        return attr
    }
    static func standard(id: UInt16 = 0, flags: UInt32 = 0) -> [UInt8] {
        var value = [UInt8](repeating: 0, count: 72)
        put(flags, at: 32, into: &value)
        return resident(type: 0x10, id: id, value: value)
    }
    static func filename(_ name: String, id: UInt16 = 1, parent: UInt64 = 5,
        flags: UInt32 = 0, namespace: UInt8 = 1) -> [UInt8] {
        let nameBytes = text(name)
        var value = [UInt8](repeating: 0, count: 66 + nameBytes.count)
        put(parent | (UInt64(1) << 48), at: 0, into: &value)
        put(flags, at: 56, into: &value)
        value[64] = UInt8(nameBytes.count / 2)
        value[65] = namespace
        value.replaceSubrange(66..<value.count, with: nameBytes)
        return resident(type: 0x30, id: id, value: value)
    }
    static func mftData(runlist: [UInt8] = [0x11, 16, 4, 0]) -> [UInt8] {
        var attr = [UInt8](repeating: 0, count: 88)
        put(UInt32(0x80), at: 0, into: &attr)
        put(UInt32(attr.count), at: 4, into: &attr)
        attr[8] = 1
        put(UInt16(2), at: 14, into: &attr)
        put(UInt64(15), at: 24, into: &attr)
        put(UInt16(64), at: 32, into: &attr)
        put(UInt64(8192), at: 40, into: &attr)
        put(UInt64(8192), at: 48, into: &attr)
        put(UInt64(8192), at: 56, into: &attr)
        attr.replaceSubrange(64..<(64 + runlist.count), with: runlist)
        return attr
    }
    static func record(_ id: UInt32, directory: Bool = false, links: UInt16 = 1,
        attrs: [[UInt8]], recordSize: Int = recordBytes) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: recordSize)
        let usaCount = recordSize / 512 + 1
        let attrStart = (48 + usaCount * 2 + 7) & ~7
        result.replaceSubrange(0..<4, with: Array("FILE".utf8))
        put(UInt16(48), at: 4, into: &result)
        put(UInt16(usaCount), at: 6, into: &result)
        put(UInt16(1), at: 16, into: &result)
        put(links, at: 18, into: &result)
        put(UInt16(attrStart), at: 20, into: &result)
        put(UInt16(directory ? 3 : 1), at: 22, into: &result)
        put(UInt32(recordSize), at: 28, into: &result)
        put(id, at: 44, into: &result)
        var position = attrStart
        for attr in attrs {
            precondition(position + attr.count + 8 < recordSize)
            result.replaceSubrange(position..<(position + attr.count), with: attr)
            position += attr.count
        }
        put(UInt32(0xFFFFFFFF), at: position, into: &result)
        put(UInt32(position + 8), at: 24, into: &result)
        put(UInt16(0xA55A), at: 48, into: &result)
        for sector in 1..<usaCount {
            let trailer = sector * 512 - 2
            result[48 + sector * 2] = result[trailer]
            result[49 + sector * 2] = result[trailer + 1]
            put(UInt16(0xA55A), at: trailer, into: &result)
        }
        return result
    }
    static func make(mftRuns: [UInt8] = [0x11, 16, 4, 0]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 128 * 512)
        result[0] = 0xEB; result[1] = 0x52; result[2] = 0x90
        result.replaceSubrange(3..<11, with: Array("NTFS    ".utf8))
        put(UInt16(512), at: 11, into: &result)
        result[13] = 1
        put(UInt64(128), at: 40, into: &result)
        put(UInt64(4), at: 48, into: &result)
        put(UInt64(24), at: 56, into: &result)
        result[64] = 0xF6; result[68] = 0xF4
        put(UInt16(0xAA55), at: 510, into: &result)
        func place(_ id: Int, _ record: [UInt8]) {
            let position = mftOffset + id * recordBytes
            result.replaceSubrange(position..<(position + recordBytes), with: record)
        }
        place(0, record(0, attrs: [standard(), filename("$MFT"), mftData(runlist: mftRuns)]))
        var volume = [UInt8](repeating: 0, count: 12)
        volume[8] = 3; volume[9] = 1
        place(3, record(3, attrs: [standard(), filename("$Volume"), resident(type: 0x70, id: 2, value: volume)]))
        place(5, record(5, directory: true, attrs: [standard(), filename(".")]))
        place(6, record(6, links: 2, attrs: [standard(), filename("示例.txt"),
            filename("另一个名称.txt", id: 2, parent: 7),
            resident(type: 0x80, id: 3, value: Array("example".utf8)),
            resident(type: 0x80, id: 4, value: Array("audit".utf8), name: "审计")]))
        place(7, record(7, directory: true, attrs: [standard(), filename("研究")]))
        return result
    }
    static func replaceRecord(_ id: Int, with record: [UInt8], in image: inout [UInt8]) {
        let position = mftOffset + id * recordBytes
        image.replaceSubrange(position..<(position + recordBytes), with: record)
    }
    static func larger(recordSize: Int, slots: Int, manyNames: Bool) -> [UInt8] {
        var image = [UInt8](repeating: 0, count: 2 << 20)
        image.replaceSubrange(0..<512, with: make()[0..<512])
        put(UInt64(image.count / 512), at: 40, into: &image)
        image[64] = UInt8(bitPattern: Int8(-Int(log2(Double(recordSize)))))
        let mftBytes = UInt64(recordSize * slots)
        let clusterCount = mftBytes / 512
        var data = mftData(runlist: [0x12, UInt8(truncatingIfNeeded: clusterCount),
            UInt8(truncatingIfNeeded: clusterCount >> 8), 4, 0])
        put(clusterCount - 1, at: 24, into: &data)
        put(mftBytes, at: 40, into: &data)
        put(mftBytes, at: 48, into: &data)
        put(mftBytes, at: 56, into: &data)
        func place(_ id: Int, attrs: [[UInt8]], directory: Bool = false, links: UInt16 = 1) {
            let bytes = record(UInt32(id), directory: directory, links: links, attrs: attrs, recordSize: recordSize)
            let start = mftOffset + id * recordSize
            image.replaceSubrange(start..<(start + recordSize), with: bytes)
        }
        place(0, attrs: [standard(), filename("$MFT"), data])
        place(5, attrs: [standard(), filename(".")], directory: true)
        if manyNames {
            for id in 6..<slots {
                var attrs = [standard()]
                for link in 0..<13 {
                    let name = String(repeating: "研", count: 252) + String(format: "%03d", link)
                    attrs.append(filename(name, id: UInt16(link + 1)))
                }
                place(id, attrs: attrs, links: 13)
            }
        }
        return image
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

final class MutationOnce: @unchecked Sendable {
    let lock = NSLock()
    var didMutate = false
    let url: URL
    init(_ url: URL) { self.url = url }
    func callback() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !didMutate {
            didMutate = true
            // Deliberately mutate only this disposable test file, never a user file.
            if let handle = try? FileHandle(forWritingTo: url) {
                try? handle.seek(toOffset: 600)
                try? handle.write(contentsOf: Data([0x7F]))
                try? handle.close()
            }
        }
        return false
    }
}

@main
struct NTFSCoreTests {
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp/GaoCiPanCoreTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: base) }
        let original = SyntheticNTFS.make()
        var checks = 0
        func expect(_ value: Bool, _ message: String) throws {
            guard value else { throw TestFailure(description: message) }
            checks += 1
        }
        func hash(_ url: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        func write(_ bytes: [UInt8], _ name: String) throws -> URL {
            let url = base.appendingPathComponent(name)
            try Data(bytes).write(to: url, options: .atomic)
            return url
        }
        func rejected(_ name: String, _ bytes: [UInt8], contains: String? = nil) throws {
            let url = try write(bytes, name + ".img")
            let before = try hash(url)
            var failure: Error?
            do { _ = try NTFSAnalyzer.analyze(url: url) }
            catch { failure = error }
            try expect(failure != nil, "\(name): 应拒绝畸形输入")
            if let contains {
                try expect(failure?.localizedDescription.contains(contains) == true,
                    "\(name): 错误不匹配：\(failure?.localizedDescription ?? "nil")")
            }
            try expect(try hash(url) == before, "\(name): 源文件被改变")
        }
        let valid = try write(original, "original-synthetic.img")
        let beforeHash = try hash(valid)
        let report = try NTFSAnalyzer.analyze(url: valid)
        try expect(report.format == "NTFS" && report.status == "partial", "报告必须标为 NTFS / partial")
        try expect(report.files.count == 5 && report.examinedRecordSlots == 8, "有界枚举记录不匹配")
        try expect(report.geometry?.recordBytes == 1024 && report.geometry?.clusterBytes == 512, "几何信息错误")
        try expect(report.sourceSHA256 == beforeHash && report.sourceUnchanged, "完整小样本 hash 错误")
        try expect(report.inspectedBytes <= NTFSAnalyzer.maximumReadBytes, "超过读取预算")
        try expect(!report.directoryInventoryComplete && !report.writeCapabilities.canWrite &&
            !report.writeCapabilities.canMount && !report.writeCapabilities.canRepair &&
            !report.writeCapabilities.canFormat && !report.writeCapabilities.writeSafetyValidated, "只读能力边界错误")
        let file = report.files.first(where: { $0.recordNumber == 6 })
        try expect(file?.name == "示例.txt" && file?.hardLinkCount == 2 && file?.nameLinks.count == 2,
            "FILE_NAME / 硬链接解析错误")
        try expect(file?.streamNames.contains("审计") == true && file?.flags.contains("ADS") == true,
            "ADS 标识缺失")
        try expect(report.features.contains(where: { $0.feature == "卷脏标志" && $0.state == "notSetInObservedField" }),
            "VOLUME_INFORMATION 未识别")
        let json = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(NTFSReport.self, from: json)
        try expect(decoded.files.count == report.files.count, "报告 Codable 往返失败")
        var forged = String(decoding: json, as: UTF8.self)
        forged = forged.replacingOccurrences(of: "\"canWrite\":false", with: "\"canWrite\":true")
        var forgeRejected = false
        do { _ = try JSONDecoder().decode(NTFSReport.self, from: Data(forged.utf8)) } catch { forgeRejected = true }
        try expect(forgeRejected, "报告反序列化接受了伪造写能力")
        try expect(try hash(valid) == beforeHash, "合法分析改写源文件")
        try expect(report.warnings.contains(where: { $0.contains("不是硬超时") }), "不得承诺宿主读取硬超时")

        var unusedImage = original
        var unused = SyntheticNTFS.record(1, attrs: [])
        SyntheticNTFS.put(UInt16(0), at: 16, into: &unused)
        SyntheticNTFS.put(UInt16(0), at: 20, into: &unused)
        SyntheticNTFS.put(UInt16(0), at: 22, into: &unused)
        SyntheticNTFS.replaceRecord(1, with: unused, in: &unusedImage)
        let unusedURL = try write(unusedImage, "unused-sequence-zero.img")
        let unusedHash = try hash(unusedURL)
        let unusedReport = try NTFSAnalyzer.analyze(url: unusedURL)
        try expect(unusedReport.files.count == 5, "未用记录序列号零应跳过而不是报损坏")
        try expect(try hash(unusedURL) == unusedHash, "未用槽测试改变源文件")
        let slotsURL = try write(SyntheticNTFS.larger(recordSize: 1024, slots: 513, manyNames: false), "record-slot-budget.img")
        let slotsHash = try hash(slotsURL)
        let slotsReport = try NTFSAnalyzer.analyze(url: slotsURL)
        try expect(slotsReport.examinedRecordSlots == 512 && slotsReport.status == "partial" &&
            slotsReport.warnings.contains(where: { $0.contains("只检查前 512") }), "记录槽预算未明确截断为 partial")
        try expect(try hash(slotsURL) == slotsHash, "记录槽预算测试改变源文件")
        try rejected("metadata-output-budget", SyntheticNTFS.larger(recordSize: 8192, slots: 128, manyNames: true), contains: "1 MiB")

        try rejected("truncated-boot", Array(original.prefix(511)))
        try rejected("truncated-mft", Array(original.prefix(2500)))
        var bad = original
        bad[510] = 0
        try rejected("bad-boot-signature", bad, contains: "签名")
        bad = original
        bad[SyntheticNTFS.mftOffset] = 0
        try rejected("bad-file-signature", bad, contains: "FILE")
        bad = original
        bad[SyntheticNTFS.mftOffset + 510] = 0
        try rejected("bad-usa-fixup", bad, contains: "USA")
        bad = original
        SyntheticNTFS.put(UInt16(0xFFFF), at: SyntheticNTFS.mftOffset + 4, into: &bad)
        try rejected("usa-offset-overflow", bad, contains: "USA")
        bad = original
        SyntheticNTFS.put(UInt64.max, at: 40, into: &bad)
        try rejected("volume-size-overflow", bad, contains: "溢出")
        bad = original
        SyntheticNTFS.put(UInt64.max, at: 48, into: &bad)
        try rejected("mft-offset-overflow", bad)
        bad = original
        bad[64] = 0x80
        try rejected("oversized-record-exponent", bad)
        bad = original
        SyntheticNTFS.put(UInt32.max, at: SyntheticNTFS.mftOffset + 24, into: &bad)
        try rejected("abnormal-record-length", bad, contains: "头部")
        bad = original
        SyntheticNTFS.put(UInt32.max, at: SyntheticNTFS.mftOffset + 60, into: &bad)
        try rejected("oversized-attribute", bad, contains: "属性长度")
        bad = original
        SyntheticNTFS.put(UInt32(5), at: SyntheticNTFS.mftOffset + 6 * 1024 + 44, into: &bad)
        try rejected("duplicate-record-id", bad, contains: "标识")
        bad = SyntheticNTFS.make(mftRuns: [0x11, 8, 4, 0x11, 8, 0, 0])
        try rejected("runlist-backreference-overlap", bad, contains: "回指")
        bad = SyntheticNTFS.make(mftRuns: [0x11, 0, 4, 0])
        try rejected("zero-run-length", bad)
        bad = SyntheticNTFS.make(mftRuns: [0x01, 16, 0])
        try rejected("sparse-run", bad, contains: "稀疏")
        bad = SyntheticNTFS.make(mftRuns: [0x88] + [UInt8](repeating: 0xFF, count: 16) + [0])
        try rejected("oversized-run-fields", bad)
        bad = original
        SyntheticNTFS.replaceRecord(5, with: SyntheticNTFS.record(5, directory: true,
            attrs: [SyntheticNTFS.standard(), SyntheticNTFS.filename(".", parent: 7)]), in: &bad)
        try rejected("parent-cycle", bad, contains: "循环")
        bad = original
        var wrongSequence = SyntheticNTFS.filename("失效父引用", parent: 5)
        SyntheticNTFS.put(UInt64(5) | (UInt64(9) << 48), at: 24, into: &wrongSequence)
        SyntheticNTFS.replaceRecord(6, with: SyntheticNTFS.record(6,
            attrs: [SyntheticNTFS.standard(), wrongSequence]), in: &bad)
        try rejected("parent-sequence-mismatch", bad, contains: "父引用")
        bad = original
        SyntheticNTFS.replaceRecord(6, with: SyntheticNTFS.record(6, attrs: [SyntheticNTFS.standard(),
            SyntheticNTFS.filename("重复", id: 1), SyntheticNTFS.filename("重复", id: 2)]), in: &bad)
        try rejected("duplicate-file-name-reference", bad, contains: "重复")
        bad = original
        SyntheticNTFS.replaceRecord(6, with: SyntheticNTFS.record(6, attrs: [SyntheticNTFS.standard(),
            SyntheticNTFS.filename("../路径")]), in: &bad)
        try rejected("path-traversal-name", bad, contains: "路径")
        bad = original
        var invalidUTF16 = SyntheticNTFS.filename("名称")
        SyntheticNTFS.put(UInt16(0xD800), at: 24 + 66 + 2, into: &invalidUTF16)
        SyntheticNTFS.replaceRecord(6, with: SyntheticNTFS.record(6,
            attrs: [SyntheticNTFS.standard(), invalidUTF16]), in: &bad)
        try rejected("unpaired-utf16", bad, contains: "UTF-16")
        bad = original
        SyntheticNTFS.replaceRecord(6, with: SyntheticNTFS.record(6, attrs: [SyntheticNTFS.standard(),
            SyntheticNTFS.resident(type: 0x20, id: 1, value: [])]), in: &bad)
        try rejected("attribute-list-unsupported", bad, contains: "ATTRIBUTE_LIST")
        bad = original
        var compressedData = SyntheticNTFS.mftData()
        SyntheticNTFS.put(UInt16(1), at: 12, into: &compressedData)
        SyntheticNTFS.replaceRecord(0, with: SyntheticNTFS.record(0,
            attrs: [SyntheticNTFS.standard(), SyntheticNTFS.filename("$MFT"), compressedData]), in: &bad)
        try rejected("compressed-mft-rejected", bad, contains: "压缩")
        bad = original
        let vol = [UInt8](repeating: 0, count: 8) + [3, 0, 0, 0]
        SyntheticNTFS.replaceRecord(3, with: SyntheticNTFS.record(3, attrs: [SyntheticNTFS.standard(),
            SyntheticNTFS.filename("$Volume"), SyntheticNTFS.resident(type: 0x70, id: 2, value: vol)]), in: &bad)
        try rejected("unsupported-volume-version", bad, contains: "版本")
        bad = original
        bad.replaceSubrange(3..<11, with: Array("-FVE-FS-".utf8))
        let locked = try write(bad, "bitlocker-marker.img")
        let lockedHash = try hash(locked)
        let lockedReport = try NTFSAnalyzer.analyze(url: locked)
        try expect(lockedReport.format == "BitLocker" && lockedReport.status == "unsupported" && lockedReport.files.isEmpty,
            "BitLocker 应识别后停止")
        try expect(try hash(locked) == lockedHash, "BitLocker 检查改写源文件")

        let symlink = base.appendingPathComponent("symlink.img")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: valid)
        var caught = false
        do { _ = try NTFSAnalyzer.analyze(url: symlink) } catch { caught = true }
        try expect(caught, "必须拒绝最终符号链接")
        let dirlink = base.appendingPathComponent("directory-symlink")
        try fm.createSymbolicLink(at: dirlink, withDestinationURL: base)
        caught = false
        do { _ = try NTFSAnalyzer.analyze(url: dirlink.appendingPathComponent(valid.lastPathComponent)) } catch { caught = true }
        try expect(caught, "必须拒绝祖先符号链接")
        let hardlink = base.appendingPathComponent("hardlink.img")
        try fm.linkItem(at: valid, to: hardlink)
        caught = false
        do { _ = try NTFSAnalyzer.analyze(url: hardlink) } catch { caught = true }
        try expect(caught, "必须拒绝硬链接文件")
        try fm.removeItem(at: hardlink)
        caught = false
        do { _ = try NTFSAnalyzer.analyze(url: base) } catch { caught = true }
        try expect(caught, "必须拒绝目录")
        caught = false
        do { _ = try NTFSAnalyzer.analyze(url: URL(fileURLWithPath: "/dev/null")) } catch { caught = true }
        try expect(caught, "必须在读取前拒绝设备")
        let fifo = base.appendingPathComponent("not-an-image.fifo")
        try expect(Darwin.mkfifo(fifo.path, 0o600) == 0, "无法创建隔离 FIFO 样本")
        caught = false
        do { _ = try NTFSAnalyzer.analyze(url: fifo) } catch { caught = true }
        try expect(caught, "必须拒绝 FIFO 且不得阻塞")
        caught = false
        do { _ = try NTFSAnalyzer.analyze(url: valid, cancelled: { true }) } catch NTFSAnalysisError.cancelled { caught = true }
        try expect(caught, "取消未生效")
        let mutable = try write(original, "mutation-only-disposable.img")
        let mutation = MutationOnce(mutable)
        caught = false
        do { _ = try NTFSAnalyzer.analyze(url: mutable, cancelled: { mutation.callback() }) }
        catch NTFSAnalysisError.changed { caught = true }
        try expect(caught, "未拒绝读取期间变化的文件")

        let oversized = base.appendingPathComponent("oversized-sparse-test.img")
        let largeFD = Darwin.open(oversized.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard largeFD >= 0 else { throw TestFailure(description: "无法建立仅测试用的稀疏普通文件") }
        let truncateResult = Darwin.ftruncate(largeFD, off_t(NTFSAnalyzer.maximumImageBytes + 1))
        Darwin.close(largeFD)
        try expect(truncateResult == 0, "无法设置测试文件逻辑长度")
        caught = false
        do { _ = try NTFSAnalyzer.analyze(url: oversized) } catch NTFSAnalysisError.budget { caught = true }
        try expect(caught, "未拒绝超过 1 TiB 的声明长度")
        try fm.removeItem(at: oversized)
        let noHash = try write(original, "hash-budget-test.img")
        let noHashFD = Darwin.open(noHash.path, O_WRONLY | O_CLOEXEC)
        guard noHashFD >= 0 else { throw TestFailure(description: "无法建立哈希预算样本") }
        let extendResult = Darwin.ftruncate(noHashFD, off_t(NTFSAnalyzer.maximumHashBytes + 1))
        Darwin.close(noHashFD)
        try expect(extendResult == 0, "无法扩展隔离哈希预算样本")
        let noHashBefore = try hash(noHash)
        let noHashReport = try NTFSAnalyzer.analyze(url: noHash)
        try expect(noHashReport.sourceSHA256 == nil && noHashReport.hashScope.contains("未计算"), "超过预算不得伪称全文件哈希")
        try expect(noHashReport.inspectedBytes < 1 << 20, "超过哈希预算仍读取了全文件")
        try expect(try hash(noHash) == noHashBefore, "哈希预算测试改变源文件")
        try expect(try hash(valid) == beforeHash, "测试结束合法源样本发生变化")
        print("PASS: \(checks) assertions; source SHA-256 \(beforeHash)")
        print("SCOPE: \(SyntheticNTFS.sourceNote)")
        print("No app, browser, device, volume, mount, repair, or GUI was launched or modified.")
    }
}
