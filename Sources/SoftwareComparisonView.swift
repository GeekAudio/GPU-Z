import SwiftUI

/// Shows local results and runs the missing software or paired cases on request.
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
        let softwareCount = model.pendingComparisonCases(CodecTestPlan.softwareCaseIDs).count
        let comparisonCount = model.pendingComparisonCases(CodecTestPlan.softwareComparisonCaseIDs).count
        return HStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(DesignTokens.Font.title2)
                .foregroundColor(.codecAccent)
                .accessibilityHidden(true)
            Text("软解对照").font(DesignTokens.Font.title2)
            Spacer(minLength: 8)
            Button {
                model.startAllSoftwareTests()
            } label: {
                Label(softwareCount == 0 ? "软编和软解已测完" : "补测 \(softwareCount) 项软编解码", systemImage: "play.fill")
            }
            .disabled(!model.canRun || softwareCount == 0)
            .accessibilityIdentifier("software-run-all")
            .help("补测缺少有效成绩的软编和软解项目")

            Button {
                model.startAllSoftwareComparisons()
            } label: {
                Label(comparisonCount == 0 ? "对照已齐全" : "补齐 \(comparisonCount) 项对照",
                      systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(NativeButtonStyle(prominent: true))
            .disabled(!model.canRun || comparisonCount == 0)
            .accessibilityIdentifier("software-compare-all")
            .help("补测六组对照中缺少有效成绩的软硬件项目")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var matrix: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("软编")
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
                Text("软解")
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
        .accessibilityLabel(Text("软解对照测试矩阵"))
    }

    private var runProgress: some View {
        HStack(spacing: 10) {
            ProgressView(value: model.progress)
                .frame(width: 120)
                .accessibilityLabel("补测进度")
            Text(String(format: "%.0f%%", model.progress * 100))
                .font(DesignTokens.Font.small.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
            Text(model.status.isEmpty ? "正在补测…" : model.status)
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
                 ? "复用同一测试环境的成绩 · 点选卡片查看单项详情"
                 : "复用同一测试环境的成绩")
                .font(DesignTokens.Font.small)
                .foregroundColor(DesignTokens.Text.secondary)
                .lineLimit(1)
                .help("软硬件成绩可来自同一环境下的不同测试轮次。")
            Spacer()
            Button("完成") { presentationMode.wrappedValue.dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("software-comparison-close")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func softwareCell(_ testCase: SoftwareComparisonCase) -> some View {
        let softwareRow = model.comparisonResult(for: testCase.softwareID)
        let hardwareRow = model.comparisonResult(for: testCase.hardwareID)
        let ratio = pairedRatio(softwareRow: softwareRow, hardwareRow: hardwareRow)
        let isSelected = selectedCaseID == testCase.softwareID
        let paths = CodecPathLabels(group: testCase.group)
        let spokenResult = [
            ratio.map { "\(paths.hardware) FPS 除以\(paths.software) FPS，" + String(format: "%.2f 倍", $0) },
            "\(paths.software) \(measurementValue(softwareRow))",
            softwareStatus(softwareRow),
            softwareRow.map(systemCPUUsageLabel),
            "\(paths.hardware) \(measurementValue(hardwareRow))",
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
                            Text("\(paths.ratio) FPS")
                                .foregroundColor(DesignTokens.Text.secondary)
                            Text(String(format: "%.2f×", ratio))
                                .font(DesignTokens.Font.small.monospacedDigit().weight(.semibold))
                        }
                        .font(DesignTokens.Font.small)
                        .help(testCase.group == "编码"
                              ? "硬编 FPS 除以软编 FPS。成绩可来自不同轮次，两路编码画质可能不同。"
                              : "硬解 FPS 除以软解 FPS。成绩可来自不同轮次，两路解码使用同一份固定码流。")
                    }
                }

                measurementRow(paths.software, caseID: testCase.softwareID, row: softwareRow, isSoftware: true)
                measurementRow(paths.hardware, caseID: testCase.hardwareID, row: hardwareRow, isSoftware: false)
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

    private func measurementRow(_ title: String, caseID: String, row: BenchRow?, isSoftware: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundColor(DesignTokens.Text.secondary)
                .frame(width: 30, alignment: .leading)
            Text(measurementValue(row))
                .font((isSoftware ? DesignTokens.Font.title3 : DesignTokens.Font.body).monospacedDigit())
                .foregroundColor(isSoftware ? DesignTokens.Text.primary : DesignTokens.Text.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let row {
                Text(systemCPUUsageLabel(row))
                    .font(DesignTokens.Font.small.monospacedDigit())
                    .foregroundColor(DesignTokens.Text.secondary)
                    .lineLimit(1)
                    .help(systemCPUUsageHelp)
                    .accessibilityIdentifier("\(isSoftware ? "software" : "hardware")-cpu-\(caseID)")
            }
        }
        .font(DesignTokens.Font.small)
    }

    private var selectedTestCase: SoftwareComparisonCase? {
        guard let selectedCaseID = selectedCaseID else { return nil }
        return SoftwareComparisonCase.all.first { $0.softwareID == selectedCaseID }
    }

    private func selectedActionBar(for testCase: SoftwareComparisonCase) -> some View {
        let softwareRow = model.comparisonResult(for: testCase.softwareID)
        let hardwareRow = model.comparisonResult(for: testCase.hardwareID)
        let ratio = pairedRatio(softwareRow: softwareRow, hardwareRow: hardwareRow)
        let paths = CodecPathLabels(group: testCase.group)
        let softwarePending = !model.pendingComparisonCases([testCase.softwareID]).isEmpty
        let pairPending = !model.pendingComparisonCases([testCase.softwareID, testCase.hardwareID]).isEmpty

        return HStack(spacing: 8) {
            Text("\(testCase.group) · \(testCase.item)")
                .font(DesignTokens.Font.small.weight(.semibold))
                .lineLimit(1)
                .accessibilityIdentifier("software-selected-title")
            Spacer(minLength: 4)
            Button {
                model.startSoftwareTest(caseID: testCase.softwareID)
            } label: {
                Label("补测\(paths.software)", systemImage: "play.fill")
            }
            .disabled(!model.canRun || !softwarePending)
            .accessibilityIdentifier("software-run-selected")

            Button {
                model.startSoftwareComparison(caseID: testCase.softwareID)
            } label: {
                Label("补齐对照", systemImage: "arrow.left.arrow.right")
            }
            .disabled(!model.canRun || !pairPending)
            .accessibilityIdentifier("software-compare-selected")

            Button("\(paths.software)详情") {
                if let softwareRow { openDetails(softwareRow, softwareRatio: ratio) }
            }
            .disabled(softwareRow == nil)
            .accessibilityIdentifier("software-selected-software-detail")

            Button("\(paths.hardware)详情") {
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

    private func pairedRatio(softwareRow: BenchRow?, hardwareRow: BenchRow?) -> Double? {
        guard let softwareRow, let hardwareRow,
              hardwareRow.group != "解码" || hardwareRow.decodeFixtureEvidence != nil else { return nil }
        return hardwareRow.throughputRatio(comparedTo: softwareRow)
    }

    private func measurementValue(_ row: BenchRow?) -> String {
        guard let row else { return "未测试" }
        guard row.hasValidMeasurement else { return row.status == .passed ? "待验证" : row.status.rawValue }
        return String(format: "%.1f FPS", row.fps)
    }

    private func softwareStatus(_ row: BenchRow?) -> String {
        guard let row else { return "尚未测试" }
        return CodecPresentation.classification(row).0
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
