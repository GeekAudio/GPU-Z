import SwiftUI

struct TestHistoryView: View {
    let loadHistory: () throws -> [TestHistoryEntry]
    let clearHistory: () throws -> Void

    // `presentationMode` works with the app's macOS 11 deployment target.
    @Environment(\.presentationMode) private var presentationMode
    @State private var entries: [TestHistoryEntry] = []
    @State private var selectedRunID: String?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var clearError: String?
    @State private var confirmsClear = false
    @State private var startedLoading = false
    @State private var detail: HistoryResultDetail?
    @State private var selectedResult: HistoryResultSelection?

    var body: some View {
        if #available(macOS 12, *) {
            content.alert("清空测试历史？", isPresented: $confirmsClear) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { reloadHistory(clearing: true) }
            } message: {
                Text(clearMessage)
            }
        } else {
            content.alert(isPresented: $confirmsClear) {
                Alert(title: Text("清空测试历史？"), message: Text(clearMessage),
                      primaryButton: .destructive(Text("清空")) { reloadHistory(clearing: true) },
                      secondaryButton: .cancel(Text("取消")))
            }
        }
    }

    private var clearMessage: String {
        "这会永久删除本机保存的测试成绩。诊断日志和已导出的报告仍可查阅。"
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            mainContent
            footer
        }
        .frame(width: 940, height: 620)
        .font(DesignTokens.Font.body)
        .foregroundColor(DesignTokens.Text.primary)
        .background(DesignTokens.Surface.window)
        .buttonStyle(NativeButtonStyle())
        .sheet(item: $detail) { detail in
            ResultDetails(row: detail.row, softwareRatio: detail.softwareRatio)
                .background(DesignTokens.Surface.window)
        }
        .onAppear {
            guard !startedLoading else { return }
            startedLoading = true
            reloadHistory()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(DesignTokens.Font.title2)
                .foregroundColor(.codecAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("测试历史").font(DesignTokens.Font.title2)
                Text(isLoading ? "正在读取本机记录…" : "\(entries.count) 轮记录 · 按时间排列")
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
            }
            Spacer()
            Button { confirmsClear = true } label: { Label("清空历史…", systemImage: "trash") }
                .disabled(isLoading || entries.isEmpty)
                .accessibilityIdentifier("history-clear")
            Button { reloadHistory() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                .disabled(isLoading)
                .help("重新读取本机保存的测试记录")
                .accessibilityIdentifier("history-refresh")
            Button("关闭") { presentationMode.wrappedValue.dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("history-close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var mainContent: some View {
        if isLoading && entries.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在读取本机历史记录…")
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, entries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(DesignTokens.Font.title2)
                    .foregroundColor(DesignTokens.Status.warning)
                Text("无法读取历史记录").font(DesignTokens.Font.title3)
                Text(loadError)
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if entries.isEmpty {
            emptyHistory
        } else {
            historyBrowser
        }
    }

    private var emptyHistory: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(DesignTokens.Font.title2)
                .foregroundColor(DesignTokens.Text.secondary)
            Text("还没有已保存的测试记录").font(DesignTokens.Font.title3)
            Text("完成测试后，本机历史记录会显示在这里。")
                .font(DesignTokens.Font.small)
                .foregroundColor(DesignTokens.Text.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyBrowser: some View {
        HStack(spacing: 0) {
            runList
                .frame(width: 218)
            Hairline(axis: .vertical)
            if let entry = selectedEntry {
                runDetail(entry)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var runList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本机记录").font(DesignTokens.Font.title3)
                .padding(.horizontal, 14)
                .padding(.top, 14)

            ScrollView(.vertical) {
                LazyVStack(spacing: 6) {
                    ForEach(entries) { entry in
                        let row = TestHistoryMatrix.row(for: entry)
                        HistoryRunListButton(entry: entry, row: row,
                                              selected: selectedRunID == entry.id) {
                            selectedRunID = entry.id
                            selectedResult = nil
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(DesignTokens.Surface.sidebarTint)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("本机测试记录"))
    }

    private func runDetail(_ entry: TestHistoryEntry) -> some View {
        let row = TestHistoryMatrix.row(for: entry)
        let plannedIDs = Set(entry.report.plannedCaseIDs ?? CodecTestPlan.legacyCaseIDs)
        let softwareCases = CodecTestPlan.cases.filter {
            $0.mode != "强制硬件" && plannedIDs.contains($0.id)
        }

        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                HistoryRunOverview(entry: entry, row: row)
                HistoryHardwareMatrix(entry: entry, row: row,
                                      selectedResult: selectedResult,
                                      openResult: openResult)
                if !softwareCases.isEmpty {
                    HistorySoftwareSection(entry: entry, cases: softwareCases,
                                           openResult: openResult)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("history-run-detail")
    }

    private var selectedEntry: TestHistoryEntry? {
        if let selectedRunID, let entry = entries.first(where: { $0.id == selectedRunID }) {
            return entry
        }
        return entries.first
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: loadError == nil && clearError == nil ? "info.circle" : "exclamationmark.triangle")
                .accessibilityHidden(true)
            Text(clearError.map { "清空历史失败：\($0)" } ?? loadError.map { "读取历史失败：\($0)" }
                 ?? "选择一轮查看成绩；点击成绩可检查测试详情。")
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("仅保存在本机").fixedSize()
        }
        .font(DesignTokens.Font.small)
        .foregroundColor(DesignTokens.Text.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func openResult(_ result: BenchRow, in entry: TestHistoryEntry) {
        selectedRunID = entry.id
        selectedResult = HistoryResultSelection(runID: entry.id, caseID: result.id)
        detail = HistoryResultDetail(row: result,
                                     softwareRatio: historySoftwareRatio(for: result, report: entry.report))
    }

    private func reloadHistory(clearing: Bool = false) {
        isLoading = true
        loadError = nil
        clearError = nil
        let loader = loadHistory
        let clear = clearHistory
        DispatchQueue.global(qos: .utility).async {
            let cleared = Result { if clearing { try clear() } }
            let loaded = Result { TestHistoryMatrix.newestFirst(try loader()) }
            DispatchQueue.main.async {
                if case .failure(let error) = cleared {
                    clearError = DiagnosticRedactor.redact(error.localizedDescription)
                }
                switch loaded {
                case .success(let loaded):
                    entries = loaded
                    if !loaded.contains(where: { $0.id == selectedRunID }) {
                        selectedRunID = loaded.first?.id
                    }
                    if let selection = selectedResult, !loaded.contains(where: { $0.id == selection.runID }) {
                        selectedResult = nil
                    }
                case .failure(let error):
                    if clearing, case .success = cleared {
                        entries = []
                        selectedRunID = nil
                        selectedResult = nil
                    }
                    loadError = DiagnosticRedactor.redact(error.localizedDescription)
                }
                isLoading = false
            }
        }
    }
}

private struct HistoryRunListButton: View {
    let entry: TestHistoryEntry
    let row: TestHistoryMatrixRow
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.dateText(entry.createdAt))
                        .font(DesignTokens.Font.body.weight(.medium).monospacedDigit())
                        .foregroundColor(DesignTokens.Text.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    Text("\(row.passedSummary) 通过")
                        .font(DesignTokens.Font.small.monospacedDigit())
                        .foregroundColor(DesignTokens.Text.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Text("驱动 \(row.driverVersion.value)")
                        .font(DesignTokens.Font.small)
                        .foregroundColor(DesignTokens.Text.secondary)
                        .lineLimit(1)
                    if let sourceLabel = row.driverVersion.sourceLabel {
                        Text("· \(sourceLabel)")
                            .font(DesignTokens.Font.small)
                            .foregroundColor(DesignTokens.Text.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DesignTokens.corner)
                .fill(selected ? DesignTokens.Interaction.selection(active: true).opacity(0.14)
                      : DesignTokens.Surface.content.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.corner)
                .strokeBorder(DesignTokens.Stroke.separator.opacity(selected ? 0.9 : 0.45), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.corner))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Self.dateText(entry.createdAt)), \(row.passedSummary) 项通过，驱动 \(row.driverVersion.value)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("history-run-\(entry.id)")
        .help(row.context + "\n驱动版本：" + row.driverVersion.help)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private static func dateText(_ date: Date) -> String { dateFormatter.string(from: date) }
}

private struct HistoryRunOverview: View {
    let entry: TestHistoryEntry
    let row: TestHistoryMatrixRow

    private var gpu: String? { environmentValue("GPU") }
    private var system: String? { environmentValue("系统") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.dateFormatter.string(from: entry.createdAt))
                        .font(DesignTokens.Font.title3.monospacedDigit())
                    Text(entry.report.runState)
                        .font(DesignTokens.Font.small)
                        .foregroundColor(DesignTokens.Text.secondary)
                }
                Spacer(minLength: 6)
                Text("\(row.passedSummary)")
                    .font(DesignTokens.Font.title2.monospacedDigit())
                    .foregroundColor(DesignTokens.Text.primary)
                    .help("通过项数 / 本轮计划项数")
            }

            HStack(alignment: .top, spacing: 14) {
                if let gpu {
                    HistoryMetadataItem(title: "GPU", value: CodecPresentation.displayGPUName(gpu))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(gpu)
                }
                if let system {
                    HistoryMetadataItem(title: "系统", value: system)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HistoryMetadataItem(title: "驱动", value: row.driverVersion.value,
                                    note: row.driverVersion.sourceLabel)
                    .frame(width: 118, alignment: .leading)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(DesignTokens.Surface.content)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.corner))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.corner)
            .strokeBorder(DesignTokens.Stroke.separator, lineWidth: 1))
        .help(row.context + "\n驱动版本：" + row.driverVersion.help)
    }

    private func environmentValue(_ key: String) -> String? {
        entry.report.environment.first(where: { $0.key == key })?.value
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

private struct HistoryMetadataItem: View {
    let title: String
    let value: String
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DesignTokens.Font.small)
                .foregroundColor(DesignTokens.Text.secondary)
            Text(value)
                .font(DesignTokens.Font.body.weight(.medium))
                .foregroundColor(DesignTokens.Text.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(note).font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary).lineLimit(1)
            }
        }
        .help(note.map { "\(title)：\(value) · \($0)" } ?? "\(title)：\(value)")
    }
}

private struct HistoryHardwareMatrix: View {
    let entry: TestHistoryEntry
    let row: TestHistoryMatrixRow
    let selectedResult: HistoryResultSelection?
    let openResult: (BenchRow, TestHistoryEntry) -> Void

    private let codecs = ["H.264", "HEVC"]
    private let bands = [
        HistoryHardwareBand(group: "编码", resolution: "1080p"),
        HistoryHardwareBand(group: "编码", resolution: "4K"),
        HistoryHardwareBand(group: "解码", resolution: "1080p"),
        HistoryHardwareBand(group: "解码", resolution: "4K")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("硬件编解码").font(DesignTokens.Font.body.weight(.semibold))

            ForEach(bands) { band in
                HStack(spacing: 8) {
                    Text(band.title)
                        .font(DesignTokens.Font.small.weight(.medium))
                        .foregroundColor(DesignTokens.Text.secondary)
                        .frame(width: 70, alignment: .leading)
                    ForEach(codecs, id: \.self) { codec in
                        let item = "\(codec) \(band.resolution)"
                        let caseID = CodecTestPlan.id(group: band.group, item: item, mode: "强制硬件")
                        hardwareCell(caseID: caseID, selected: selectedResult?.runID == entry.id
                                     && selectedResult?.caseID == caseID)
                    }
                }
                .frame(height: 54)
            }
        }
        .padding(14)
        .background(DesignTokens.Surface.window)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.corner))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.corner)
            .strokeBorder(DesignTokens.Stroke.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("硬件成绩"))
    }

    @ViewBuilder
    private func hardwareCell(caseID: String, selected: Bool) -> some View {
        let cell = row.cells.first(where: { $0.caseID == caseID })
        if let result = savedResult(caseID: caseID) {
            let classification = CodecPresentation.classification(result)
            Button { openResult(result, entry) } label: {
                HistoryScoreCell(title: result.item.hasPrefix("H.264") ? "H.264" : "HEVC",
                                 value: cell?.value ?? "待验证",
                                 status: classification.0,
                                 selected: selected,
                                 measured: cell?.value.hasSuffix(" FPS") == true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(result.group) \(result.item) 强制硬件，\(classification.0)，\(cell?.value ?? "待验证")，查看详情")
            .accessibilityIdentifier("history-case-\(caseID)")
            .help(cell?.help ?? result.detail)
        } else {
            HistoryScoreCell(title: caseID.contains("HEVC") ? "HEVC" : "H.264",
                             value: cell?.value ?? "未选",
                             status: cell?.help.components(separatedBy: "\n").first ?? "未选",
                             selected: false,
                             measured: false)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(caseID.replacingOccurrences(of: "|", with: " "))，\(cell?.value ?? "未选")")
                .help(cell?.help ?? "本轮没有选择该项目。")
        }
    }

    private func savedResult(caseID: String) -> BenchRow? {
        let plan = entry.report.plannedCaseIDs ?? CodecTestPlan.legacyCaseIDs
        guard plan.contains(caseID) else { return nil }
        let matches = entry.report.results.filter { $0.id == caseID }
        return matches.count == 1 ? matches.first : nil
    }
}

private struct HistoryHardwareBand: Identifiable {
    let group: String
    let resolution: String
    var title: String { "\(group) · \(resolution)" }
    var id: String { "\(group)|\(resolution)" }
}

private struct HistoryScoreCell: View {
    let title: String
    let value: String
    let status: String
    let selected: Bool
    let measured: Bool

    var body: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(DesignTokens.Font.small.weight(.medium))
                    .foregroundColor(DesignTokens.Text.primary)
                Text(status)
                    .font(DesignTokens.Font.small)
                    .foregroundColor(measured ? DesignTokens.Text.secondary : DesignTokens.Text.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(measured ? String(value.dropLast(4)) : value)
                    .font(DesignTokens.Font.body.monospacedDigit().weight(.medium))
                    .foregroundColor(measured ? DesignTokens.Text.primary : DesignTokens.Text.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if measured {
                    Text("FPS").font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignTokens.corner)
            .fill(selected ? DesignTokens.Interaction.selection(active: true).opacity(0.12)
                  : DesignTokens.Surface.content))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.corner)
            .strokeBorder(DesignTokens.Stroke.separator, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.corner))
    }
}

private struct HistorySoftwareSection: View {
    let entry: TestHistoryEntry
    let cases: [CodecTestPlan.Case]
    let openResult: (BenchRow, TestHistoryEntry) -> Void

    private let bands = [
        HistoryHardwareBand(group: "编码", resolution: "1080p"),
        HistoryHardwareBand(group: "编码", resolution: "4K"),
        HistoryHardwareBand(group: "解码", resolution: "1080p"),
        HistoryHardwareBand(group: "解码", resolution: "4K")
    ]

    private var visibleBands: [HistoryHardwareBand] {
        bands.filter { band in
            cases.contains {
                $0.group == band.group && $0.item.hasSuffix(band.resolution)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("软解对照").font(DesignTokens.Font.body.weight(.semibold))
                Spacer()
                Text("硬件 / 软件吞吐比")
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
                    .lineLimit(1)
            }

            ForEach(visibleBands) { band in
                HStack(spacing: 8) {
                    Text(band.title)
                        .font(DesignTokens.Font.small.weight(.medium))
                        .foregroundColor(DesignTokens.Text.secondary)
                        .frame(width: 70, alignment: .leading)
                    ForEach(softwareCases(in: band)) { testCase in
                        softwareCell(testCase)
                    }
                }
                .frame(height: 54)
            }
        }
        .padding(14)
        .background(DesignTokens.Surface.content.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.corner))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.corner)
            .strokeBorder(DesignTokens.Stroke.separator, lineWidth: 1))
    }

    private func softwareCases(in band: HistoryHardwareBand) -> [CodecTestPlan.Case] {
        let codecs = ["H.264", "HEVC"]
        return codecs.compactMap { codec in
            cases.first {
                $0.group == band.group && $0.item == "\(codec) \(band.resolution)"
            }
        }
    }

    @ViewBuilder
    private func softwareCell(_ testCase: CodecTestPlan.Case) -> some View {
        let cell = TestHistoryMatrix.cell(report: entry.report, caseID: testCase.id)
        let matchingHardware = entry.report.results.filter {
            $0.group == testCase.group && $0.item == testCase.item && $0.mode == "强制硬件"
        }
        let ratio = matchingHardware.count == 1
            ? historySoftwareRatio(hardware: matchingHardware[0], report: entry.report) : nil
        if let result = savedResult(caseID: testCase.id) {
            Button { openResult(result, entry) } label: {
                HistoryScoreCell(title: testCase.item.hasPrefix("H.264") ? "H.264" : "HEVC",
                                 value: cell.value,
                                 status: softwareStatus(result, ratio: ratio),
                                 selected: false,
                                 measured: cell.value.hasSuffix(" FPS"))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(testCase.group) \(testCase.item) \(testCase.mode)，\(cell.value)\(ratio.map { "，硬件与软件吞吐比 \(String(format: "%.2f", $0)) 倍" } ?? "")，查看详情")
            .accessibilityIdentifier("history-case-\(testCase.id)")
            .help(softwareHelp(testCase: testCase, cell: cell, ratio: ratio))
        } else {
            HistoryScoreCell(title: testCase.item.hasPrefix("H.264") ? "H.264" : "HEVC",
                             value: cell.value,
                             status: cell.help.components(separatedBy: "\n").first ?? "未测",
                             selected: false,
                             measured: false)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(testCase.group) \(testCase.item) \(testCase.mode)，\(cell.value)")
                .help(cell.help)
        }
    }

    private func softwareStatus(_ row: BenchRow, ratio: Double?) -> String {
        let classification = CodecPresentation.classification(row).0
        guard let ratio else { return classification }
        return "\(classification) · \(String(format: "%.2f×", ratio)) 硬 / 软"
    }

    private func savedResult(caseID: String) -> BenchRow? {
        let matches = entry.report.results.filter { $0.id == caseID }
        return matches.count == 1 ? matches.first : nil
    }

    private func softwareHelp(testCase: CodecTestPlan.Case,
                              cell: TestHistoryMatrixCell, ratio: Double?) -> String {
        var lines = [cell.help]
        if let ratio {
            lines.append("配对硬件 / 软件吞吐比：\(String(format: "%.2f×", ratio))")
            lines.append(testCase.group == "编码" ? "编码吞吐比不代表两路画质相同。" : "对照使用同一份固定码流。")
        }
        return lines.joined(separator: "\n")
    }
}

private struct HistoryResultDetail: Identifiable {
    let row: BenchRow
    let softwareRatio: Double?

    var id: String { row.id }
}

private struct HistoryResultSelection: Equatable {
    let runID: String
    let caseID: String
}

private func historySoftwareRatio(hardware: BenchRow, report: CodecReport) -> Double? {
    let plannedIDs = report.plannedCaseIDs ?? CodecTestPlan.legacyCaseIDs
    guard hardware.mode == "强制硬件", plannedIDs.contains(hardware.id),
          hardware.group != "解码" || hardware.decodeFixtureEvidence != nil else { return nil }
    let matches = report.results.filter {
        plannedIDs.contains($0.id) && CodecTestPlan.hardwareComparisonCaseID(forSoftwareCaseID: $0.id) == hardware.id
    }
    guard matches.count == 1, let software = matches.first else { return nil }
    return hardware.throughputRatio(comparedTo: software)
}

private func historySoftwareRatio(for result: BenchRow, report: CodecReport) -> Double? {
    let plannedIDs = report.plannedCaseIDs ?? CodecTestPlan.legacyCaseIDs
    guard plannedIDs.contains(result.id) else { return nil }
    if result.mode == "强制硬件" {
        return historySoftwareRatio(hardware: result, report: report)
    }
    let hardwareRows = report.results.filter {
        $0.id == CodecTestPlan.hardwareComparisonCaseID(forSoftwareCaseID: result.id)
            && plannedIDs.contains($0.id)
    }
    guard hardwareRows.count == 1, let hardware = hardwareRows.first else { return nil }
    return historySoftwareRatio(hardware: hardware, report: report)
}
