import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI



struct HomeView: View {
    @ObservedObject private var store = DictationStore.shared
    @ObservedObject private var vocab = VocabStore.shared
    @ObservedObject private var corrections = CorrectionsStore.shared
    @ObservedObject private var enroll = SpeakerEnroll.shared
    var onOpenSettings: () -> Void = {}
    var onOpenHistory: () -> Void = {}

    @AppStorage("asrCloud") private var asrCloud = false
    @AppStorage("speakerVerify") private var speakerVerify = false
    @State private var adding = false
    @State private var newTerm = ""
    @State private var addingCorrection = false
    @State private var correctionWrong = ""
    @State private var correctionRight = ""
    @State private var searching = false
    @State private var query = ""
    @State private var showAll = false
    @State private var tab = 0            // 个人规则卡切页:0=常用写法 1=听写纠错
    @State private var showRuleHelp = false
    @State private var micGranted = false
    @State private var axGranted = false
    @State private var asrCloudKeyConfigured = false
    @State private var vocabNotice = ""
    @State private var correctionNotice = ""
    private let previewCount = 12

    var body: some View { homeContent }

    var homeContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            topBar
            hero
            statusStrip
            vocabSection
            recentSection
            Spacer(minLength: 0)
        }
        .padding(.top, 28)      // ⑤ 让开左上角红绿灯:窗口是 fullSizeContentView、内容从 y=0 起,不下移就压住交通灯
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var hotkey: String { HotkeyConfig.current.prettyDisplay }

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.Palette.accent)
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: "waveform").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.Palette.accentInk))
                HStack(spacing: 3) {
                    Text("Liana").font(.system(size: 17, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.Palette.textPrimary)
                    Rectangle().fill(Theme.Palette.accent).frame(width: 7, height: 18)
                }
            }
            Spacer(minLength: 18)
            statsLine
            Spacer(minLength: 18)
            HStack(spacing: 7) {
                Circle().fill(Theme.Palette.accent).frame(width: 7, height: 7)
                Text(L("就绪", "Ready")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.Palette.textPrimary)
                Text(L("· 按 \(hotkey) 说话", "· \(hotkey) to talk")).font(.system(size: 12)).foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Theme.Palette.bgElevated))
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(Theme.Palette.textSecondary)
            }.buttonStyle(.plain)
        }

        .padding(.horizontal, 24).padding(.top, 20)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                Text(L("轻声，成文", "Speak soft. Read clean.")).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Palette.textPrimary)
                Text("Speak softly. Write boldly.").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.Palette.textTertiary)
            }
            HStack(spacing: 16) {
                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<20, id: \.self) { i in
                        Capsule().fill(Theme.Palette.spectrum[min(6, i * 7 / 20)]).frame(width: 4, height: waveHeight(i))
                    }
                }
                .frame(height: 44)
                Image(systemName: "arrow.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.Palette.textTertiary)
                HStack(spacing: 2) {
                    Text(L("把你刚说的话，直接变成可用文字。", "Turn what you said into text you can use."))
                        .font(.system(size: 15, design: .monospaced)).foregroundStyle(Theme.Palette.textPrimary)
                    Rectangle().fill(Theme.Palette.accent).frame(width: 8, height: 20)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text(L("按住", "Hold")).foregroundStyle(Theme.Palette.textSecondary)
                Text(hotkey).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Palette.bgElevated))
                Text(L("说话,松手即出字", "to talk, release to drop text")).foregroundStyle(Theme.Palette.textSecondary)
            }
            .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .cardSurface(16)
        .padding(.horizontal, 24)
    }

    private var vocabSection: some View {
        let all = vocab.terms
        let filtered = (searching && !query.isEmpty) ? all.filter { $0.localizedCaseInsensitiveContains(query) } : all
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                tabHeader(L("常用写法", "Preferred spellings"), count: all.count, idx: 0)
                tabHeader(L("听写纠错", "Transcription corrections"), count: corrections.pairs.count, idx: 1)
                Button { showRuleHelp.toggle() } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help(L("这两项有什么区别？", "What is the difference?"))
                .popover(isPresented: $showRuleHelp, arrowEdge: .top) { ruleHelp }
                Spacer()
                if tab == 0 {
                    Button { searching.toggle(); if !searching { query = "" } } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(searching ? Theme.Palette.accent : Theme.Palette.textSecondary)
                    }.buttonStyle(.plain)
                    Button(action: importVocabulary) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }.buttonStyle(.plain).help(L("导入常用写法（合并）", "Import preferred spellings (merge)"))
                    Button(action: exportVocabulary) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }.buttonStyle(.plain).help(L("导出常用写法", "Export preferred spellings"))
                    Button { adding.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                            Text(L("添加写法", "Add spelling")).font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Theme.Palette.accentInk)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.Palette.accent))
                    }.buttonStyle(.plain)
                } else {
                    Button {
                        addingCorrection.toggle()
                        correctionNotice = ""
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                            Text(L("添加纠错", "Add correction")).font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Theme.Palette.accentInk)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.Palette.accent))
                    }.buttonStyle(.plain)
                }
            }
            if tab == 0 {
                if searching { field($query, L("搜索常用写法…", "Search preferred spellings…")) }
                if adding {
                    field($newTerm, L("输入正确写法，按回车保存…", "Type the preferred spelling, then press Return…"), onSubmit: addTerm)
                }
                if filtered.isEmpty {
                    Text(searching ? L("没找到。", "No match.") : L("还没有常用写法。添加人名、产品名或术语的正确拼写。", "No preferred spellings yet. Add the correct spelling of names, products, or terms."))
                        .font(.system(size: 12)).foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    let shown = showAll ? filtered : Array(filtered.prefix(previewCount))
                    FlowLayout(spacing: 9) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, t in chip(t) }
                        if filtered.count > previewCount {
                            Button { showAll.toggle() } label: {   // ③ 原来是纯 Text、点不动;包成 Button,展开/收起
                                Text(showAll ? L("收起", "Show less") : "+\(filtered.count - previewCount) \(L("更多", "more"))")
                                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Palette.accent)
                                    .padding(.horizontal, 13).padding(.vertical, 7)
                                    .background(Capsule().fill(Theme.Palette.accent.opacity(0.12)))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                HStack(spacing: 6) {
                    Circle().fill(Theme.Palette.bgElevated).frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Theme.Palette.borderSubtle))
                    Text(L("告诉 Liana 这个词应当怎样写；只有确定是同一个词时才统一写法。", "Tells Liana how a term should be written; it is used only when the term is clearly the same."))
                        .font(.system(size: 11)).foregroundStyle(Theme.Palette.textTertiary)
                }
                if !vocabNotice.isEmpty {
                    Text(vocabNotice).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.Palette.accent)
                }
            } else {
                correctionsBody
            }
        }
        .padding(18)
        .cardSurface(16)
        .padding(.horizontal, 24)
        .onAppear {
            vocab.reload(); corrections.reload(); refreshReadiness(); enroll.refresh()
        }   // 守护进程"编辑即学习"写的,回首页刷新才看得到
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshReadiness()
        }
    }


    private var statusStrip: some View {
        let voiceOn = speakerVerify && enroll.enrolled && enroll.available
        return HStack(spacing: 10) {
            Image(systemName: asrCloud && asrCloudKeyConfigured ? "arrow.triangle.2.circlepath" : "lock.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
            Text(asrCloud && asrCloudKeyConfigured
                 ? L("高准确 · Qwen 云端", "High accuracy · Qwen cloud")
                 : L("本地 · Qwen3 0.6B", "Local · Qwen3 0.6B"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.textPrimary)
            Rectangle().fill(Theme.Palette.borderSubtle).frame(width: 1, height: 14)
            Image(systemName: asrCloud && asrCloudKeyConfigured ? "cloud" : "cloud.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(asrCloud && asrCloudKeyConfigured ? Theme.Palette.accent : Theme.Palette.textTertiary)
            Text(cloudSummary)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textSecondary)
            Rectangle().fill(Theme.Palette.borderSubtle).frame(width: 1, height: 14)
            Image(systemName: voiceOn ? "person.wave.2.fill" : "person.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(voiceOn ? Theme.Palette.accent : Theme.Palette.textTertiary)
            Text(voiceOn
                 ? L("声纹：已开", "Voice: on")
                 : L("声纹：未开", "Voice: off"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: 8)
            if !micGranted || !axGranted {
                Button(L("完成设置", "Finish setup")) { onOpenSettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accentInk)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.Palette.accent))
            } else {
                Text(asrCloud && asrCloudKeyConfigured
                     ? L("失败回落本地", "Local fallback")
                     : L("可离线工作", "Works offline"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .cardSurface(12)
        .padding(.horizontal, 24)
    }

    private func refreshReadiness() {
        micGranted = AudioRecorder.microphoneGranted
        axGranted = AXIsProcessTrusted()
        asrCloudKeyConfigured = AppDefaults.asrCloudKeyState().value != nil
    }

    private var cloudSummary: String {
        if !asrCloud { return L("云端：已关闭", "Cloud: off") }
        return asrCloudKeyConfigured
            ? L("云端：高准确", "Cloud: high accuracy")
            : L("云端：未配置 Key", "Cloud: no key")
    }


    private func tabHeader(_ title: String, count: Int, idx: Int) -> some View {
        Button {
            tab = idx
            searching = false
            query = ""
            adding = false
            addingCorrection = false
            correctionNotice = ""
            showAll = false
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tab == idx ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                Text("\(count)").font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(tab == idx ? Theme.Palette.textSecondary : Theme.Palette.textTertiary)
            }
        }.buttonStyle(.plain)
    }


    private var correctionsBody: some View {
        let pairs = corrections.pairs
        return Group {
            if addingCorrection { correctionEditor }
            if pairs.isEmpty {
                Text(L("还没有听写纠错。反复听错同一个词时，添加一条明确的“听写成了 → 应改为”。",
                       "No transcription corrections yet. Add one when the same term is repeatedly misheard."))
                    .font(.system(size: 12)).foregroundStyle(Theme.Palette.textSecondary)
            } else {
                let shown = showAll ? pairs : Array(pairs.prefix(previewCount))
                FlowLayout(spacing: 9) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, p in correctionChip(p.wrong, p.right) }
                    if pairs.count > previewCount {
                        Button { showAll.toggle() } label: {
                            Text(showAll ? L("收起", "Show less") : "+\(pairs.count - previewCount) \(L("更多", "more"))")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Palette.accent)
                                .padding(.horizontal, 13).padding(.vertical, 7)
                                .background(Capsule().fill(Theme.Palette.accent.opacity(0.12)))
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 6) {
                Circle().fill(Theme.Palette.danger).frame(width: 9, height: 9)
                Text(L("只负责精确纠正转写结果，不锁定后续的可选润色。",
                       "Corrects the transcription; it does not lock later optional polishing."))
                    .font(.system(size: 11)).foregroundStyle(Theme.Palette.textTertiary)
            }
            if !correctionNotice.isEmpty {
                Text(correctionNotice).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.Palette.accent)
            }
        }
    }

    private var correctionEditor: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("听写成了", "Transcribed as"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.Palette.textTertiary)
                field($correctionWrong, L("错误文字", "Misheard text"))
            }
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary).padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 5) {
                Text(L("应改为", "Change to"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.Palette.textTertiary)
                field($correctionRight, L("正确文字", "Correct text"), onSubmit: addCorrection)
            }
            Button(L("保存纠错", "Save correction"), action: addCorrection)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(correctionDraftValid ? Theme.Palette.accentInk : Theme.Palette.textTertiary)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(Capsule().fill(correctionDraftValid ? Theme.Palette.accent : Theme.Palette.bgElevated))
                .disabled(!correctionDraftValid)
        }
    }

    private var correctionDraftValid: Bool {
        let wrong = correctionWrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = correctionRight.trimmingCharacters(in: .whitespacesAndNewlines)
        return !wrong.isEmpty && !right.isEmpty && wrong != right
    }

    private func addCorrection() {
        guard correctionDraftValid else { return }
        switch corrections.add(wrong: correctionWrong, right: correctionRight) {
        case .added:
            correctionNotice = L("已添加听写纠错", "Transcription correction added")
        case .updated:
            correctionNotice = L("已更新这条听写纠错", "Transcription correction updated")
        case .unchanged:
            correctionNotice = L("这条听写纠错已经存在", "This transcription correction already exists")
        case .invalid:
            correctionNotice = L("无法保存：请分别填写错误文字和正确文字", "Could not save: enter both the misheard and correct text")
            return
        }
        correctionWrong = ""
        correctionRight = ""
        addingCorrection = false
    }

    private var ruleHelp: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("两种个人规则", "Two personal rules"))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Palette.textPrimary)
            ruleHelpRow(
                icon: "textformat",
                title: L("常用写法", "Preferred spellings"),
                body: L("只填写正确写法。适合人名、产品名和术语；拿不准是不是同一个词时不会强改。",
                        "Enter only the correct spelling. Use it for names, products, and terms; uncertain matches are left unchanged.")
            )
            Divider().overlay(Theme.Palette.borderSubtle)
            ruleHelpRow(
                icon: "arrow.triangle.swap",
                title: L("听写纠错", "Transcription corrections"),
                body: L("明确填写“听写成了 → 应改为”。它先修正转写，但不会锁死后续的可选润色。",
                        "Enter an explicit “transcribed as → change to” pair. It corrects transcription first without locking later optional polishing.")
            )
            Text(L("两项都只保存在这台 Mac，不随安装包分发。", "Both stay on this Mac and are never bundled with the app."))
                .font(.system(size: 10.5)).foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
        .background(Theme.Palette.bgSurface)
    }

    private func ruleHelpRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent).frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Palette.textPrimary)
                Text(body).font(.system(size: 11)).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func correctionChip(_ wrong: String, _ right: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.swap").font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.Palette.danger.opacity(0.8))
            Text(wrong).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.Palette.textTertiary).strikethrough()
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.Palette.textTertiary)
            Text(right).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Palette.textPrimary)
            Button { corrections.remove(wrong: wrong) } label: {   // 点 ✕ 删这条纠正(写回 corrections.txt)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.Palette.textTertiary)
            }.buttonStyle(.plain).help(L("删除", "Remove"))
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Capsule().fill(Theme.Palette.danger.opacity(0.12)))
    }

    private func field(_ text: Binding<String>, _ ph: String, onSubmit: @escaping () -> Void = {}) -> some View {
        TextField(ph, text: text)
            .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.Palette.bgElevated))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.Palette.borderSubtle))
            .onSubmit(onSubmit)
    }

    private func addTerm() {
        let t = newTerm.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        vocab.add(t); newTerm = ""; adding = false
    }


    private func importVocabulary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try vocab.importFile(url)
            vocabNotice = result.added == 0
                ? L("没有新增词条(重复项已跳过)", "No new terms (duplicates skipped)")
                : L("已导入 \(result.added) 个词条", "Imported \(result.added) terms")
            Toast.show(vocabNotice)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { vocabNotice = "" }
        } catch {
            vocabNotice = L("导入失败：文件不是 UTF-8 文本", "Import failed: expected UTF-8 text")
            Toast.show(vocabNotice, duration: 3)
        }
    }

    private func exportVocabulary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "liana-vocabulary.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try vocab.export(to: url)
            vocabNotice = L("已导出 \(vocab.terms.count) 个词条", "Exported \(vocab.terms.count) terms")
            Toast.show(vocabNotice)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { vocabNotice = "" }
        } catch {
            vocabNotice = L("导出失败，请换一个位置再试", "Export failed; try another location")
            Toast.show(vocabNotice, duration: 3)
        }
    }

    private func chip(_ t: String) -> some View {
        HStack(spacing: 5) {
            Text(t).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Palette.textPrimary)
            Button { vocab.remove(t) } label: {   // 点 ✕ 删词(VocabStore.remove 写回 vocab.txt,守护进程即时读到)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.Palette.textTertiary)
            }.buttonStyle(.plain).help(L("删除", "Remove"))
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Capsule().fill(Theme.Palette.bgElevated))
    }

    private var recentSection: some View {


        let recents = Array(store.records.prefix(2))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L("最近记录", "Recent")).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Button(action: onOpenHistory) {
                    HStack(spacing: 4) {
                        Text(L("查看全部", "See all")).font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.Palette.bgElevated))
                }.buttonStyle(.plain)
            }
            if recents.isEmpty {
                Text(L("还没有记录。按热键说一句试试。", "Nothing yet. Press your hotkey and say something."))
                    .font(.system(size: 12)).foregroundStyle(Theme.Palette.textSecondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(recents) { r in
                        HStack(spacing: 13) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.Palette.accent).frame(width: 3, height: 34)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(r.text).font(.system(size: 14)).foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                                HStack(spacing: 6) {
                                    metaPill("clock", L("\(durationLabel(r.durationSec))秒 · \(r.chars)字", "\(durationLabel(r.durationSec)) · \(r.chars) chars"))
                                }
                            }
                            Spacer(minLength: 8)
                            CopyIconButton(text: r.text)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .cardSurface(12)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private func metaPill(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 11, design: .monospaced))
        }
        .foregroundStyle(Theme.Palette.textSecondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Theme.Palette.bgElevated))
    }

    private var statsLine: some View {
        let s = store.thisWeek
        return HStack(spacing: 5) {
            Text(L("本周", "This week")).foregroundStyle(Theme.Palette.textTertiary)
            Text("\(s.count)").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Palette.textSecondary)
            Text(L("次 ·", "·")).foregroundStyle(Theme.Palette.textTertiary)
            Text(charStr(s.chars)).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Palette.textSecondary)
            Text(L("字 · 省下", "chars · saved")).foregroundStyle(Theme.Palette.textTertiary)
            Text("\(Int(s.savedSec / 60))").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Palette.textSecondary)
            Text(L("分钟", "min")).foregroundStyle(Theme.Palette.textTertiary)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func waveHeight(_ i: Int) -> CGFloat {
        let x = Double(i)
        let v = sin(x * 0.5) * 0.42 + sin(x * 0.23 + 1) * 0.34 + sin(x * 0.12 + 2) * 0.24
        return 10 + CGFloat(abs(v)) * 48
    }

    private func durStr(_ sec: Double) -> String {
        let t = Int(sec.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
    }

    private func durationLabel(_ sec: Double) -> String {
        let t = Int(sec.rounded())
        return t < 60 ? "\(t)" : durStr(sec)
    }

    private func charStr(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

extension View {

    func cardSurface(_ r: CGFloat = Theme.Radius.card) -> some View {
        background(RoundedRectangle(cornerRadius: r, style: .continuous).fill(Theme.Palette.bgSurface))
            .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(Theme.Palette.borderSubtle, lineWidth: 1))
    }
}
