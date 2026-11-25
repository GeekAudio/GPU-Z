import SwiftUI

struct DashboardEnvironmentView: View {
    let gpu: String
    let driver: String
    let system: String?
    let cpu: String?
    let encoderCount: Int
    let componentStatus: String?
    let refreshing: Bool
    let openDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("本机环境").font(DesignTokens.Font.title3)
                Spacer(minLength: 4)
                if refreshing {
                    ProgressView().scaleEffect(0.55).frame(width: 14, height: 14)
                        .accessibilityLabel(Text("正在采集环境"))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("GPU")
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
                Text(CodecPresentation.displayGPUName(gpu))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .help(gpu)
            }

            Hairline()
            VStack(alignment: .leading, spacing: 13) {
                field("NullMoth", driver)
                field("系统", system ?? pending)
                field("处理器", cpu.map(Self.displayProcessor) ?? pending, source: cpu)
            }

            Spacer(minLength: 0)
            Hairline()
            VStack(alignment: .leading, spacing: 13) {
                field("NVENC", refreshing && encoderCount == 0 ? pending : "已注册 \(encoderCount) 个")
                field("组件文件", componentStatus ?? pending)
            }

            Spacer(minLength: 2)
            Hairline()
            Button(action: openDetails) {
                HStack {
                    Text("环境详情").font(DesignTokens.Font.body.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(DesignTokens.Font.small.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundColor(DesignTokens.Text.secondary)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("environment-details")
            .help("查看完整环境、设备名称和编码器注册")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(PanelStyle())
    }

    private var pending: String { refreshing ? "正在读取…" : "未记录" }

    private static func displayProcessor(_ name: String) -> String {
        name.replacingOccurrences(of: "(R)", with: "")
            .replacingOccurrences(of: "(TM)", with: "")
            .replacingOccurrences(of: #"^\d+(st|nd|rd|th) Gen "#, with: "", options: .regularExpression)
    }

    private func field(_ title: String, _ value: String, source: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(DesignTokens.Font.small)
                .foregroundColor(DesignTokens.Text.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(DesignTokens.Font.body.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(source ?? value)
        .accessibilityElement(children: .combine)
    }
}
