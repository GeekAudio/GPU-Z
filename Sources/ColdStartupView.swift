import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let coldStartupSize = NSSize(width: 600, height: 572)

final class ColdStartupIndicator: ObservableObject {
    @Published var report: ColdStartupReport?

    func clear() { report = nil }
}

extension AppDelegate: NSMenuItemValidation {
    private var canOpenColdStartupCheck: Bool {
        guard let window, let model else { return false }
        return window.attachedSheet == nil && !model.running && !model.refreshing && !coldStartupRunning
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(showColdStartupCheck(_:)) || canOpenColdStartupCheck
    }

    @objc func showColdStartupCheck(_ sender: Any?) {
        guard canOpenColdStartupCheck, let window else { return }

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: coldStartupSize),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "冷启动检测"
        panel.contentView = NSHostingView(rootView: ColdStartupView(
            didFinish: { [weak self] report in
                self?.coldStartup.report = report
                self?.coldStartupRunning = false
            },
            close: { [weak window, weak panel] in
                guard let panel else { return }
                window?.endSheet(panel)
            }
        ))
        coldStartupRunning = true
        window.beginSheet(panel)
    }
}

private struct ColdStartupView: View {
    let didFinish: (ColdStartupReport) -> Void
    let close: () -> Void
    @State private var started = false
    @State private var report: ColdStartupReport?
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            guide
                .padding(20)
            Hairline()
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.cases) { result in
                            resultRow(result)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            } else {
                ProgressView("正在检测首次硬件会话…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Hairline()
            HStack {
                if let exportError {
                    Text(exportError).foregroundColor(DesignTokens.Status.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let report {
                    Text("通过 \(report.passedCount)/\(report.cases.count) 项")
                        .foregroundColor(DesignTokens.Text.secondary)
                }
                Spacer(minLength: 10)
                Button("导出 JSON…", action: export)
                    .accessibilityIdentifier("cold-check-export")
                    .disabled(report == nil)
                Button("完成", action: close)
                    .accessibilityIdentifier("cold-check-close")
                    .keyboardShortcut(.defaultAction)
                    .disabled(report == nil)
            }
            .padding(16)
        }
        .frame(width: coldStartupSize.width, height: coldStartupSize.height)
        .font(DesignTokens.Font.body)
        .foregroundColor(DesignTokens.Text.primary)
        .background(DesignTokens.Surface.window)
        .buttonStyle(NativeButtonStyle(prominent: false))
        .onAppear(perform: start)
        .onExitCommand { if report != nil { close() } }
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("冷启动检测").font(DesignTokens.Font.title2)
                Text("检查新进程第一次请求硬件编解码时，能否成功建立会话并输出完整帧。")
                Text("H.264 和 HEVC 的 1080p 硬编、硬解各用一个独立进程。")
                    .foregroundColor(DesignTokens.Text.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                guideRow("何时使用", "应用刚打开时硬件加速不可用，或稍后才恢复。")
                guideRow("怎么看结果", """
                    通过数表示成功完成首次会话的项目数。
                    若常规硬件测试通过、这里失败，优先排查首次会话的初始化。
                    """)
            }
            .modifier(PanelStyle())
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func guideRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(DesignTokens.Font.body.weight(.semibold))
                .frame(width: 76, alignment: .leading)
            Text(detail)
                .foregroundColor(DesignTokens.Text.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resultRow(_ result: ColdStartupCaseReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(result.name).font(DesignTokens.Font.body.weight(.semibold))
                Spacer()
                Text(result.status.rawValue).font(DesignTokens.Font.small)
            }
            if let row = result.row {
                DisclosureGroup("技术详情") {
                    VStack(alignment: .leading, spacing: 6) {
                        if result.status == .sessionUnavailable, let status = row.failureOSStatus {
                            let reason = CodecBench.sessionCreationFailureReason(status)
                            Text(reason.explanation)
                                .font(DesignTokens.Font.body)
                                .foregroundColor(DesignTokens.Text.primary)
                            Text(verbatim: "OSStatus \(status)")
                            if let symbol = reason.symbol {
                                Text(symbol).font(.system(size: 11, design: .monospaced))
                            }
                            Text(CodecBench.sessionCreationFailureContext)
                        } else {
                            Text(row.detail.replacingOccurrences(of: "；", with: "\n"))
                        }
                        if !row.encoderID.isEmpty {
                            Text("编码器 ID").fontWeight(.semibold)
                            Text(row.encoderID)
                        }
                        if let quality = row.encoderQualityEvidence {
                            Text("画质证据").fontWeight(.semibold)
                            Text(quality.reportLines.joined(separator: "\n"))
                        }
                        if let fixture = row.decodeFixtureEvidence {
                            Text("固定码流").fontWeight(.semibold)
                            Text(fixture.identifier)
                            Text("SHA-256")
                            Text(fixture.sha256).font(.system(size: 11, design: .monospaced))
                        }
                    }
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .font(DesignTokens.Font.small)
                .foregroundColor(DesignTokens.Text.secondary)
            } else if let error = result.error {
                Text(error).foregroundColor(DesignTokens.Text.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(PanelStyle())
    }

    private func start() {
        guard !started else { return }
        started = true
        DispatchQueue.global(qos: .userInitiated).async {
            let completed = ColdStartupCheck.run()
            DispatchQueue.main.async {
                report = completed
                didFinish(completed)
            }
        }
    }

    private func export() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "GPU-Z-cold-\(SelfTest.stamp()).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ColdStartupCheck.jsonData(report).write(to: url, options: .atomic)
                exportError = nil
            } catch {
                exportError = "导出失败，\(error.localizedDescription)"
            }
        }
    }
}
