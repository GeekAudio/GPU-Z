import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 434),
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
            VStack(alignment: .leading, spacing: 6) {
                Text("冷启动检测").font(DesignTokens.Font.title2)
                Text("每项 1080p 检测各用一个新进程请求首次硬件会话，事先不枚举 Metal 设备或编码器。")
                    .foregroundColor(DesignTokens.Text.secondary)
            }
            .padding(20)
            Hairline()
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(report.cases) { result in
                            resultRow(result)
                        }
                    }.padding(20)
                }
            } else {
                ProgressView("正在检测首次硬件会话…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Hairline()
            HStack {
                if let exportError {
                    Text(exportError).foregroundColor(DesignTokens.Status.warning)
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
        .frame(width: 600, height: 434)
        .font(DesignTokens.Font.body)
        .foregroundColor(DesignTokens.Text.primary)
        .background(DesignTokens.Surface.window)
        .buttonStyle(NativeButtonStyle(prominent: false))
        .onAppear(perform: start)
        .onExitCommand { if report != nil { close() } }
    }

    private func resultRow(_ result: ColdStartupCaseReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(result.name).font(DesignTokens.Font.body.weight(.semibold))
                Spacer()
                Text(result.status.rawValue).font(DesignTokens.Font.small)
            }
            if let row = result.row {
                Text(row.detail).foregroundColor(DesignTokens.Text.secondary)
                if !row.encoderID.isEmpty {
                    Text(row.encoderID).font(DesignTokens.Font.small)
                        .foregroundColor(DesignTokens.Text.secondary)
                }
                if let quality = row.encoderQualityEvidence {
                    DisclosureGroup("画质证据") {
                        Text(quality.reportLines.joined(separator: "\n"))
                            .font(DesignTokens.Font.small)
                            .foregroundColor(DesignTokens.Text.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
                if let fixture = row.decodeFixtureEvidence {
                    DisclosureGroup("固定码流") {
                        Text("\(fixture.identifier)\nSHA-256 \(fixture.sha256)")
                            .font(DesignTokens.Font.small)
                            .foregroundColor(DesignTokens.Text.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
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
