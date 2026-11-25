import SwiftUI

/// Software baselines remain opt-in, and run beside the matching hardware case on request.
struct SoftwareComparisonView: View {
    @ObservedObject var model: TestModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var detailRequest: SoftwareDetailRequest?
    @State private var selectedCaseID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if model.runningSoftwareTests { runProgress.padding(.horizontal, 16).padding(.top, 12) }
            matrix.padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let selectedTestCase {
                selectedActionBar(for: selectedTestCase)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Hairline()
            footer
        }
        .frame(width: 840, height: (selectedCaseID == nil ? 490 : 542) + (model.runningSoftwareTests ? 52 : 0))
        .font(DesignTokens.Font.body)
        .foregroundColor(DesignTokens.Text.primary)
        .background(DesignTokens.Surface.window)
        .buttonStyle(NativeButtonStyle())
        .onExitCommand { presentationMode.wrappedValue.dismiss() }
        .sheet(item: $detailRequest) { request in
            ResultDetails(row: request.row, softwareRatio: request.softwareRatio)
                .background(DesignTokens.Surface.window)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(DesignTokens.Font.title2)
                .foregroundColor(.codecAccent)
                .accessibilityHidden(true)
            Text("软件对照").font(DesignTokens.Font.title2)
            Spacer(minLength: 8)
            Button {
                model.startAllSoftwareTests()
            } label: {
                Label("运行 6 项软件", systemImage: "play.fill")
            }
            .disabled(!model.canRun)
            .accessibilityIdentifier("software-run-all")
            .help("运行六项软件编码与解码测试")

            Button {
                model.startAllSoftwareComparisons()
            } label: {
                Label("运行 6 组软硬件对照", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(NativeButtonStyle(prominent: true))
            .disabled(!model.canRun)
            .accessibilityIdentifier("software-compare-all")
            .help("同一轮运行六项硬件测试和对应的六项软件基准")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var matrix: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("软件编码")
                .font(DesignTokens.Font.title3)
            HStack(spacing: 10) {
                ForEach(["1080p", "4K"], id: \.self) { resolution in
                    if let testCase = SoftwareComparisonCase.find(
                        group: "编码", codec: "H.264", resolution: resolution
                    ) {
                        softwareCell(testCase)
                    }
                }
            }
            .frame(height: 84)

            Hairline()

            HStack {
                Text("软件解码")
                    .font(DesignTokens.Font.title3)
                Spacer(minLength: 8)
                Text("同一固定码流")
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
            }
            ForEach(["1080p", "4K"], id: \.self) { resolution in
                HStack(spacing: 10) {
                    ForEach(["H.264", "HEVC"], id: \.self) { codec in
                        if let testCase = SoftwareComparisonCase.find(
                            group: "解码", codec: codec, resolution: resolution
                        ) {
                            softwareCell(testCase)
                        }
                    }
                }
                .frame(height: 84)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("H.264 与 HEVC 软件测试矩阵"))
    }

    private var runProgress: some View {
        HStack(spacing: 10) {
            ProgressView(value: model.progress)
                .frame(width: 120)
                .accessibilityLabel("软件测试进度")
            Text(String(format: "%.0f%%", model.progress * 100))
                .font(DesignTokens.Font.small.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
            Text(model.status.isEmpty ? "正在运行软件测试…" : model.status)
                .font(DesignTokens.Font.small)
                .foregroundColor(DesignTokens.Text.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.cancel()
            } label: {
                Label(model.cancelRequested ? "等待取消" : "取消测试", systemImage: "stop.fill")
            }
            .disabled(model.cancelRequested)
            .keyboardShortcut(".", modifiers: .command)
            .accessibilityIdentifier("software-cancel")
        }
        .modifier(PanelStyle(padding: 9))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("software-comparison-progress")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(selectedCaseID == nil
                 ? "整机 CPU 含系统编解码服务及后台活动 · 点选卡片查看单项操作"
                 : "整机 CPU 含系统编解码服务及后台活动")
                .font(DesignTokens.Font.small)
                .foregroundColor(DesignTokens.Text.secondary)
                .lineLimit(1)
                .help(systemCPUUsageHelp)
            Spacer()
            Button("完成") { presentationMode.wrappedValue.dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("software-comparison-close")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func softwareCell(_ testCase: SoftwareComparisonCase) -> some View {
        let results = model.results
        let plannedIDs = model.displayedCaseIDs
        let softwareRow = uniqueResult(testCase.softwareID, results: results, plannedIDs: plannedIDs)
        let hardwareRow = uniqueResult(testCase.hardwareID, results: results, plannedIDs: plannedIDs)
        let ratio = pairedRatio(softwareRow: softwareRow, hardwareRow: hardwareRow)
        let isSelected = selectedCaseID == testCase.softwareID
        let spokenResult = [
            ratio.map { String(format: "硬件 FPS 除以软件 FPS，%.2f 倍", $0) },
            "软件 \(resultValue(softwareRow))",
            softwareStatus(softwareRow),
            softwareRow.map(systemCPUUsageLabel),
            "硬件 \(hardwareValue(hardwareRow))",
            hardwareRow.map(systemCPUUsageLabel)
        ].compactMap { $0 }.joined(separator: "，")

        return Button {
            selectedCaseID = isSelected ? nil : testCase.softwareID
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(testCase.item)
                        .font(DesignTokens.Font.body.weight(.semibold))
                    Spacer(minLength: 2)
                    if let ratio {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("硬件 / 软件 FPS")
                                .foregroundColor(DesignTokens.Text.secondary)
                            Text(String(format: "%.2f×", ratio))
                                .font(DesignTokens.Font.small.monospacedDigit().weight(.semibold))
                        }
                        .font(DesignTokens.Font.small)
                        .help(testCase.group == "编码"
                              ? "硬件 FPS 除以软件 FPS。两路编码画质可能不同。"
                              : "硬件 FPS 除以软件 FPS。两路解码使用同一份固定码流。")
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(resultValue(softwareRow))
                        .font(DesignTokens.Font.title3.monospacedDigit())
                        .lineLimit(1)
                    Text(softwareStatus(softwareRow))
                        .font(DesignTokens.Font.small)
                        .foregroundColor(softwareStatusColor(softwareRow))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let softwareRow {
                        Text(systemCPUUsageLabel(softwareRow))
                            .font(DesignTokens.Font.small.monospacedDigit())
                            .foregroundColor(DesignTokens.Text.secondary)
                            .lineLimit(1)
                            .help(systemCPUUsageHelp)
                            .accessibilityIdentifier("software-cpu-\(testCase.softwareID)")
                    }
                }

                HStack(spacing: 5) {
                    Text("硬件")
                        .foregroundColor(DesignTokens.Text.secondary)
                    Text(hardwareValue(hardwareRow))
                        .foregroundColor(DesignTokens.Text.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 2)
                    if let hardwareRow {
                        Text(systemCPUUsageLabel(hardwareRow))
                            .font(DesignTokens.Font.small.monospacedDigit())
                            .foregroundColor(DesignTokens.Text.secondary)
                            .lineLimit(1)
                            .help(systemCPUUsageHelp)
                            .accessibilityIdentifier("hardware-cpu-\(testCase.hardwareID)")
                    }
                }
                .font(DesignTokens.Font.small.monospacedDigit())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .modifier(PanelStyle(padding: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.corner)
            .stroke(isSelected ? DesignTokens.Interaction.accent : Color.clear,
                    lineWidth: isSelected ? 1.5 : 0)
            .allowsHitTesting(false))
        .accessibilityLabel(Text("\(testCase.group) · \(testCase.item)"))
        .accessibilityValue(Text(spokenResult))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(Text("选中后可在下方运行单项测试或查看详情"))
        .accessibilityIdentifier("software-select-\(testCase.softwareID)")
    }

    private var selectedTestCase: SoftwareComparisonCase? {
        guard let selectedCaseID = selectedCaseID else { return nil }
        return SoftwareComparisonCase.all.first { $0.softwareID == selectedCaseID }
    }

    private func selectedActionBar(for testCase: SoftwareComparisonCase) -> some View {
        let results = model.results
        let plannedIDs = model.displayedCaseIDs
        let softwareRow = uniqueResult(testCase.softwareID, results: results, plannedIDs: plannedIDs)
        let hardwareRow = uniqueResult(testCase.hardwareID, results: results, plannedIDs: plannedIDs)
        let ratio = pairedRatio(softwareRow: softwareRow, hardwareRow: hardwareRow)

        return HStack(spacing: 8) {
            Text("\(testCase.group) · \(testCase.item)")
                .font(DesignTokens.Font.small.weight(.semibold))
                .lineLimit(1)
                .accessibilityIdentifier("software-selected-title")
            Spacer(minLength: 4)
            Button {
                model.startSingle(testCase.softwareID)
            } label: {
                Label("单跑软件", systemImage: "play.fill")
            }
            .disabled(!model.canRun)
            .accessibilityIdentifier("software-run-selected")

            Button {
                model.startSoftwareComparison(caseID: testCase.softwareID)
            } label: {
                Label("单项对照", systemImage: "arrow.left.arrow.right")
            }
            .disabled(!model.canRun)
            .accessibilityIdentifier("software-compare-selected")

            Button("软件详情") {
                if let softwareRow { openDetails(softwareRow, softwareRatio: ratio) }
            }
            .disabled(softwareRow == nil)
            .accessibilityIdentifier("software-selected-software-detail")

            Button("硬件详情") {
                if let hardwareRow { openDetails(hardwareRow, softwareRatio: ratio) }
            }
            .disabled(hardwareRow == nil)
            .accessibilityIdentifier("software-selected-hardware-detail")
        }
        .font(DesignTokens.Font.small)
        .modifier(PanelStyle(padding: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("所选测试操作"))
    }

    private func uniqueResult(_ id: String, results: [BenchRow], plannedIDs: Set<String>) -> BenchRow? {
        guard plannedIDs.contains(id) else { return nil }
        let matches = results.filter { $0.id == id }
        return matches.count == 1 ? matches[0] : nil
    }

    private func pairedRatio(softwareRow: BenchRow?, hardwareRow: BenchRow?) -> Double? {
        guard let softwareRow, let hardwareRow,
              hardwareRow.group != "解码" || hardwareRow.decodeFixtureEvidence != nil else { return nil }
        return hardwareRow.throughputRatio(comparedTo: softwareRow)
    }

    private func resultValue(_ row: BenchRow?) -> String {
        guard let row, row.hasValidMeasurement else { return "— FPS" }
        return String(format: "%.1f FPS", row.fps)
    }

    private func hardwareValue(_ row: BenchRow?) -> String {
        guard let row else { return "尚无本轮结果" }
        guard row.hasValidMeasurement else { return row.status.rawValue }
        return String(format: "%.1f FPS", row.fps)
    }

    private func softwareStatus(_ row: BenchRow?) -> String {
        guard let row else { return "尚未测试" }
        return CodecPresentation.classification(row).0
    }

    private func softwareStatusColor(_ row: BenchRow?) -> Color {
        guard let row else { return DesignTokens.Text.secondary }
        return CodecPresentation.classification(row).1
    }

    private var systemCPUUsageHelp: String {
        "测量期间的整机 CPU 平均占用，包含测试 XPC 工作进程、系统编解码服务及其他后台活动。"
    }

    private func systemCPUUsageLabel(_ row: BenchRow) -> String {
        guard row.status != .notTested else { return "整机 CPU 待测" }
        guard let value = row.statistics?.systemCPUUsagePercent, value.isFinite, value >= 0 else {
            return "整机 CPU 未采集"
        }
        return "整机 CPU \(formattedCPUPercent(value))"
    }

    private func formattedCPUPercent(_ value: Double) -> String {
        if value > 0, value < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", value)
    }

    private func openDetails(_ row: BenchRow, softwareRatio: Double?) {
        detailRequest = SoftwareDetailRequest(row: row, softwareRatio: softwareRatio)
    }
}

private struct SoftwareComparisonCase: Identifiable {
    let group: String
    let item: String
    let softwareID: String
    let hardwareID: String

    var id: String { softwareID }

    static let all = CodecTestPlan.cases.compactMap { testCase -> Self? in
        guard CodecTestPlan.softwareCaseIDs.contains(testCase.id),
              let hardwareID = CodecTestPlan.hardwareComparisonCaseID(forSoftwareCaseID: testCase.id) else {
            return nil
        }
        return Self(group: testCase.group, item: testCase.item,
                    softwareID: testCase.id, hardwareID: hardwareID)
    }

    static func find(group: String, codec: String, resolution: String) -> Self? {
        let item = "\(codec) \(resolution)"
        return all.first { $0.group == group && $0.item == item }
    }
}

private struct SoftwareDetailRequest: Identifiable {
    let row: BenchRow
    let softwareRatio: Double?
    var id: String { row.id }
}
