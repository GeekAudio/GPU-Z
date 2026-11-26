import Foundation

struct TestHistoryEntry: Identifiable {
    let id: String
    let createdAt: Date
    let report: CodecReport
}

/// Only reuse measurements that describe the same machine, software and workload.
enum SoftwareComparisonResults {
    private static let requiredEnvironmentKeys: Set<String> = ["系统", "架构", "CPU", "GPU"]
    private static let environmentKeys = requiredEnvironmentKeys.union(["机型", "NullMoth 驱动", "内核扩展"])

    static func environment(in rows: [EnvRow]) -> [String: String] {
        rows.filter { environmentKeys.contains($0.key) }
            .reduce(into: [:]) { $0[$1.key] = $1.value }
    }

    static func canReuse(_ row: BenchRow) -> Bool {
        guard CodecTestPlan.softwareComparisonCaseIDs.contains(row.id), row.hasValidMeasurement else { return false }
        if CodecTestPlan.hardwareCaseIDs.contains(row.id) {
            guard row.hardwareAccelerated == true else { return false }
        } else {
            guard row.hardwareAccelerated != true,
                  row.attribution == .software || row.hardwareAccelerated == false else { return false }
        }
        guard row.group == "解码" else { return true }
        guard let evidence = row.decodeFixtureEvidence,
              let expected = FixedDecodeFixture.expectedEvidence(for: row.item) else { return false }
        return evidence.identifier == expected.id && evidence.sha256 == expected.sha256
    }

    static func restore(from entries: [TestHistoryEntry], matching current: [EnvRow]) -> [String: BenchRow] {
        let identity = environment(in: current)
        guard requiredEnvironmentKeys.allSatisfy({ identity[$0]?.isEmpty == false }) else { return [:] }
        var rows: [String: BenchRow] = [:]
        for entry in TestHistoryMatrix.newestFirst(entries) {
            let report = entry.report
            guard report.methodology == CodecBench.measurementDescription,
                  environment(in: report.environment) == identity else { continue }
            let planned = Set(report.plannedCaseIDs ?? CodecTestPlan.legacyCaseIDs)
            for (id, matches) in Dictionary(grouping: report.results, by: \.id) {
                guard rows[id] == nil, planned.contains(id), matches.count == 1,
                      let row = matches.first, canReuse(row) else { continue }
                rows[id] = row
            }
            if rows.count == CodecTestPlan.softwareComparisonCaseIDs.count { break }
        }
        return rows
    }
}

struct TestHistoryMatrixCell: Identifiable {
    let caseID: String
    let value: String
    let help: String

    var id: String { caseID }
}

struct TestHistoryMatrixRow: Identifiable {
    let id: String
    let createdAt: Date
    let driverVersion: TestHistoryDriverVersion
    let passedSummary: String
    let context: String
    let cells: [TestHistoryMatrixCell]
}

struct TestHistoryDriverVersion {
    let value: String
    let sourceLabel: String?
    let help: String
}

enum TestHistoryMatrix {
    static let cases = CodecTestPlan.cases

    static func rows(entries: [TestHistoryEntry]) -> [TestHistoryMatrixRow] {
        newestFirst(entries).map(row(for:))
    }

    static func row(for entry: TestHistoryEntry) -> TestHistoryMatrixRow {
        let report = entry.report
        let cells = cases.map { testCase in cell(report: report, caseID: testCase.id) }
        let plannedCount = plannedIDs(report).count
        let passedCount = cells.filter { $0.value.hasSuffix(" FPS") }.count
        return TestHistoryMatrixRow(id: entry.id, createdAt: entry.createdAt,
            driverVersion: driverVersion(in: report), passedSummary: "\(passedCount)/\(plannedCount)",
            context: contextDescription(report), cells: cells)
    }

    private static func driverVersion(in report: CodecReport) -> TestHistoryDriverVersion {
        guard let driver = report.driverReport else {
            return TestHistoryDriverVersion(value: "未记录", sourceLabel: nil,
                help: "这轮历史没有保存 NVIDIA / NullMoth 驱动版本，不使用当前驱动或应用版本补值。")
        }
        let version = driver.version?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version, !version.isEmpty else {
            var help = "本轮未记录可确认的 NVIDIA / NullMoth 驱动版本。\n状态：\(driver.summary)"
            if let installed = driver.installedVersion {
                help += "\n磁盘安装版本：\(installed)；不代表本轮加载版本。"
            }
            return TestHistoryDriverVersion(value: "未记录", sourceLabel: nil, help: help)
        }
        let source = driver.versionSource ?? "来源未记录"
        let label: String?
        if source.hasPrefix("磁盘") { label = "磁盘" }
        else if source.contains("标记") { label = "标记" }
        else { label = driver.runtimeConfirmed ? nil : "未确认" }
        var help = "本轮 NVIDIA / NullMoth 驱动版本：\(version)\n来源：\(source)\n状态：\(driver.summary)"
        if !driver.runtimeConfirmed { help += "\n安装文件或版本标记不代表本轮运行版本已确认。" }
        if driver.runtimeConfirmed, let installed = driver.installedVersion, installed != version {
            help += "\n磁盘安装版本：\(installed)；与本轮加载版本分开记录。"
        }
        return TestHistoryDriverVersion(value: version, sourceLabel: label, help: help)
    }

    static func newestFirst(_ entries: [TestHistoryEntry]) -> [TestHistoryEntry] {
        entries.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
    }

    static func cell(report: CodecReport, caseID: String) -> TestHistoryMatrixCell {
        guard plannedIDs(report).contains(caseID) else {
            return TestHistoryMatrixCell(caseID: caseID, value: "未选", help: "本轮计划没有选择该测试项目。")
        }
        let matches = report.results.filter { $0.id == caseID }
        guard matches.count == 1, let result = matches.first else {
            let value = matches.isEmpty ? "未测" : "待验证"
            let help = matches.isEmpty ? "该项目在本轮计划中，但没有保存测试结果。"
                : "该项目有多个结果行，无法确定应显示哪一个。"
            return TestHistoryMatrixCell(caseID: caseID, value: value, help: help)
        }

        let title = caseDescription(caseID)
        switch result.status {
        case .passed:
            guard result.hasValidMeasurement else {
                return TestHistoryMatrixCell(caseID: caseID, value: "待验证",
                    help: "\(title)\n状态写为通过，但没有有效的正数 FPS。\n\(result.detail)")
            }
            let fps = String(format: "%.1f FPS", locale: Locale(identifier: "en_US_POSIX"), result.fps)
            let evidence = [result.engine, result.hardwareEvidence, result.gpuEvidence,
                            result.nvidiaEvidence, result.warningText, result.detail]
                .filter { !$0.isEmpty && $0 != "—" }
                .joined(separator: "\n")
            return TestHistoryMatrixCell(caseID: caseID, value: fps,
                help: [title, "通过 · \(fps)", evidence].filter { !$0.isEmpty }.joined(separator: "\n"))
        case .failed:
            return TestHistoryMatrixCell(caseID: caseID, value: "失败", help: statusHelp(title, result))
        case .cancelled:
            return TestHistoryMatrixCell(caseID: caseID, value: "取消", help: statusHelp(title, result))
        case .notTested:
            return TestHistoryMatrixCell(caseID: caseID, value: "未测", help: statusHelp(title, result))
        case .unverified:
            return TestHistoryMatrixCell(caseID: caseID, value: "待验证", help: statusHelp(title, result))
        }
    }

    private static func plannedIDs(_ report: CodecReport) -> Set<String> {
        // Schema-version-1 reports without a plan predate the two 4K decode cases.
        // Keep their nine-case denominator and mark newly introduced columns unselected.
        let requested = Set(report.plannedCaseIDs ?? CodecTestPlan.legacyCaseIDs)
        return requested.intersection(CodecTestPlan.allCaseIDSet)
    }

    private static func statusHelp(_ title: String, _ result: BenchRow) -> String {
        [title, "状态：\(result.status.rawValue)", result.engine, result.failureStage,
         result.warningText, result.detail].compactMap { value in
            guard let value, !value.isEmpty, value != "—" else { return nil }
            return value
        }.joined(separator: "\n")
    }

    private static func contextDescription(_ report: CodecReport) -> String {
        let environmentKeys: Set<String> = ["系统", "机型", "CPU", "GPU"]
        let environment = report.environment
            .filter { environmentKeys.contains($0.key) }
            .map { "\($0.key)：\($0.value)" }
        var details = [report.runState, "应用版本：\(report.appVersion)"] + environment
        if let driverReport = report.driverReport { details.append("驱动：\(driverReport.summary)") }
        return details.joined(separator: "\n")
    }

    private static func caseDescription(_ caseID: String) -> String {
        guard let testCase = cases.first(where: { $0.id == caseID }) else { return caseID }
        return "\(testCase.group) · \(testCase.item) · \(testCase.mode)"
    }
}
