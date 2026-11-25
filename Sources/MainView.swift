import SwiftUI
import AppKit

/// The fixed hardware matrix, environment snapshot, and run controls share one dashboard.
struct MainView: View {
    @ObservedObject var model: TestModel
    @ObservedObject var coldStartup: ColdStartupIndicator
    let onColdStartupCheck: (() -> Void)?
    @State private var selectedID = CodecPresentation.plan[0].id
    @State private var sheet: DashboardSheet?

    init(model: TestModel, coldStartup: ColdStartupIndicator = ColdStartupIndicator(),
         onColdStartupCheck: (() -> Void)? = nil) {
        _model = ObservedObject(wrappedValue: model)
        _coldStartup = ObservedObject(wrappedValue: coldStartup)
        self.onColdStartupCheck = onColdStartupCheck
    }

    private enum DashboardSheet: Identifiable {
        case environment, methods, feedback, history, softwareComparison, result(BenchRow)
        var id: String {
            switch self {
            case .environment: return "environment"
            case .methods: return "methods"
            case .feedback: return "feedback"
            case .history: return "history"
            case .softwareComparison: return "software-comparison"
            case .result(let row): return row.id
            }
        }
    }
    private var plannedRows: [BenchRow] {
        CodecPresentation.plan.map { planned in model.results.first { $0.id == planned.id } ?? planned }
    }
    private var selected: BenchRow? { model.results.first { $0.id == selectedID } }
    private var focusedCase: BenchRow? { plannedRows.first { $0.id == selectedID } }
    private var hardwarePlan: [BenchRow] { CodecPresentation.plan.filter { CodecTestPlan.hardwareCaseIDs.contains($0.id) } }
    private var overviewCaseIDs: Set<String> { model.displayedCaseIDs.intersection(CodecTestPlan.hardwareCaseIDs) }
    private var overviewPlan: [BenchRow] { hardwarePlan.filter { overviewCaseIDs.contains($0.id) } }
    private var overviewRows: [BenchRow] { model.results.filter { overviewCaseIDs.contains($0.id) } }
    private var overviewCompleted: Int {
        overviewRows.filter { $0.status != .notTested && $0.status != .cancelled }.count
    }
    private var hardwareSelectionCount: Int { model.selectedCaseIDs.intersection(CodecTestPlan.hardwareCaseIDs).count }
    private var coldStartupSummary: String {
        guard let report = coldStartup.report else { return "未测" }
        return "\(report.passedCount)/\(report.cases.count)"
    }
    private var startTitle: String {
        if hardwareSelectionCount != CodecTestPlan.hardwareCaseIDs.count { return "测试所选硬件" }
        return model.tested ? "重新测试" : "测试硬件"
    }
    var body: some View {
        VStack(spacing: 8) {
            header
            TestOverview(rows: overviewRows, plan: overviewPlan, completed: overviewCompleted, total: overviewPlan.count,
                         finished: model.finished && !overviewPlan.isEmpty,
                         cancelled: model.wasCancelled && !overviewPlan.isEmpty,
                         running: model.running && !overviewPlan.isEmpty,
                         coldStartupSummary: coldStartupSummary).frame(height: 66)
            HStack(alignment: .top, spacing: 12) {
                matrix.frame(maxWidth: .infinity, maxHeight: .infinity)
                environment.frame(width: DashboardLayout.environmentWidth).frame(maxHeight: .infinity)
            }.frame(minHeight: 352, maxHeight: .infinity)
            selectedEvidence.frame(height: 60)
            footer
        }
        .padding(20)
        .frame(minWidth: 840, minHeight: 660)
        .background(Color.codecBackground).font(DesignTokens.Font.body).lineSpacing(2)
        .foregroundColor(.txt).accentColor(.codecAccent)

        .sheet(item: $sheet) { item in
            switch item {
            case .environment: DetailWindow(title: "完整环境与驱动证据") { EnvironmentEvidenceContent(model: model) }
            case .methods: DetailWindow(title: "测量方法") { MeasurementMethodsView() }
            case .softwareComparison: SoftwareComparisonView(model: model)
            case .result(let row): ResultDetails(row: row, softwareRatio: row.softwareRatio(in: model.results)).background(Color.codecBackground)
            case .history:
                let store = model.diagnosticStore
                TestHistoryView(loadHistory: model.testHistoryLoader(), clearHistory: { try store?.clearTestHistory() })
            case .feedback:
                FeedbackView(refreshHistory: model.feedbackHistoryLoader(), deleteDiagnostic: { try model.deleteDiagnostic($0) },
                             clearHistory: { try model.diagnosticStore?.clear() }, storageNotice: model.diagnosticLogError)

            }
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle").font(DesignTokens.Font.title2).foregroundColor(.codecAccent)
            Text("GPU-Z").font(DesignTokens.Font.title2)
            Text("视频编解码诊断").font(DesignTokens.Font.small).foregroundColor(.sub)
            Spacer(minLength: 12)
            Button(action: {
                coldStartup.clear()
                model.refresh()
            }) { Label("刷新环境", systemImage: "arrow.clockwise") }
                .buttonStyle(NativeButtonStyle()).disabled(model.running || model.refreshing)
                .accessibilityIdentifier("environment-refresh")
                .help("重新采集环境并清空本轮结果")
            Button(action: { onColdStartupCheck?() }) {
                Label("冷启动检测", systemImage: "power")
            }
            .buttonStyle(NativeButtonStyle())
            .disabled(!model.canRun || onColdStartupCheck == nil)
            .accessibilityIdentifier("cold-start-check")
            .help("每项 1080p 测试都在全新进程中验证首次硬件会话")
            if model.running {
                Button(action: { model.cancel() }) {
                    Label(model.cancelRequested ? "等待安全取消…" : "取消测试", systemImage: "stop.fill")
                }.buttonStyle(NativeButtonStyle()).disabled(model.cancelRequested)
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button(action: startHardwareTests) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(startTitle)
                            .font(.system(size: 13, weight: .medium))
                    }
                }.buttonStyle(NativeButtonStyle(prominent: true)).disabled(!model.canRun || hardwareSelectionCount == 0)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(Text(startTitle))
                    .accessibilityIdentifier("hardware-test-start")
                    .help("运行勾选的 \(hardwareSelectionCount) 项硬件测试（⌘↩）。软件对照可单独运行")
            }
        }.frame(height: 28)
    }
    private var matrix: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("编解码测试").font(DesignTokens.Font.title3)
                Spacer()
                Button("软件对照…") { sheet = .softwareComparison }
                    .buttonStyle(NativeButtonStyle())
                    .disabled(model.refreshing || (model.running && !model.runningSoftwareTests))
                    .accessibilityIdentifier("software-comparison")
                    .help("按需运行软件编码与解码对照")
                Text("已选 \(hardwareSelectionCount)/\(CodecTestPlan.hardwareCaseIDs.count)").font(DesignTokens.Font.small).foregroundColor(.sub)
                Button("全选") { model.selectCases(CodecTestPlan.hardwareCaseIDs) }
                    .buttonStyle(BorderlessButtonStyle()).disabled(model.running)
                Button("取消全选") { model.selectCases([]) }
                    .buttonStyle(BorderlessButtonStyle()).disabled(model.running)
                Menu {
                    selectionPreset("仅编码") { $0.group == "编码" }
                    selectionPreset("仅解码") { $0.group == "解码" }
                    Button("反选") { model.selectCases(CodecTestPlan.hardwareCaseIDs.subtracting(model.selectedCaseIDs)) }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle").foregroundColor(.sub)
                }.menuStyle(BorderlessButtonMenuStyle()).fixedSize().disabled(model.running)
                    .accessibilityLabel("按类型选择测试项目")
            }.font(DesignTokens.Font.small).frame(height: 28)
            HardwareMatrixView(
                rows: hardwarePlan.map { planned in model.results.first { $0.id == planned.id } ?? planned },
                selectedID: selectedID,
                selectedCaseIDs: model.selectedCaseIDs,
                selectionEnabled: !model.running,
                activeCaseID: activeHardwareCaseID,
                phase: model.status.components(separatedBy: " · ").last ?? "正在准备测量…",
                canRunSingle: model.canRun,
                setIncluded: { model.setCase($0, included: $1) },
                runSingle: { id in selectedID = id; model.startSingle(id) },
                select: { selectedID = $0.id }
            )
        }.frame(maxHeight: .infinity, alignment: .top).modifier(PanelStyle(padding: 12))
    }
    private var activeHardwareCaseID: String? {
        guard model.running else { return nil }
        return hardwarePlan.first { model.status.hasPrefix($0.group + " " + $0.item + " · " + $0.mode) }?.id
    }
    private func selectionPreset(_ title: String, matching predicate: @escaping (BenchRow) -> Bool) -> some View {
        Button(title) { model.selectCases(Set(hardwarePlan.filter(predicate).map(\.id))) }
    }
    private func startHardwareTests() {
        model.selectCases(model.selectedCaseIDs.intersection(CodecTestPlan.hardwareCaseIDs))
        model.start()
    }
    private var environment: some View {
        DashboardEnvironmentView(
            gpu: model.gpu,
            driver: model.driver,
            system: model.env.first { $0.key == "系统" }?.value,
            cpu: model.env.first { $0.key == "CPU" }?.value,
            encoderCount: model.nvidiaEncoders.count,
            componentStatus: model.env.first { $0.key == "组件文件存在性" }?.value,
            refreshing: model.refreshing,
            openDetails: { sheet = .environment }
        )
    }
    private var selectedEvidenceSummary: String {
        guard let selected else { return "可单独运行当前项，或勾选后随本轮运行。" }
        if let failure = CodecPresentation.failureSummary(selected) { return failure }
        let identity = CodecPresentation.classification(selected).0
        if selected.hasValidMeasurement && !selected.gpuName.isEmpty {
            return "\(identity) · \(selected.gpuName)"
        }
        return identity
    }
    private var selectedEvidence: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(focusedCase.map { $0.group + " · " + $0.item } ?? "测试详情")
                    .font(DesignTokens.Font.body.weight(.semibold)).lineLimit(1)
                Text(selectedEvidenceSummary)
                    .font(DesignTokens.Font.small).foregroundColor(.sub).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("单独测试") { if let focusedCase { model.startSingle(focusedCase.id) } }
                .buttonStyle(NativeButtonStyle()).disabled(!model.canRun || focusedCase == nil)
                .help(focusedCase.map { "仅运行：" + $0.group + " · " + $0.item + " · " + $0.mode } ?? "先选择一张卡片")
            Button("证据与详情…") { if let selected { sheet = .result(selected) } }
                .buttonStyle(NativeButtonStyle()).disabled(selected == nil)
        }.modifier(PanelStyle(padding: 8))
    }
    private var footer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(model.status.isEmpty ? "硬件测试预热后测量三次，取中位数。" : model.status)
                    .font(DesignTokens.Font.small).foregroundColor(.sub).lineLimit(1).help(model.status)
                Spacer(minLength: 0)
                if model.running { Text(String(format: "%.0f%%", model.progress * 100)).font(DesignTokens.Font.small.monospacedDigit()).foregroundColor(.sub) }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.codecInset)
                    Capsule().fill(Color.codecAccent).frame(width: geometry.size.width * min(1, max(0, model.progress)))
                }
            }.frame(height: 4)
                .accessibilityElement().accessibilityLabel(Text("测试进度"))
                .accessibilityValue(Text(String(format: "%.0f%%", model.progress * 100)))
            HStack(spacing: 12) {
                Button("测量方法") { sheet = .methods }.buttonStyle(NativeButtonStyle())
                Button("日志与反馈") { sheet = .feedback }.buttonStyle(NativeButtonStyle())
                    .accessibilityIdentifier("diagnostic-feedback")
                Button("测试历史") { sheet = .history }.buttonStyle(NativeButtonStyle()).disabled(model.running || model.refreshing)
                    .accessibilityIdentifier("test-history")
                Text(model.diagnosticLogError == nil ? "日志仅存本机 · 反馈前可预览" : "日志留存异常，点击反馈查看")
                    .font(DesignTokens.Font.small).foregroundColor(.sub).lineLimit(1)
                Spacer(minLength: 0)
                Link(destination: GitHubFeedback.repositoryURL) {
                    Label("GitHub", systemImage: "arrow.up.right.square")
                        .foregroundColor(DesignTokens.Text.secondary)
                }.fixedSize().help("查看开源代码、版本和问题反馈")
                    .accessibilityLabel("在 GitHub 打开 GPU-Z 开源仓库")
                Menu {
                    Button("导出文本 TXT") { model.exportReport() }
                    Button("导出完整 JSON") { model.exportReport(asJSON: true) }
                } label: {
                    Label {
                        Text(model.results.isEmpty ? "导出环境" : "导出报告")
                            .foregroundColor(DesignTokens.Text.secondary)
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(DesignTokens.Text.secondary)
                    }
                }
                    .modifier(NativeMenuStyle())
                    .fixedSize().disabled(!model.canExport)
            }.font(DesignTokens.Font.small)
        }.frame(height: 54)
    }
}
