import Foundation
import CoreMedia
import VideoToolbox
import Darwin

enum ColdStartupCase: String, Codable, CaseIterable, Identifiable {
    case h264Encode = "h264-encode"
    case hevcEncode = "hevc-encode"
    case h264Decode = "h264-decode"
    case hevcDecode = "hevc-decode"

    var id: String { rawValue }
    var encoding: Bool { rawValue.hasSuffix("encode") }
    var codec: CMVideoCodecType {
        rawValue.hasPrefix("h264") ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
    }
    var name: String {
        let codecName = rawValue.hasPrefix("h264") ? "H.264" : "HEVC"
        return "\(codecName) 1080p \(encoding ? "硬编" : "硬解")"
    }
}

enum ColdStartupCaseStatus: String, Codable {
    case passed = "通过"
    case failed = "失败"
    case sessionUnavailable = "首次会话不可用"
    case notTested = "未测试"
    case timedOut = "超时"
    case launchFailed = "子进程启动失败"
    case invalidOutput = "子进程结果无效"
}

private final class ColdStartupPipeCapture {
    enum Retention {
        case head
        case tail
    }

    private let lock = NSLock()
    private let limit: Int
    private let retention: Retention
    private var stored = Data()
    private var didTruncate = false

    init(limit: Int, retention: Retention) {
        self.limit = limit
        self.retention = retention
    }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        switch retention {
        case .head:
            let remaining = max(0, limit - stored.count)
            if chunk.count > remaining { didTruncate = true }
            if remaining > 0 { stored.append(chunk.prefix(remaining)) }
        case .tail:
            stored.append(chunk)
            if stored.count > limit {
                stored.removeFirst(stored.count - limit)
                didTruncate = true
            }
        }
    }

    func snapshot() -> (data: Data, truncated: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (stored, didTruncate)
    }
}

struct ColdStartupWorkerOutput: Codable {
    let caseID: String
    let workerPID: Int32
    let row: BenchRow?
    let error: String?
}

struct ColdStartupCaseReport: Codable, Identifiable {
    let caseID: String
    let name: String
    let status: ColdStartupCaseStatus
    let workerPID: Int32?
    let elapsed: Double
    let row: BenchRow?
    let error: String?
    let diagnostic: String

    var id: String { caseID }
}

struct ColdStartupReport: Codable {
    let schemaVersion: Int
    let appVersion: String
    let systemVersion: String
    let startedAt: Date
    let finishedAt: Date
    let cases: [ColdStartupCaseReport]

    var passedCount: Int { cases.filter { $0.status == .passed }.count }
    var allPassed: Bool { cases.count == ColdStartupCase.allCases.count && passedCount == cases.count }
}

enum ColdStartupCheck {
    private static let caseArgument = "--cold-check-worker"
    private static let timeoutSeconds: TimeInterval = 20
    private static let diagnosticLimit = 16_384
    private static let outputLimit = 1_048_576

    /// Execute every format in a fresh process, in a fixed order, without environment probing.
    static func run(executableURL: URL? = Bundle.main.executableURL,
                    timeout: TimeInterval = timeoutSeconds) -> ColdStartupReport {
        let startedAt = Date()
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        guard let executableURL else {
            let failed = ColdStartupCase.allCases.map { testCase in
                ColdStartupCaseReport(caseID: testCase.id, name: testCase.name, status: .launchFailed,
                    workerPID: nil, elapsed: 0, row: nil,
                    error: "无法定位 GPU-Z 测量程序", diagnostic: "")
            }
            return ColdStartupReport(schemaVersion: 1, appVersion: appVersion, systemVersion: systemVersion,
                                     startedAt: startedAt, finishedAt: Date(), cases: failed)
        }

        var results: [ColdStartupCaseReport] = []
        for testCase in ColdStartupCase.allCases {
            results.append(run(testCase, executableURL: executableURL, timeout: timeout))
        }
        return ColdStartupReport(schemaVersion: 1, appVersion: appVersion, systemVersion: systemVersion,
                                 startedAt: startedAt, finishedAt: Date(), cases: results)
    }

    /// Run one isolated first-session case. The child performs no Metal/VT environment enumeration.
    private static func run(_ testCase: ColdStartupCase, executableURL: URL,
                           timeout: TimeInterval) -> ColdStartupCaseReport {
        let start = ProcessInfo.processInfo.systemUptime
        let child = Process()
        child.executableURL = executableURL
        child.arguments = [caseArgument, testCase.rawValue]
        let output = Pipe(), errors = Pipe()
        child.standardOutput = output
        child.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in exited.signal() }

        do {
            try child.run()
        } catch {
            return ColdStartupCaseReport(caseID: testCase.id, name: testCase.name, status: .launchFailed,
                workerPID: nil, elapsed: ProcessInfo.processInfo.systemUptime - start, row: nil,
                error: error.localizedDescription, diagnostic: "")
        }
        output.fileHandleForWriting.closeFile()
        errors.fileHandleForWriting.closeFile()

        let pid = child.processIdentifier
        let readGroup = DispatchGroup()
        let stdoutCapture = ColdStartupPipeCapture(limit: outputLimit, retention: .head)
        let stderrCapture = ColdStartupPipeCapture(limit: diagnosticLimit, retention: .tail)
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = output.fileHandleForReading.readData(ofLength: 4096)
                if data.isEmpty { break }
                stdoutCapture.append(data)
            }
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = errors.fileHandleForReading.readData(ofLength: 4096)
                if data.isEmpty { break }
                stderrCapture.append(data)
            }
            readGroup.leave()
        }

        var timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            child.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(pid, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        if child.isRunning {
            kill(pid, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
            timedOut = true
        }
        let readFinished = readGroup.wait(timeout: .now() + 2) == .success
        if !readFinished {
            output.fileHandleForReading.closeFile()
            errors.fileHandleForReading.closeFile()
            _ = readGroup.wait(timeout: .now() + 1)
        } else {
            output.fileHandleForReading.closeFile()
            errors.fileHandleForReading.closeFile()
        }
        let capturedOutput = stdoutCapture.snapshot()
        let receivedOutput = capturedOutput.data
        let capturedErrors = stderrCapture.snapshot()
        let diagnosticText = String(decoding: capturedErrors.data, as: UTF8.self)
        let diagnostic = capturedErrors.truncated ? "[较早的驱动日志已截断]\n" + diagnosticText : diagnosticText
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        if timedOut {
            return ColdStartupCaseReport(caseID: testCase.id, name: testCase.name, status: .timedOut,
                workerPID: pid, elapsed: elapsed, row: nil,
                error: "首次会话探针超过 \(Int(timeout)) 秒", diagnostic: diagnostic)
        }

        let decoder = JSONDecoder()
        guard !capturedOutput.truncated,
              let line = receivedOutput.split(separator: 10).last,
              let result = try? decoder.decode(ColdStartupWorkerOutput.self, from: Data(line)),
              result.caseID == testCase.id,
              result.workerPID == pid,
              let row = result.row else {
            return ColdStartupCaseReport(caseID: testCase.id, name: testCase.name, status: .invalidOutput,
                workerPID: pid, elapsed: elapsed, row: nil,
                error: "冷启动子进程未返回可核验的测试行", diagnostic: diagnostic)
        }
        let frames = row.statistics?.frames ?? 0
        let requestedFrames = row.statistics?.requestedFrames ?? 0
        let passed = child.terminationStatus == 0 && row.status == .passed && row.ok &&
            frames == requestedFrames && requestedFrames > 0
        let caseStatus: ColdStartupCaseStatus
        if passed {
            caseStatus = .passed
        } else if row.status == .notTested {
            caseStatus = .notTested
        } else if row.failureStage == "创建会话", row.failureOSStatus != nil {
            caseStatus = .sessionUnavailable
        } else {
            caseStatus = .failed
        }
        return ColdStartupCaseReport(caseID: testCase.id, name: testCase.name,
            status: caseStatus, workerPID: pid, elapsed: elapsed,
            row: row, error: passed ? nil : (result.error ?? row.detail), diagnostic: diagnostic)
    }

    /// Entry point for the cold worker. This must run before `CodecWorker` or `EnvProbe`.
    static func runWorker(arguments: [String] = CommandLine.arguments) -> Int32 {
        guard let index = arguments.firstIndex(of: caseArgument), index + 1 < arguments.count,
              let testCase = ColdStartupCase(rawValue: arguments[index + 1]),
              !arguments.dropFirst(index + 2).contains(where: { $0 == caseArgument }) else {
            FileHandle.standardError.write(Data("用法：--cold-check-worker h264-encode|hevc-encode|h264-decode|hevc-decode\n".utf8))
            return 64
        }
        // The very first codec operation happens inside this method, before any encoder list
        // query, Metal device enumeration, or standard environment collection.
        let row = CodecBench.coldCheck(encoding: testCase.encoding, codec: testCase.codec)
        let output = ColdStartupWorkerOutput(caseID: testCase.id, workerPID: getpid(), row: row,
                                             error: row.ok ? nil : row.detail)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(output) else { return 70 }
        data.append(10)
        FileHandle.standardOutput.write(data)
        let frames = row.statistics?.frames ?? 0
        let requestedFrames = row.statistics?.requestedFrames ?? 0
        return row.ok && row.status == .passed && requestedFrames > 0 && frames == requestedFrames ? 0 : 1
    }

    static func jsonData(_ report: ColdStartupReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    static func renderText(_ report: ColdStartupReport) -> String {
        var lines = ["冷启动检测 · \(report.passedCount)/\(report.cases.count) 项通过"]
        for result in report.cases {
            let frameCount = result.row?.statistics.map { "\($0.frames)/\($0.requestedFrames) 帧" } ?? "无有效输出"
            let encoderID = result.row.flatMap { $0.encoderID.isEmpty ? nil : $0.encoderID } ?? "编码器未报告"
            let gpu = result.row.flatMap { $0.gpuName.isEmpty ? nil : $0.gpuName } ?? "GPU 未报告"
            lines.append("\(result.name) · \(result.status.rawValue) · \(frameCount) · \(encoderID) · \(gpu)")
            if let row = result.row {
                if let hardware = row.hardwareAccelerated {
                    lines.append("  会话硬件属性 · \(hardware ? "硬件" : "软件") · \(row.attribution.rawValue)")
                } else {
                    lines.append("  会话硬件属性未报告 · \(row.attribution.rawValue)")
                }
                if let quality = row.encoderQualityEvidence {
                    lines += quality.reportLines.map { "  \($0)" }
                }
                if let fixture = row.decodeFixtureEvidence {
                    lines.append("  固定解码样本 · \(fixture.identifier) · SHA-256 \(fixture.sha256)")
                }
            }
            if let error = result.error, !error.isEmpty { lines.append("  \(error)") }
        }
        return lines.joined(separator: "\n")
    }

    static func runCommand(arguments: [String] = CommandLine.arguments) -> Int32 {
        let report = run()
        print(renderText(report))
        if let jsonPath = argument("--json-output", in: arguments) {
            do {
                try jsonData(report).write(to: URL(fileURLWithPath: jsonPath), options: .atomic)
                print("结构化报告已写入 \(jsonPath)")
            } catch {
                FileHandle.standardError.write(Data(("写入冷启动报告失败：" + error.localizedDescription + "\n").utf8))
                return 74
            }
        }
        return report.allPassed ? 0 : 1
    }

    private static func argument(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
              !arguments[index + 1].hasPrefix("--") else { return nil }
        return arguments[index + 1]
    }
}
