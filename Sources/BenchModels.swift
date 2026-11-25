import Foundation
import CoreMedia

// MARK: - 模式

enum EncodeMode: String, CaseIterable, Identifiable, Codable {
    case forcedHW = "强制硬件"
    case auto     = "自动选择"
    case software = "软件编码"
    var id: String { rawValue }
}

enum DecodeMode: String, CaseIterable, Identifiable, Codable {
    case forcedHW = "强制硬件"
    case auto     = "自动选择"
    case software = "软件解码"
    var id: String { rawValue }
}

// MARK: - 结果

/// 状态描述本项测试是否完成；NVIDIA 归属独立由证据字段表达。
enum BenchStatus: String, Codable, CaseIterable {
    case passed = "成功"
    case failed = "失败"
    case unverified = "未验证"
    case notTested = "未测试"
    case cancelled = "取消"
}

enum BenchAttribution: String, Codable {
    case nvidiaConfirmed
    case systemHardwareUnknownGPU
    case otherHardware
    case software
    case unknown
}

struct BenchStatistics: Codable {
    var frames = 0
    var requestedFrames = 0
    var submittedFrames = 0
    var droppedFrames = 0
    var elapsed: Double = 0
    var measurementCount = 1
    var fpsMin: Double = 0
    var fpsMax: Double = 0
    var bytesPerFrame = 0
    var cpuUsage: BenchCPUUsage? = nil
    var systemCPUUsage: BenchSystemCPUUsage? = nil

    /// Percent of total logical CPU capacity; 100% means all logical CPUs.
    var cpuUsagePercent: Double? {
        guard let cpuUsage, cpuUsage.isValid,
              elapsed.isFinite, elapsed > 0 else { return nil }
        let percent = cpuUsage.processCPUTime / elapsed / Double(cpuUsage.logicalCPUCount) * 100
        // Small tolerance accounts for getrusage's microsecond resolution at the sample edges.
        guard percent.isFinite, percent >= 0, percent <= 100.5 else { return nil }
        return min(percent, 100)
    }

    /// Process CPU time per successfully produced frame, independent of core count.
    var cpuMillisecondsPerFrame: Double? {
        guard let cpuUsage, cpuUsage.isValid, frames > 0 else { return nil }
        let milliseconds = cpuUsage.processCPUTime * 1_000 / Double(frames)
        return milliseconds.isFinite && milliseconds > 0 ? milliseconds : nil
    }

    /// Whole-machine busy time, including background processes, during the trial window.
    var systemCPUUsagePercent: Double? {
        guard let systemCPUUsage, systemCPUUsage.isValid else { return nil }
        let percent = Double(systemCPUUsage.busyTicks) / Double(systemCPUUsage.totalTicks) * 100
        return percent.isFinite && (0...100).contains(percent) ? percent : nil
    }
}

/// CPU time used by the codec worker process during one measured trial.
struct BenchCPUUsage: Codable, Equatable {
    let processCPUTime: Double
    let logicalCPUCount: Int

    fileprivate var isValid: Bool {
        processCPUTime.isFinite && processCPUTime > 0 && logicalCPUCount > 0
    }
}

/// Host-wide CPU tick delta during one measured trial; busy includes user, system and nice.
struct BenchSystemCPUUsage: Codable, Equatable {
    let busyTicks: UInt64
    let totalTicks: UInt64

    fileprivate var isValid: Bool {
        totalTicks > 0 && busyTicks <= totalTicks
    }
}

struct VTSessionPropertyEvidence: Codable, Equatable {
    let name: String
    let status: Int32
    let value: String?

    var reportValue: String {
        guard status == 0 else { return "查询失败 OSStatus=\(status)" }
        return value ?? "未提供"
    }
}

enum EncoderPresetEvidenceStatus: String, Codable {
    case reported
    case notReportedByVideoToolbox
}

struct EncoderQualityEvidence: Codable, Equatable {
    /// VideoToolbox does not return a universal P-level preset for these encoders.
    /// Leave nil unless the encoder itself reports one.
    var reportedPreset: String?
    var presetStatus: EncoderPresetEvidenceStatus
    var sessionProperties: [VTSessionPropertyEvidence]
    /// Calculated from encoded sample sizes and presentation duration, not the target bitrate.
    var outputBitrateBps: Int64?

    init(reportedPreset: String?, sessionProperties: [VTSessionPropertyEvidence],
         outputBitrateBps: Int64?) {
        self.reportedPreset = reportedPreset
        self.presetStatus = reportedPreset == nil ? .notReportedByVideoToolbox : .reported
        self.sessionProperties = sessionProperties
        self.outputBitrateBps = outputBitrateBps
    }

    var reportedPresetLabel: String {
        reportedPreset ?? "未报告"
    }

    var reportLines: [String] {
        var lines = ["可核实画质档 · \(reportedPresetLabel)"]
        if presetStatus == .notReportedByVideoToolbox {
            lines.append("画质档状态 · VideoToolbox 未提供通用 P 档位，无法核实具体 P 档")
        }
        if let outputBitrateBps {
            lines.append("实际输出码率 · \(outputBitrateBps) bit/s（由样本大小和时长计算）")
        } else {
            lines.append("实际输出码率 · 未取得")
        }
        lines += sessionProperties.map { "\($0.name) · \($0.reportValue)" }
        return lines
    }
}

struct DecodeFixtureEvidence: Codable, Equatable {
    let identifier: String
    let sha256: String
}

/// 取消是协作式的：只在 VT 调用之间检查，已提交的帧始终安全排空。
final class BenchCancellation {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    static let waitingDescription = "正在取消：等待当前驱动调用返回并安全排空…"
}

struct BenchOutcome {
    var ok = false
    var status: BenchStatus = .failed
    var fps: Double = 0
    var elapsed: Double = 0
    var frames: Int = 0              // 实际有效输出，不是请求帧数
    var requestedFrames = 0
    var submittedFrames = 0
    var droppedFrames = 0
    var measurementCount = 1
    var fpsMin: Double = 0
    var fpsMax: Double = 0
    var hardwareAccelerated: Bool? = nil
    var encoderID = ""
    var encoderQualityEvidence: EncoderQualityEvidence?
    var decodeFixtureEvidence: DecodeFixtureEvidence?
    var gpuName = ""
    var gpuRegistryID: UInt64? = nil
    var gpuVendorID: UInt32? = nil
    var attribution: BenchAttribution = .unknown
    var isNVIDIAConfirmed = false
    var hardwareEvidence = ""
    var gpuEvidence = ""
    var nvidiaEvidence = ""
    var warningText = ""
    var errorText = ""
    var failureStage: String?
    var failureOSStatus: Int32?
    var usedEngine = ""
    var bytesPerFrame = 0
    var cpuUsage: BenchCPUUsage?
    var systemCPUUsage: BenchSystemCPUUsage?
    var samples: [CMSampleBuffer] = []

    mutating func recordIssue(_ message: String) {
        errorText = errorText.isEmpty ? message : errorText + "；" + message
    }
}

struct BenchRow: Identifiable, Codable {
    var id: String { group + "|" + item + "|" + mode }
    let group: String
    let item: String
    let mode: String
    let ok: Bool
    let fps: Double
    let engine: String
    let detail: String
    let status: BenchStatus
    let hardwareAccelerated: Bool?
    let encoderID: String
    let encoderQualityEvidence: EncoderQualityEvidence?
    let decodeFixtureEvidence: DecodeFixtureEvidence?
    let gpuName: String
    let gpuRegistryID: UInt64?
    let gpuVendorID: UInt32?
    let attribution: BenchAttribution
    let isNVIDIAConfirmed: Bool
    let hardwareEvidence: String
    let gpuEvidence: String
    let nvidiaEvidence: String
    let warningText: String
    let statistics: BenchStatistics?
    let failureStage: String?
    let failureOSStatus: Int32?

    /// True only when the run succeeded and produced a displayable positive finite rate.
    /// This is derived from existing report fields and is not serialized.
    var hasValidMeasurement: Bool {
        MeasurementValidity.isValid(statusPassed: status == .passed, ok: ok, fps: fps)
    }

    /// Both display and text export use the same measured, matching software baseline.
    func throughputRatio(comparedTo software: BenchRow) -> Double? {
        guard hasValidMeasurement, hardwareAccelerated == true,
              software.hasValidMeasurement, group == software.group, item == software.item,
              group == "编码" || group == "解码",
              group != "解码" || decodeFixtureEvidence == software.decodeFixtureEvidence,
              software.mode == (group == "编码" ? "软件编码" : "软件解码"),
              software.attribution == .software || software.hardwareAccelerated == false else { return nil }
        let ratio = fps / software.fps
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }

    func softwareRatio(in results: [BenchRow]) -> Double? {
        results.lazy.compactMap { self.throughputRatio(comparedTo: $0) }.first
    }

    /// 保留原有参数；新增证据均有默认值，旧调用不会因此产生 NVIDIA 结论。
    init(group: String, item: String, mode: String, ok: Bool, fps: Double,
         engine: String, detail: String, status: BenchStatus? = nil,
         hardwareAccelerated: Bool? = nil, encoderID: String = "", gpuName: String = "",
         gpuRegistryID: UInt64? = nil, gpuVendorID: UInt32? = nil,
         attribution: BenchAttribution = .unknown, isNVIDIAConfirmed: Bool = false,
         hardwareEvidence: String = "", gpuEvidence: String = "", nvidiaEvidence: String = "",
         warningText: String = "",
         encoderQualityEvidence: EncoderQualityEvidence? = nil,
         decodeFixtureEvidence: DecodeFixtureEvidence? = nil,
         statistics: BenchStatistics? = nil,
         failureStage: String? = nil, failureOSStatus: Int32? = nil) {
        self.group = group
        self.item = item
        self.mode = mode
        self.ok = ok
        self.fps = fps
        self.engine = engine
        self.detail = detail
        self.status = status ?? (ok ? .passed : .failed)
        self.hardwareAccelerated = hardwareAccelerated
        self.encoderID = encoderID
        self.encoderQualityEvidence = encoderQualityEvidence
        self.decodeFixtureEvidence = decodeFixtureEvidence
        self.gpuName = gpuName
        self.gpuRegistryID = gpuRegistryID
        self.gpuVendorID = gpuVendorID
        self.attribution = attribution
        self.isNVIDIAConfirmed = isNVIDIAConfirmed
        self.hardwareEvidence = hardwareEvidence
        self.gpuEvidence = gpuEvidence
        self.nvidiaEvidence = nvidiaEvidence
        self.warningText = warningText
        self.statistics = statistics
        self.failureStage = failureStage
        self.failureOSStatus = failureOSStatus
    }
}

struct EncCase {
    let codec: CMVideoCodecType
    let w: Int, h: Int, frames: Int, bitrate: Int
    let mode: EncodeMode
    var label: String {
        let c = codec == kCMVideoCodecType_HEVC ? "HEVC" : "H.264"
        return "\(c) \(w >= 3840 ? "4K" : "1080p")"
    }
}
