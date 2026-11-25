import SwiftUI
import AppKit

/// 只负责本机预览与显式操作；不会自动联网或后台发送反馈。
struct FeedbackView: View {
    let currentDiagnostic: FeedbackDiagnostic?
    let refreshHistory: (() throws -> [FeedbackDiagnostic])?
    let deleteDiagnostic: ((String) throws -> Void)?
    let clearHistory: (() throws -> Void)?
    let storageNotice: String?

    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.displayScale) private var displayScale
    private var hairline: CGFloat { 1 / max(displayScale, 1) }
    @State private var historyItems: [FeedbackDiagnostic]
    @State private var selectedID: String?
    @State private var issueTitle = "GPU-Z 问题反馈"
    @State private var problem = ""
    @State private var previewTab = PreviewTab.draft
    @State private var loading = false
    @State private var hasLoadedHistory = false
    @State private var operationNotice = ""
    @State private var activeAlert: FeedbackAlert?
    @State private var editedLogs: [String: FeedbackDiagnostic] = [:]
    @State private var logEditorPresented = false
    @State private var logEditorText = ""
    @State private var logEditorID = ""
    @State private var draftRevision = 0
    @State private var draftGeneration = 0
    @State private var draftWorkItem: DispatchWorkItem?
    @State private var pendingDraftKey: DraftKey?
    @State private var cachedDraft: CachedDraft?
    @State private var draftPending = false
    @State private var page = Page.overview
    @State private var feedbackReturnPage = Page.overview

    init(currentDiagnostic: FeedbackDiagnostic? = nil, history: [FeedbackDiagnostic] = [],
         refreshHistory: (() throws -> [FeedbackDiagnostic])? = nil,
         deleteDiagnostic: ((String) throws -> Void)? = nil,
         clearHistory: (() throws -> Void)? = nil, storageNotice: String? = nil) {
        self.currentDiagnostic = currentDiagnostic
        self.refreshHistory = refreshHistory
        self.deleteDiagnostic = deleteDiagnostic
        self.clearHistory = clearHistory
        self.storageNotice = storageNotice
        let sorted = history.sorted { $0.createdAt > $1.createdAt }
        _historyItems = State(initialValue: sorted)
        _selectedID = State(initialValue: sorted.first?.id ?? currentDiagnostic?.id)
    }

    private struct DraftKey: Equatable {
        let title: String
        let problem: String
        let selectedID: String?
        let revision: Int
    }

    private struct CachedDraft {
        let key: DraftKey
        let value: GitHubIssueDraft
    }

    private enum PreviewTab: String, CaseIterable, Identifiable {
        case draft = "网页草稿"
        case full = "完整脱敏日志"
        case json = "诊断 JSON"
        var id: String { rawValue }
    }

    private enum Page {
        case overview, records, compose, preview

        var title: String {
            switch self {
            case .overview: return "日志与反馈"
            case .records: return "诊断记录"
            case .compose: return "填写反馈"
            case .preview: return "预览反馈"
            }
        }
    }

    private enum FeedbackAlert: Identifiable {
        case error(String), delete(String), clear
        var id: String {
            switch self {
            case .error(let message): return "error:" + message
            case .delete(let id): return "delete:" + id
            case .clear: return "clear"
            }
        }
    }

    private var diagnostics: [FeedbackDiagnostic] {
        var items = historyItems
        // 有已持久化日志时优先真实记录；存储失败或没有历史时才使用临时诊断补救。
        if let current = currentDiagnostic, (items.isEmpty || storageNotice != nil),
           !items.contains(where: { $0.id == current.id }) { items.append(current) }
        return items
    }
    private var originalSelection: FeedbackDiagnostic? {
        diagnostics.first { $0.id == selectedID } ?? diagnostics.first
    }
    private var selected: FeedbackDiagnostic? {
        guard let original = originalSelection else { return nil }
        return editedLogs[original.id] ?? original
    }
    private var usingEditedCopy: Bool {
        originalSelection.map { editedLogs[$0.id] != nil } ?? false
    }
    private var activeDraftKey: DraftKey {
        DraftKey(title: issueTitle, problem: problem, selectedID: selected?.id, revision: draftRevision)
    }
    private var readyDraft: GitHubIssueDraft? {
        guard let cachedDraft, cachedDraft.key == activeDraftKey, !draftPending, !loading else { return nil }
        return cachedDraft.value
    }
    private var listSelection: Binding<String?> {
        Binding(
            get: { originalSelection?.id },
            set: { newID in
                guard let newID else { return }
                selectedID = newID
            }
        )
    }
    private func previewText(for draft: GitHubIssueDraft?) -> String {
        switch previewTab {
        case .draft: return draft?.text ?? "正在更新预览…"
        case .full: return selected?.redactedText ?? "尚无脱敏诊断日志。你仍可填写问题现象并预览网页草稿。"
        case .json:
            if usingEditedCopy { return "当前使用删减副本，仅以 TXT 提交。本次禁用原诊断 JSON，避免重新带出已删除内容。" }
            return selected?.redactedJSON ?? "此记录没有可用的结构化 JSON；完整脱敏 TXT 仍可预览和导出。"
        }
    }
    private var canDeleteSelected: Bool {
        selected.map { doc in doc.isLocalRecord && historyItems.contains { $0.id == doc.id } } == true && deleteDiagnostic != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            pageContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline()
            footer
        }
        .frame(width: 720, height: page == .overview ? 340 : 500)
        .font(DesignTokens.Font.body).lineSpacing(2)
        .foregroundColor(DesignTokens.Text.primary)
        .background(DesignTokens.Surface.window)
        .buttonStyle(NativeButtonStyle(prominent: false))
        .onAppear { reloadHistory(firstLoad: true) }
        .onDisappear { cancelDraftGeneration() }
        .onChange(of: issueTitle) { _ in scheduleDraftGeneration() }
        .onChange(of: problem) { _ in scheduleDraftGeneration() }
        .onChange(of: selectedID) { _ in
            draftRevision += 1
            operationNotice = ""
            scheduleDraftGeneration()
        }
        .onChange(of: currentDiagnostic?.createdAt) { _ in
            draftRevision += 1
            scheduleDraftGeneration()
        }
        .onChange(of: storageNotice) { _ in
            draftRevision += 1
            scheduleDraftGeneration()
        }
        .alert(item: $activeAlert, content: makeAlert)
        .sheet(isPresented: $logEditorPresented) {
            FeedbackLogEditor(text: logEditorText, original: diagnostics.first { $0.id == logEditorID }) { document in
                editedLogs[document.id] = document
                draftRevision += 1
                previewTab = .full
                operationNotice = "已应用删减副本；原日志未修改，本次仅以 TXT 提交"
                scheduleDraftGeneration()
                logEditorPresented = false
            }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .overview:
            overview
        case .records:
            HStack(spacing: 0) {
                historySidebar.frame(width: 218)
                    .background(SidebarSurface())
                Hairline(axis: .vertical)
                diagnosticBody.padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .compose:
            feedbackBody.padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .preview:
            previewPanel(draft: readyDraft).padding(18)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if page == .overview {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(DesignTokens.Font.title2).foregroundColor(.codecAccent).accessibilityHidden(true)
            } else {
                Button(action: returnToPreviousPage) { Image(systemName: "chevron.left") }
                    .accessibilityLabel("返回")
                    .accessibilityIdentifier("feedback.back")
            }
            Text(page.title).font(DesignTokens.Font.title2.weight(.semibold))
            Spacer()
            Button("关闭") { presentationMode.wrappedValue.dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("feedback.close")
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func returnToPreviousPage() {
        switch page {
        case .overview: break
        case .records: page = .overview
        case .compose: page = feedbackReturnPage
        case .preview: page = .compose
        }
        operationNotice = ""
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let record = originalSelection {
                Text(record.title).font(DesignTokens.Font.title3)
                Text(Self.dateString(record.createdAt))
                    .font(DesignTokens.Font.body.monospacedDigit())
                    .foregroundColor(DesignTokens.Text.secondary)
            } else {
                Text(loading ? "正在读取诊断记录…" : "暂无诊断记录")
                    .font(DesignTokens.Font.title3)
            }
            if let storageNotice, !storageNotice.isEmpty {
                Text(DiagnosticRedactor.redact(storageNotice))
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Status.warning)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PanelStyle(padding: 18))
        .frame(width: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("feedback.overview")
    }

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("诊断记录").font(DesignTokens.Font.title3)
                Spacer()
                if loading { ProgressView().scaleEffect(0.55).frame(width: 18, height: 18) }
                Button(action: { reloadHistory() }) { Image(systemName: "arrow.clockwise") }
                    .disabled(loading || refreshHistory == nil)
                    .accessibilityLabel("刷新本机日志")
                    .accessibilityIdentifier("feedback.reload")
                    .help("重新读取本机日志，不会运行新的编解码测试")
            }
            if diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(loading ? "正在读取…" : "尚无记录").font(DesignTokens.Font.body.weight(.medium))
                    Text("完成环境扫描或测试后，脱敏记录会显示在这里。也可先填写问题说明。")
                        .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 12).padding(.horizontal, 8)
                Spacer()
            } else {
                List(selection: listSelection) {
                    ForEach(diagnostics) { diagnostic in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(diagnostic.title)
                                .font(DesignTokens.Font.body.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(Self.dateString(diagnostic.createdAt))
                                .font(DesignTokens.Font.small.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text(diagnostic.title + "，" + Self.dateString(diagnostic.createdAt)))
                        .accessibilityIdentifier("feedback.record.\(diagnostic.id)")
                        .help(diagnostic.title + "\n" + Self.dateString(diagnostic.createdAt))
                        .tag(diagnostic.id)
                    }
                }
                .listStyle(SidebarListStyle())
                .modifier(FeedbackListSurface())
                .environment(\.defaultMinListRowHeight, 28)
                .foregroundColor(nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let notice = storageNotice, !notice.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(DesignTokens.Status.warning)
                        .accessibilityHidden(true)
                    Text("日志留存提示：" + DiagnosticRedactor.redact(notice))
                        .foregroundColor(DesignTokens.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.font(DesignTokens.Font.small)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.controlCorner)
                        .fill(DesignTokens.Status.warning.opacity(DesignTokens.Status.backgroundOpacity)))
            }
            Text("最近 20 次 · 最长 30 天 · 仅存本机")
                .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Menu {
                Button("删除所选记录…") {
                    if let id = selected?.id { activeAlert = .delete(id) }
                }.disabled(!canDeleteSelected)
                Button("清空可删除的历史记录…") { activeAlert = .clear }
                    .disabled(clearHistory == nil || !historyItems.contains { $0.isLocalRecord })
            } label: { Text("管理记录…").foregroundColor(DesignTokens.Text.secondary) }
                .modifier(NativeMenuStyle()).disabled(loading)
                .accessibilityIdentifier("feedback.manage")
        }.padding(12)
    }

    private var feedbackBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("标题").font(DesignTokens.Font.body.weight(.medium))
                    TextField("概括发生的问题", text: $issueTitle)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .accessibilityLabel("反馈标题")
                        .accessibilityIdentifier("feedback.issueTitle")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("问题现象与复现步骤").font(DesignTokens.Font.body.weight(.medium))
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $problem).font(DesignTokens.Font.body).frame(height: 122)
                            .accessibilityLabel("问题现象与复现步骤")
                            .accessibilityIdentifier("feedback.problem")
                        if problem.isEmpty {
                            Text("例如：已安装驱动，但 H.264 硬编失败；点击开始后出现……")
                                .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.placeholder)
                                .padding(.horizontal, 5).padding(.vertical, 6)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.controlCorner)
                        .strokeBorder(DesignTokens.Stroke.separator, lineWidth: hairline))
                }
            }
            selectedDiagnosticSummary
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var diagnosticBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected {
                HStack(alignment: .firstTextBaseline) {
                    Text(usingEditedCopy ? "删减日志副本" : "脱敏日志内容")
                        .font(DesignTokens.Font.title3)
                    Spacer()
                    Text(Self.dateString(selected.createdAt))
                        .font(DesignTokens.Font.small.monospacedDigit())
                        .foregroundColor(DesignTokens.Text.secondary)
                }
                FeedbackTextPreview(text: selected.redactedText, usesMonospacedFont: true)
                    .frame(maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.controlCorner)
                        .strokeBorder(DesignTokens.Stroke.separator, lineWidth: hairline))
                    .accessibilityLabel("所选记录的脱敏日志，可选择和复制")
                    .accessibilityIdentifier("feedback.localLog")
            } else {
                Text(loading ? "正在读取诊断记录…" : "暂无诊断记录")
                    .foregroundColor(DesignTokens.Text.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func previewPanel(draft: GitHubIssueDraft?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("预览内容", selection: $previewTab) {
                ForEach(PreviewTab.allCases) { tab in
                    Text(tab == .full && usingEditedCopy ? "删减日志" : tab.rawValue)
                        .tag(tab).disabled(usingEditedCopy && tab == .json)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .labelsHidden()
            .accessibilityIdentifier("feedback.preview.kind")
            FeedbackTextPreview(text: previewText(for: draft), usesMonospacedFont: previewTab != .draft)
                .frame(maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.controlCorner)
                    .strokeBorder(DesignTokens.Stroke.separator, lineWidth: hairline))
                .accessibilityLabel("脱敏反馈内容预览，可选择和复制")
                .accessibilityIdentifier("feedback.preview.content")
            if previewTab == .draft {
                Text(draft.map(deliveryDescription) ?? "正在生成草稿…")
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
            }
        }
    }

    @ViewBuilder
    private var selectedDiagnosticSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(DesignTokens.Font.body)
                    .foregroundColor(.codecAccent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(selected?.title ?? "未选择诊断记录")
                        .font(DesignTokens.Font.body.weight(.semibold)).lineLimit(1)
                    Text(selected.map(Self.historyDetail) ?? "网页草稿仅包含问题说明")
                        .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if usingEditedCopy {
                    Text("删减副本").font(DesignTokens.Font.small)
                        .foregroundColor(DesignTokens.Text.secondary)
                }
                Menu {
                    Button("删减本次反馈日志副本…") { editSelectedLog() }
                        .disabled(selected == nil)
                    if usingEditedCopy {
                        Button("还原原日志") { restoreOriginalLog() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .modifier(NativeMenuStyle())
                .accessibilityLabel("更多日志操作")
                .accessibilityIdentifier("feedback.more")
            }
        }
        .modifier(PanelStyle(padding: 12))
    }

    private func editSelectedLog() {
        guard let document = selected else { return }
        logEditorID = document.id
        logEditorText = document.redactedText
        logEditorPresented = true
    }

    private func restoreOriginalLog() {
        if let id = originalSelection?.id { editedLogs.removeValue(forKey: id) }
        draftRevision += 1
        operationNotice = "已还原本机原日志；提交前请重新检查"
        scheduleDraftGeneration()
    }

    private func deliveryDescription(_ draft: GitHubIssueDraft) -> String {
        switch draft.delivery {
        case .complete:
            if selected == nil { return "未选择诊断日志；网页草稿仅含标题与问题说明。" }
            if usingEditedCopy { return "网页草稿包含当前删减后的脱敏内容；原日志与原 JSON 不变。" }
            return "网页草稿包含问题、诊断摘要和所选脱敏日志。"
        case .summaryOnly:
            return usingEditedCopy
                ? "网页链接只含问题与诊断摘要；删减后的日志副本未放入，需手动附加。"
                : "网页链接只含问题与诊断摘要；完整过程日志未传，需手动附加。"
        case .manual:
            return "网页仅预填待补充说明；完整反馈尚未放入链接。"
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if page == .overview {
                Button("浏览记录…") { page = .records }
                    .accessibilityIdentifier("feedback.browse")
            }
            if !operationNotice.isEmpty {
                Text(operationNotice)
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            switch page {
            case .overview:
                Button(usingEditedCopy ? "导出副本…" : "导出日志…", action: exportSelectedLog)
                    .disabled(selected == nil || loading)
                    .accessibilityIdentifier("feedback.export")
                composeButton
            case .records:
                Menu {
                    Button(usingEditedCopy ? "删减副本 TXT" : "脱敏日志 TXT", action: exportSelectedLog)
                        .disabled(selected == nil)
                    Button("脱敏诊断 JSON", action: exportSelectedJSON)
                        .disabled(selected?.redactedJSON == nil)
                } label: { Text("导出…").foregroundColor(DesignTokens.Text.secondary) }
                    .modifier(NativeMenuStyle())
                    .accessibilityIdentifier("feedback.recordExport")
                composeButton
            case .compose:
                Button("预览内容") {
                    previewTab = .draft
                    page = .preview
                    operationNotice = ""
                    scheduleDraftGeneration()
                }
                .buttonStyle(NativeButtonStyle(prominent: true))
                .accessibilityIdentifier("feedback.preview.toggle")
            case .preview:
                draftExportMenu
                Button("打开 GitHub…", action: openGitHub)
                    .buttonStyle(NativeButtonStyle(prominent: true))
                    .disabled(readyDraft == nil || loading)
                    .accessibilityIdentifier("feedback.github")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var composeButton: some View {
        Button("填写反馈…") {
            feedbackReturnPage = page
            page = .compose
            operationNotice = ""
            scheduleDraftGeneration()
        }
        .buttonStyle(NativeButtonStyle(prominent: true))
        .accessibilityIdentifier("feedback.compose")
    }

    private var draftExportMenu: some View {
        let hasDraft = readyDraft != nil
        return Menu {
            Button("复制网页草稿正文", action: copyDraftBody).disabled(!hasDraft)
            Button("复制完整反馈正文", action: copyFullFeedback).disabled(!hasDraft)
            Divider()
            Button("网页草稿 TXT") { exportDraft(asJSON: false) }.disabled(!hasDraft)
            Button("网页草稿 JSON") { exportDraft(asJSON: true) }
                .disabled(!hasDraft || usingEditedCopy)
            Button("完整反馈 TXT", action: exportFullFeedback).disabled(!hasDraft)
            Button(usingEditedCopy ? "删减日志副本 TXT" : "脱敏日志 TXT", action: exportSelectedLog)
                .disabled(selected == nil)
            Button("脱敏诊断 JSON", action: exportSelectedJSON)
                .disabled(selected?.redactedJSON == nil)
        } label: { Text("复制 / 导出…").foregroundColor(DesignTokens.Text.secondary) }
            .modifier(NativeMenuStyle())
            .accessibilityIdentifier("feedback.copyExport")
    }

    private func scheduleDraftGeneration() {
        guard page == .compose || page == .preview else { return }
        let key = activeDraftKey
        if cachedDraft?.key == key || (draftPending && pendingDraftKey == key) { return }

        draftGeneration &+= 1
        let generation = draftGeneration
        draftWorkItem?.cancel()
        cachedDraft = nil
        pendingDraftKey = key
        draftPending = true

        let title = key.title
        let problem = key.problem
        let diagnostic = selected
        let workItem = DispatchWorkItem {
            let value = GitHubFeedback.makeDraft(title: title, problem: problem, diagnostic: diagnostic)
            DispatchQueue.main.async {
                guard generation == draftGeneration, key == activeDraftKey else { return }
                cachedDraft = CachedDraft(key: key, value: value)
                pendingDraftKey = nil
                draftPending = false
                draftWorkItem = nil
            }
        }
        draftWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func cancelDraftGeneration() {
        draftGeneration &+= 1
        draftWorkItem?.cancel()
        draftWorkItem = nil
        pendingDraftKey = nil
        draftPending = false
    }

    private func reloadHistory(firstLoad: Bool = false) {
        guard let refresh = refreshHistory, !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try refresh().sorted { $0.createdAt > $1.createdAt } }
            DispatchQueue.main.async {
                loading = false
                switch result {
                case .success(let items):
                    historyItems = items
                    draftRevision += 1
                    if (!hasLoadedHistory || firstLoad) {
                        selectedID = items.first?.id ?? currentDiagnostic?.id
                    } else if !diagnostics.contains(where: { $0.id == selectedID }) {
                        selectedID = diagnostics.first?.id
                    }
                    hasLoadedHistory = true
                    scheduleDraftGeneration()
                case .failure(let error):
                    hasLoadedHistory = true
                    activeAlert = .error("无法读取日志：" + DiagnosticRedactor.redact(error.localizedDescription))
                    scheduleDraftGeneration()
                }
            }
        }
    }

    private func makeAlert(_ alert: FeedbackAlert) -> Alert {
        switch alert {
        case .error(let message):
            return Alert(title: Text("操作未完成"), message: Text(message), dismissButton: .default(Text("知道了")))
        case .delete(let id):
            return Alert(title: Text("删除所选本机日志？"), message: Text("已导出的文件和 GitHub 内容不受影响；运行中的记录会由存储层保护。"),
                primaryButton: .destructive(Text("删除"), action: {
                    performHistoryChange { try deleteDiagnostic?(id) }
                }), secondaryButton: .cancel(Text("保留")))
        case .clear:
            return Alert(title: Text("清空可删除的历史日志？"), message: Text("只清理本机记录；运行中的记录由存储层决定是否保留。"),
                primaryButton: .destructive(Text("清空"), action: {
                    performHistoryChange { try clearHistory?() }
                }), secondaryButton: .cancel(Text("保留")))
        }
    }

    private func performHistoryChange(_ change: @escaping () throws -> Void) {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try change() }
            DispatchQueue.main.async {
                loading = false
                switch result {
                case .success: operationNotice = "本机日志已更新"; reloadHistory()
                case .failure(let error): activeAlert = .error(DiagnosticRedactor.redact(error.localizedDescription))
                }
            }
        }
    }

    private func copy(_ text: String, notice: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) { operationNotice = notice }
        else { activeAlert = .error("无法写入剪贴板，请重试。") }
    }

    private func copyDraftBody() {
        guard page == .preview, let draft = readyDraft, !loading else { return }
        copy(draft.body, notice: "已复制当前网页草稿正文")
    }

    private func copyFullFeedback() {
        guard let draft = readyDraft, !loading else { return }
        copy(draft.fullBody, notice: "已复制完整反馈；可在 GitHub 网页手动粘贴")
    }

    private func exportDraft(asJSON: Bool) {
        guard let draft = readyDraft, !loading else { return }
        do {
            let text = try asJSON ? GitHubFeedback.draftJSON(draft) : draft.text
            export(text, extension: asJSON ? "json" : "txt", name: "GPU-Z-GitHub-draft")
        } catch { activeAlert = .error(DiagnosticRedactor.redact(error.localizedDescription)) }
    }

    private func exportFullFeedback() {
        guard let draft = readyDraft, !loading else { return }
        export(draft.fullText, extension: "txt", name: "GPU-Z-feedback-full")
    }

    private func exportSelectedLog() {
        guard let selected else { return }
        export(selected.redactedText, extension: "txt",
               name: usingEditedCopy ? "GPU-Z-log-redacted-copy" : "GPU-Z-log-redacted")
    }

    private func exportSelectedJSON() {
        guard let json = selected?.redactedJSON else { return }
        export(json, extension: "json", name: "GPU-Z-diagnostic-redacted")
    }

    private func export(_ text: String, extension fileExtension: String, name: String) {
        let exceedsAttachmentLimit = text.utf8.count > GitHubFeedback.maximumAttachmentBytes
        let panel = NSSavePanel()
        panel.allowedFileTypes = [fileExtension]
        panel.nameFieldStringValue = name + "." + fileExtension
        panel.title = "导出已预览的脱敏内容"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            operationNotice = exceedsAttachmentLimit
                ? "已完整导出，文件超过 GitHub 普通附件的 25 MB 限制；尚未上传，请在网页另行说明"
                : "已导出脱敏文件；尚未向 GitHub 上传"
        } catch { activeAlert = .error(DiagnosticRedactor.redact(error.localizedDescription)) }
    }

    private func openGitHub() {
        guard let draft = readyDraft, !loading else { return }
        // The preview must match the exact draft handed to the browser; this never submits an issue.
        guard previewTab == .draft else {
            previewTab = .draft
            operationNotice = "已切换到网页草稿。检查后再点“打开 GitHub…”"
            return
        }
        let target = draft.url ?? GitHubFeedback.newIssueURL
        if NSWorkspace.shared.open(target) {
            operationNotice = draft.url == nil
                ? "已打开空白 issue 页面；请手动复制完整反馈"
                : "已打开 GitHub 草稿，尚未提交或上传附件"
        } else { activeAlert = .error("无法打开默认浏览器。可复制反馈后手动前往 \(GitHubFeedback.newIssueURL.absoluteString)。") }
    }

    private static func historyDetail(_ diagnostic: FeedbackDiagnostic) -> String {
        let local = diagnostic.isLocalRecord ? "本机" : "当前快照"
        return Self.dateString(diagnostic.createdAt) + " · " + local
    }

    private static func byteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

private struct FeedbackListSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 13, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}

/// macOS 11 也支持选择和复制的只读预览，不依赖后续系统的 Text.textSelection。
private struct FeedbackTextPreview: NSViewRepresentable {
    let text: String
    let usesMonospacedFont: Bool

    private var previewFont: NSFont {
        usesMonospacedFont
            ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            : NSFont.systemFont(ofSize: 13, weight: .regular)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = previewFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        view.defaultParagraphStyle = paragraph
        view.textColor = NSColor.labelColor
        view.backgroundColor = NSColor.textBackgroundColor
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.font?.fontName != previewFont.fontName || view.font?.pointSize != previewFont.pointSize {
            view.font = previewFont
            view.typingAttributes[.font] = previewFont
        }
        if view.string != text {
            view.string = text
            let start = NSRange(location: 0, length: 0)
            view.setSelectedRange(start)
            view.scrollRangeToVisible(start)
        }
    }
}

/// 编辑仅生成当前反馈副本，应用后重新脱敏；不回写历史日志或原诊断 JSON。
private struct FeedbackLogEditor: View {
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.displayScale) private var displayScale
    private var hairline: CGFloat { 1 / max(displayScale, 1) }
    @State private var text: String
    @State private var applying = false
    @State private var errorMessage: String?
    let original: FeedbackDiagnostic?
    let apply: (FeedbackDiagnostic) -> Void

    init(text: String, original: FeedbackDiagnostic?, apply: @escaping (FeedbackDiagnostic) -> Void) {
        _text = State(initialValue: text)
        self.original = original
        self.apply = apply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("删减本次反馈的日志副本").font(DesignTokens.Font.title2.weight(.semibold))
            Text("可删除你不愿公开的内容。应用时会再次脱敏，并以此副本生成预览、复制内容和 TXT 导出；原本机日志不变，原诊断 JSON 将禁用。")
                .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
            TextEditor(text: $text).font(DesignTokens.Font.small).disabled(applying)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.sep, lineWidth: hairline))
            if let message = errorMessage {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(DesignTokens.Text.primary).padding(4)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.controlCorner)
                            .fill(DesignTokens.Status.error.opacity(DesignTokens.Status.backgroundOpacity)))
                        .accessibilityHidden(true)
                    Text(message).foregroundColor(DesignTokens.Text.primary)
                }.font(DesignTokens.Font.small)
            }
            HStack {
                if applying { ProgressView("正在脱敏副本，请稍候…").font(DesignTokens.Font.small) }
                else { Text("请保留关键错误码与复现信息，避免删去诊断上下文。")
                    .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary) }
                Spacer()
                Button("取消") { presentationMode.wrappedValue.dismiss() }.keyboardShortcut(.cancelAction).disabled(applying)
                Button("应用删减副本", action: applyCopy).disabled(applying)
                    .buttonStyle(NativeButtonStyle(prominent: true))
            }
        }.padding(20).frame(minWidth: 680, idealWidth: 780, minHeight: 480, idealHeight: 590)
            .font(DesignTokens.Font.body).lineSpacing(2)
            .foregroundColor(DesignTokens.Text.primary)
            .background(DesignTokens.Surface.window)
            .buttonStyle(NativeButtonStyle(prominent: false))
    }

    private func applyCopy() {
        guard let original = original else { errorMessage = "原记录已不可用，请取消后重新选择日志。"; return }
        applying = true
        errorMessage = nil
        let editedText = text
        DispatchQueue.global(qos: .utility).async {
            let document = FeedbackDiagnostic(id: original.id, title: original.title, createdAt: original.createdAt,
                redactedText: editedText, redactedJSON: nil,
                summary: "已使用用户删减后的脱敏 TXT 副本；本次反馈不包含原诊断 JSON。",
                sourceDescription: "本次反馈副本（原本机记录未修改）", isLocalRecord: original.isLocalRecord)
            DispatchQueue.main.async { applying = false; apply(document) }
        }
    }
}
