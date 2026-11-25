import SwiftUI

/// The software baselines are opt-in because the HEVC encode case is intentionally slow.
struct SoftwareComparisonView: View {
    @ObservedObject var model: TestModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var detailRequest: SoftwareDetailRequest?

    private var softwareCaseIDs: Set<String> { Set(SoftwareComparisonCase.all.map(\.softwareID)) }
    private var showsRunProgress: Bool {
        guard model.running else { return false }
        guard let planned = model.plannedCaseIDs else { return model.status.contains("软件") }
        return !softwareCaseIDs.isDisjoint(with: planned)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    if model.running {
                        runProgress
                    }
                    Text("可单独运行软件路径，或在同一轮测量对应的硬件与软件。")
                        .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                    ForEach(SoftwareComparisonCase.all) { testCase in
                        softwareCard(testCase)
                    }
                }
                .padding(18)
            }
            Hairline()
            footer
        }
        .frame(width: 760, height: 650)
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
            Image(systemName: "cpu").font(DesignTokens.Font.title2)
                .foregroundColor(.codecAccent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("软件对照").font(DesignTokens.Font.title2)
                Text("按需运行 · 与硬件测试分开计量")
                    .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var runProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView(value: model.progress).frame(width: 120)
                Text(String(format: "%.0f%%", model.progress * 100))
                    .font(DesignTokens.Font.small.monospacedDigit())
                Spacer()
                Button {
                    model.cancel()
                } label: {
                    Label(model.cancelRequested ? "等待安全取消…" : "取消测试", systemImage: "stop.fill")
                }
                .disabled(model.cancelRequested)
                .keyboardShortcut(".", modifiers: .command)
            }
            Text(model.status.isEmpty ? (showsRunProgress ? "正在测量软件对照…" : "其他测试正在运行…") : model.status)
                .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(PanelStyle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("software-comparison-progress")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("结果会进入同一份测试历史与报告。")
                .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
            Spacer()
            Button("完成") { presentationMode.wrappedValue.dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("software-comparison-close")
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
    }

    private func softwareCard(_ testCase: SoftwareComparisonCase) -> some View {
        let softwareRow = model.results.first(where: { $0.id == testCase.softwareID })
        let hardwareRow = model.results.first(where: { $0.id == testCase.hardwareID })
        let ratio = hardwareRow?.softwareRatio(in: model.results)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(testCase.item).font(DesignTokens.Font.title3)
                StatusPill(text: testCase.group == "编码" ? "软件编码" : "软件解码",
                           color: DesignTokens.Status.info)
                Spacer(minLength: 8)
                Text(testCase.group).font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
            }
            if testCase.group == "编码" && testCase.item == "HEVC 1080p" {
                Text("此项软件编码耗时较长，请预留时间；运行中可取消。")
                    .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
            }

            if let softwareRow {
                measuredResult(softwareRow, pathTitle: "软件实际结果")
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "circle.dotted").accessibilityHidden(true)
                    Text("尚无本轮软件结果")
                        .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                }
            }

            if let hardwareRow {
                Hairline()
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("配对硬件结果").font(DesignTokens.Font.small)
                            .foregroundColor(DesignTokens.Text.secondary)
                        Text(hardwareRow.hasValidMeasurement
                             ? String(format: "%.1f FPS", hardwareRow.fps) : hardwareRow.status.rawValue)
                            .font(DesignTokens.Font.body.monospacedDigit().weight(.medium))
                        Text(CodecPresentation.classification(hardwareRow).0)
                            .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if let ratio {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(String(format: "%.2f×", ratio))
                                .font(DesignTokens.Font.title3.monospacedDigit())
                            Text(testCase.group == "编码" ? "各自画质设置的吞吐比" : "同一固定码流")
                                .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                        }
                    }
                    Button("硬件详情…") { openDetails(hardwareRow, softwareRatio: ratio) }
                        .accessibilityIdentifier("software-hardware-details-\(testCase.softwareID)")
                }
            }

            HStack(spacing: 8) {
                Button {
                    model.startSingle(testCase.softwareID)
                } label: {
                    Label("单跑软件", systemImage: "play.fill")
                }
                .disabled(!model.canRun || model.running)
                .accessibilityIdentifier("software-single-\(testCase.softwareID)")
                .help("只运行此项软件基准")

                Button {
                    model.startSoftwareComparison(caseID: testCase.softwareID)
                } label: {
                    Label("软硬件对照", systemImage: "arrow.left.arrow.right")
                }
                .disabled(!model.canRun || model.running)
                .accessibilityIdentifier("software-compare-\(testCase.softwareID)")
                .help("在同一轮中运行对应硬件与软件基准")

                Spacer()

                if let softwareRow {
                    Button("软件详情…") { openDetails(softwareRow, softwareRatio: nil) }
                        .accessibilityIdentifier("software-details-\(testCase.softwareID)")
                }
            }
        }
        .modifier(PanelStyle())
    }

    @ViewBuilder
    private func measuredResult(_ row: BenchRow, pathTitle: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pathTitle).font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(row.hasValidMeasurement ? String(format: "%.1f", row.fps) : "—")
                        .font(DesignTokens.Font.title1.monospacedDigit())
                    Text("FPS").font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                let classification = CodecPresentation.classification(row)
                StatusPill(text: classification.0, color: classification.1)

            }
            Spacer(minLength: 0)
        }
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
        guard let hardwareID = CodecTestPlan.hardwareComparisonCaseID(forSoftwareCaseID: testCase.id) else {
            return nil
        }
        return Self(group: testCase.group, item: testCase.item,
                    softwareID: testCase.id, hardwareID: hardwareID)
    }
}

private struct SoftwareDetailRequest: Identifiable {
    let row: BenchRow
    let softwareRatio: Double?
    var id: String { row.id }
}
