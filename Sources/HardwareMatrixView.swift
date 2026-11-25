import SwiftUI

/// The dashboard's primary matrix: four hardware workloads by codec, with every cell visible.
struct HardwareMatrixView: View {
    let rows: [BenchRow]
    let selectedID: String
    let selectedCaseIDs: Set<String>
    let selectionEnabled: Bool
    let activeCaseID: String?
    let phase: String
    let canRunSingle: Bool
    let setIncluded: (String, Bool) -> Void
    let runSingle: (String) -> Void
    let select: (BenchRow) -> Void

    private struct Band: Identifiable {
        let group: String
        let resolution: String
        var title: String { "\(group) · \(resolution)" }
        var id: String { "\(group)|\(resolution)" }
    }

    private let bands = [
        Band(group: "编码", resolution: "1080p"),
        Band(group: "编码", resolution: "4K"),
        Band(group: "解码", resolution: "1080p"),
        Band(group: "解码", resolution: "4K")
    ]
    private let codecs = ["H.264", "HEVC"]
    private let headingHeight: CGFloat = 18
    private let rowSpacing: CGFloat = 6
    private let rowLabelWidth: CGFloat = 78

    var body: some View {
        GeometryReader { geometry in
            let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let rowsHeight = geometry.size.height - headingHeight - rowSpacing * CGFloat(bands.count)
            let rowHeight = max(48, rowsHeight / CGFloat(bands.count))

            VStack(spacing: rowSpacing) {
                HStack(spacing: 8) {
                    Color.clear.frame(width: rowLabelWidth).accessibilityHidden(true)
                    ForEach(codecs, id: \.self) { codec in
                        Text(codec)
                            .font(DesignTokens.Font.small.weight(.semibold))
                            .foregroundColor(DesignTokens.Text.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(height: headingHeight)

                ForEach(bands) { band in
                    HStack(spacing: 8) {
                        Text(band.title)
                            .font(DesignTokens.Font.small.weight(.medium))
                            .foregroundColor(DesignTokens.Text.secondary)
                            .lineLimit(1)
                            .frame(width: rowLabelWidth, alignment: .leading)
                        ForEach(codecs, id: \.self) { codec in
                            let id = CodecTestPlan.id(group: band.group,
                                                      item: "\(codec) \(band.resolution)",
                                                      mode: "强制硬件")
                            if let row = rowsByID[id] {
                                HardwareMatrixCell(
                                    row: row,
                                    selected: selectedID == row.id,
                                    included: selectedCaseIDs.contains(row.id),
                                    selectionEnabled: selectionEnabled,
                                    active: activeCaseID == row.id,
                                    phase: phase,
                                    canRunSingle: canRunSingle,
                                    setIncluded: { setIncluded(row.id, $0) },
                                    runSingle: { runSingle(row.id) },
                                    select: { select(row) }
                                )
                            } else {
                                Color.clear.frame(maxWidth: .infinity).accessibilityHidden(true)
                            }
                        }
                    }
                    .frame(height: rowHeight)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("硬件编解码测试，四种负载，每种包含 H.264 和 HEVC"))
    }
}

private struct HardwareMatrixCell: View {
    let row: BenchRow
    let selected: Bool
    let included: Bool
    let selectionEnabled: Bool
    let active: Bool
    let phase: String
    let canRunSingle: Bool
    let setIncluded: (Bool) -> Void
    let runSingle: () -> Void
    let select: () -> Void

    private var status: (String, Color) { CodecPresentation.classification(row) }
    private var statusSymbol: String {
        if active { return "hourglass" }
        if row.hasValidMeasurement { return "checkmark.circle" }
        if row.status == .failed { return "xmark.circle" }
        if row.status == .passed && row.ok { return "exclamationmark.triangle" }
        return "circle.dotted"
    }
    private var statusTitle: String { active ? "正在测量" : status.0 }
    private var measurementNote: String? {
        if active { return phase }
        if let failure = CodecPresentation.failureSummary(row) { return failure }
        if row.status == .passed && row.ok && !row.hasValidMeasurement { return "测量值无效" }
        if row.status == .failed { return row.detail.isEmpty ? nil : row.detail }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Toggle("加入测试：\(row.group) \(row.item) 强制硬件", isOn: Binding(
                get: { included }, set: setIncluded
            ))
            .labelsHidden()
            .toggleStyle(CheckboxToggleStyle())
            .controlSize(.small)
            .disabled(!selectionEnabled)
            .frame(width: 16)
            .help("勾选后加入下一轮测试")

            Button(action: select) {
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Image(systemName: statusSymbol)
                                .foregroundColor(active ? DesignTokens.Interaction.accent : status.1)
                                .accessibilityHidden(true)
                            Text(statusTitle).lineLimit(1)
                        }
                        .font(DesignTokens.Font.small.weight(.medium))
                        .foregroundColor(DesignTokens.Text.primary)
                        if let note = measurementNote {
                            Text(note)
                                .font(DesignTokens.Font.small)
                                .foregroundColor(DesignTokens.Text.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 2)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(row.hasValidMeasurement ? String(format: "%.1f", row.fps) : "—")
                            .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundColor(row.hasValidMeasurement ? DesignTokens.Text.primary : DesignTokens.Text.placeholder)
                            .lineLimit(1)
                        Text("FPS").font(.system(size: 9)).foregroundColor(DesignTokens.Text.secondary)
                    }
                    .fixedSize()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(row.group) \(row.item) 强制硬件 \(statusTitle)"))
            .accessibilityValue(Text(row.hasValidMeasurement ? String(format: "%.1f FPS", row.fps) : "无有效测量值"))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("hardware-cell-\(row.id)")
            .help(row.detail)
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: DesignTokens.corner)
            .fill(DesignTokens.Surface.content))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.corner)
            .fill(DesignTokens.Interaction.selection(active: true).opacity(selected ? 0.08 : 0))
            .allowsHitTesting(false))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.corner)
            .strokeBorder(DesignTokens.Stroke.separator, lineWidth: 1)
            .allowsHitTesting(false))
        .contextMenu {
            Button("单独测试此项", action: runSingle).disabled(!canRunSingle)
            Divider()
            Button(included ? "取消选择此项" : "选择此项") { setIncluded(!included) }
                .disabled(!selectionEnabled)
        }
    }
}
