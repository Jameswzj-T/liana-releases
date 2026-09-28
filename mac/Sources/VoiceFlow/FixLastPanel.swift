import AppKit
import SwiftUI







@MainActor
final class FixLastPanel {
    static let shared = FixLastPanel()
    private var panel: NSPanel?
    private var priorApp: NSRunningApplication?

    func show() {
        guard let record = DictationStore.shared.records.first else {
            Toast.show(L("还没有听写记录——先按热键说一句", "Nothing dictated yet — press the hotkey and say something"))
            return
        }
        priorApp = NSWorkspace.shared.frontmostApplication   // 记住刚才在用的 app,关掉面板后把前台还回去
        if panel == nil { panel = makePanel() }
        panel?.contentViewController = NSHostingController(
            rootView: FixLastView(record: record, onClose: { [weak self] in self?.close() })
        )
        panel?.setContentSize(NSSize(width: 480, height: 300))
        panel?.center()


        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        if let prior = priorApp, prior.bundleIdentifier != Bundle.main.bundleIdentifier {
            prior.activate(options: [])   // teach-only 不回贴 → 焦点回到刚才那个应用,你接着干原来的事
        }
        priorApp = nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                        styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .aqua)
        p.backgroundColor = NSColor(red: 0xF5 / 255.0, green: 0xF1 / 255.0, blue: 0xE8 / 255.0, alpha: 1)
        return p
    }
}


private struct FixLastView: View {
    let record: DictationRecord
    let onClose: () -> Void
    @State private var draft: String
    @State private var retrying = false
    @State private var retryMessage = ""
    @FocusState private var focused: Bool

    init(record: DictationRecord, onClose: @escaping () -> Void) {
        self.record = record
        self.onClose = onClose
        _draft = State(initialValue: record.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("改上一条", "Fix last")).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Text(L("改完按 ⌘↩ 记住", "⌘↩ to remember")).font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            TextEditor(text: $draft)
                .font(.system(size: 15)).scrollContentBackground(.hidden)
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(minHeight: 120)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.bgElevated))
                .focused($focused)
            if !retryMessage.isEmpty {
                Text(retryMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.accent)
            }
            HStack(spacing: 12) {
                Text(L("只教它记住,不动你现在光标处的字", "Teaches Liana — won't touch your cursor"))
                    .font(.system(size: 11)).foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                if DictationStore.shared.canRetry(record) {
                    Button {
                        retry()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: retrying ? "hourglass" : "arrow.clockwise")
                            Text(retrying ? L("识别中…", "Retrying…") : L("重新识别", "Retry"))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .disabled(retrying)
                }
                Button(L("取消", "Cancel")) { onClose() }
                    .buttonStyle(.plain).foregroundStyle(Theme.Palette.textSecondary)
                    .keyboardShortcut(.cancelAction)                        // Esc 关
                Button(L("记住", "Remember")) { remember() }
                    .buttonStyle(.plain).foregroundStyle(Theme.Palette.accent).fontWeight(.semibold)
                    .keyboardShortcut(.return, modifiers: .command)          // ⌘↩ 记住(纯↩留给文本框换行)
            }.font(.system(size: 13))
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { focused = true }
    }

    private func remember() {
        let old = record.text
        guard draft != old, !draft.isEmpty else { onClose(); return }   // 没改 / 清空 → 不学,直接关
        DictationStore.shared.update(id: record.id, newText: draft)      // 记忆库这条也跟着更新(与铅笔编辑一致)
        let raw = record.raw ?? ""
        Task {

            let terms = await Transcriber.shared.learn(old: old, new: draft, raw: raw)
            await MainActor.run {
                Toast.show(terms.isEmpty
                    ? L("已更新这条(没提取到要记的词)", "Updated (nothing new to learn)")
                    : L("✓ 已记住:\(terms.joined(separator: "、"))", "✓ Learned: \(terms.joined(separator: "、"))"))
                onClose()
            }
        }
    }



    private func retry() {
        guard let url = DictationStore.shared.lastAudioURL else { return }
        TemporaryAudioFiles.shared.retain(url)
        retrying = true
        retryMessage = ""
        Task {
            defer { TemporaryAudioFiles.shared.release(url) }
            let result = await Transcriber.shared.transcribe(path: url.path)
            let raw = await Transcriber.shared.lastRaw
            await MainActor.run {
                retrying = false
                if result.isEmpty {
                    retryMessage = L("重新识别没有得到结果，原文字未改变。", "Retry returned no text; the original is unchanged.")
                } else {
                    draft = result
                    retryMessage = raw.isEmpty
                        ? L("已得到候选结果；按“记住”才会替换这条记录。", "Candidate ready; press Remember to replace this record.")
                        : L("候选结果已放入编辑框；确认后才会替换。", "Candidate is in the editor; confirm to replace it.")
                }
            }
        }
    }
}
