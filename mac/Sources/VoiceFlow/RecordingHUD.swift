import AppKit
import SwiftUI


@MainActor
final class HUDModel: ObservableObject {
    @Published var levels: [CGFloat] = Array(repeating: 0.06, count: 9)   // 每个频段的柱高(平滑后,0..1),驱动均衡器
    @Published var processing = false
    @Published var slowPolish = false
    @Published var usingTranscript = false
    @Published var visible = true          // 出字后淡出
    @Published var active = false          // panel 隐藏后必须停掉 TimelineView；orderOut 本身不会停动画时钟

    private var seen: [Float] = []          // 本次录音的原始 RMS,停录时打分位数 —— 拿真实数据标定曲线
    private var seenBands: [[Float]] = []   // 本次录音每帧的频段能量,停录打【每频段中位 share】—— 标定压缩/包络用真数据、别再靠猜

    func push(_ rms: Float, _ bands: [Float]) {
        seen.append(rms)




        guard !bands.isEmpty else { return }
        seenBands.append(bands)   // 记真实频谱,停录时打分布 → 标定不再靠猜





        let db = 20 * log10(max(rms, 1e-6))
        let overall = CGFloat(min(1.0, max(0.06, (db + 62) / 44)))          // 绝对响度:-40→0.5、-28→0.77、-18 顶
        let mean = Double(bands.reduce(0, +)) / Double(bands.count)
        let center = (levels.count - 1) / 2
        for i in 0..<levels.count {





            let fb = min(abs(i - center), bands.count - 1)                  // 中央=低频、边缘=高频(镜像)
            let raw = Double(bands[fb]) / max(mean, 1e-6)
            let share = min(1.6, max(0.25, raw))                            // 保底 0.25 + 封顶 1.6
            let bias = 0.30 + 0.70 * exp(-pow(Double(i - center) / 2.4, 2)) // 山峰:中央 1.0,两侧 0.30
            let boost = 1.0 + 0.25 * exp(-pow(Double(i - center) / 1.5, 2)) // 中央再拔高(波峰尖)
            let target = overall * CGFloat(pow(share * bias, 0.7) * 0.68 * boost)   // ^0.7:压平低频独大,让中频也有反应


            let k: CGFloat = target > levels[i] ? 1.0 : (0.30 + 0.35 * levels[i])
            levels[i] = levels[i] * (1 - k) + target * k
        }
    }

    func reset() {
        dumpLevelStats()
        levels = Array(repeating: 0.06, count: levels.count); processing = false; visible = true
        slowPolish = false; usingTranscript = false
    }



    private func dumpLevelStats() {
        defer { seen.removeAll(); seenBands.removeAll() }
        guard seen.count > 8 else { return }
        let s = seen.sorted()
        func q(_ p: Double) -> Float { s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
        func db(_ v: Float) -> String { String(format: "%.0f", 20 * log10(max(v, 1e-6))) }
        var line = "电平分布 n=\(s.count)  p10=\(db(q(0.10)))dB  中位=\(db(q(0.50)))dB  p90=\(db(q(0.90)))dB  峰=\(db(q(1.0)))dB"

        let nb = seenBands.first?.count ?? 0
        if nb > 0 {
            var parts: [String] = []
            for b in 0..<nb {
                var sh: [Float] = []
                for f in seenBands where f.count == nb {
                    let m = f.reduce(0, +) / Float(nb)
                    if m > 1e-6 { sh.append(f[b] / m) }
                }
                if !sh.isEmpty { sh.sort(); parts.append(String(format: "b%d=%.2f", b, sh[sh.count / 2])) }
            }
            if !parts.isEmpty { line += "\n  频段中位share(越大越独大) " + parts.joined(separator: " ") }
        }
        vlog(line)


        if let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            .appendingPathComponent("VoiceFlow", isDirectory: true) {
            let f = base.appendingPathComponent("warm.log")
            let stamp = ISO8601DateFormatter().string(from: Date())
            if let d = "\(stamp) \(line)\n".data(using: .utf8) {
                if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(d); try? h.close() }
                else { try? d.write(to: f) }
            }
        }
    }
}


@MainActor
final class RecordingHUD {
    static let shared = RecordingHUD()
    let model = HUDModel()

    static let panelWidth: CGFloat = 124
    static let panelHeight: CGFloat = 36
    static let waitingWidth: CGFloat = 340
    static let waitingHeight: CGFloat = 78
    private static let originKey = "hudSavedOrigin"   // UserDefaults(com.voiceflow.mac 域)里的 HUD 位置


    private static var savedOrigin: NSPoint? {
        get {
            guard let s = UserDefaults.standard.string(forKey: originKey) else { return nil }
            let p = s.split(separator: ",").compactMap { Double($0) }
            guard p.count == 2 else { return nil }
            return NSPoint(x: p[0], y: p[1])
        }
        set {
            if let v = newValue {
                UserDefaults.standard.set("\(Int(v.x)),\(Int(v.y))", forKey: originKey)
            } else {
                UserDefaults.standard.removeObject(forKey: originKey)
            }
        }
    }


    func drag(by delta: CGSize) {
        guard let panel else { return }
        let o = panel.frame.origin
        panel.setFrameOrigin(NSPoint(x: o.x + delta.width, y: o.y - delta.height))
    }

    func endDrag() {
        guard let panel else { return }
        Self.savedOrigin = panel.frame.origin
    }




    private static let hudLevel: NSWindow.Level = .screenSaver


    private static let hudBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    private var panel: NSPanel?
    private var onCancel: (() -> Void)?
    private var onConfirm: (() -> Void)?
    private var onUseTranscript: (() -> Void)?
    private var presentationID = UUID()
    private var onScreen = false                  // 悬浮条此刻是否该在屏上 —— gate 跨 Space 的重申,别在没录音时乱亮
    private var spaceObserver: NSObjectProtocol?  // 监听切 Space:治「三指滑进别家全屏 Space 没跟过来」的偶发老毛病

    func show(onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        presentationID = UUID()
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        model.reset()
        model.active = true
        if panel == nil { panel = makePanel() }
        resizePanel(width: Self.panelWidth, height: Self.panelHeight)
        setupSpaceFollowIfNeeded()


        panel?.collectionBehavior = Self.hudBehavior
        panel?.level = Self.hudLevel
        positionPanel()
        panel?.orderFrontRegardless()
        onScreen = true
    }


    func preload() {
        if panel == nil { panel = makePanel() }
        setupSpaceFollowIfNeeded()
    }

    func startProcessing() { model.processing = true }
    func showPolishWait(onUseTranscript: @escaping () -> Void, onCancel: @escaping () -> Void) {
        guard onScreen, model.processing else { return }
        self.onUseTranscript = onUseTranscript
        self.onCancel = onCancel
        guard !model.slowPolish else { return }
        model.slowPolish = true
        resizePanel(width: Self.waitingWidth, height: Self.waitingHeight)
    }
    func usingTranscript() { model.usingTranscript = true }
    func push(_ rms: Float, _ bands: [Float]) { model.push(rms, bands) }
    func hide() {
        onScreen = false
        presentationID = UUID()
        onUseTranscript = nil
        model.active = false
        panel?.orderOut(nil)
        model.reset()
    }


    func finish() {
        model.visible = false
        let current = presentationID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self, self.presentationID == current else { return }
            self.hide()
        }
    }

    private func makePanel() -> NSPanel {
        let view = WaveformHUD(
            model: model,
            onCancel: { [weak self] in self?.onCancel?() },
            onConfirm: { [weak self] in self?.onConfirm?() },
            onUseTranscript: { [weak self] in self?.onUseTranscript?() }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = Self.hudLevel
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        panel.collectionBehavior = Self.hudBehavior
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
        panel.contentView = host
        return panel
    }

    private func positionPanel() {
        guard let panel else { return }


        if let saved = Self.savedOrigin {
            panel.setFrameOrigin(saved)
            return
        }
        let mouse = NSEvent.mouseLocation        // 全局坐标,左下原点
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 76))
    }

    private func resizePanel(width: CGFloat, height: CGFloat) {
        guard let panel else { return }
        var frame = NSRect(x: panel.frame.midX - width / 2, y: panel.frame.minY, width: width, height: height)
        if let screen = panel.screen ?? NSScreen.main {
            let bounds = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - width)
            frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - height)
        }
        panel.setFrame(frame, display: true)
    }





    private func setupSpaceFollowIfNeeded() {
        guard spaceObserver == nil else { return }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.reassertForCurrentSpace() }
        }
    }


    private func reassertForCurrentSpace() {
        guard onScreen, let panel else { return }
        panel.collectionBehavior = Self.hudBehavior
        panel.level = Self.hudLevel
        positionPanel()
        panel.orderFrontRegardless()
    }
}

struct WaveformHUD: View {
    @ObservedObject var model: HUDModel
    let onCancel: () -> Void
    let onConfirm: () -> Void
    var onUseTranscript: () -> Void = {}

    var body: some View {
        Group {
            if model.slowPolish { waitingView }
            else if model.processing { processingView } else { recordingView }
        }
        .frame(width: model.slowPolish ? RecordingHUD.waitingWidth : RecordingHUD.panelWidth,
               height: model.slowPolish ? RecordingHUD.waitingHeight : RecordingHUD.panelHeight)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.hud, style: .continuous).fill(Theme.Palette.hudBg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.hud, style: .continuous).strokeBorder(Theme.Palette.hudBorder, lineWidth: 1))


        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { g in RecordingHUD.shared.drag(by: g.translation) }
                .onEnded { _ in RecordingHUD.shared.endDrag() }
        )
        .opacity(model.visible ? 1 : 0)
        .scaleEffect(model.visible ? 1 : 0.9)
        .animation(.easeOut(duration: 0.25), value: model.visible)
    }


    private var waitingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model.usingTranscript
                     ? L("正在采用转写…", "Using your transcript…")
                     : L("仍在等待润色…", "Still waiting for refinement…"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.hudText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(action: onCancel) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .foregroundStyle(Theme.Palette.hudText)
                .buttonStyle(.plain)
                .help(L("取消本次输入（Esc）", "Cancel this dictation (Esc)"))
                .accessibilityLabel(L("取消本次输入", "Cancel dictation"))
            }
            Button(action: onUseTranscript) {
                Text(L("先用转写", "Use transcript instead"))
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .foregroundStyle(Theme.Palette.accentInk)
                    .background(Theme.Palette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.usingTranscript)
            .opacity(model.usingTranscript ? 0.5 : 1)
        }
        .padding(.horizontal, 14)
    }

    private var recordingView: some View {
        HStack(spacing: 6) {
            iconButton("xmark", bg: AnyShapeStyle(Theme.Palette.hudElevated), fg: Theme.Palette.hudText.opacity(0.6), action: onCancel)
            EqualizerBars(levels: model.levels, active: model.active).frame(width: 40)
            iconButton("checkmark", bg: AnyShapeStyle(Theme.Palette.accent), fg: Theme.Palette.accentInk, action: onConfirm)
        }
        .padding(.horizontal, 6)  // 内边距保圆角:按钮 30 高 vs 框 36,上下 3px 贴框;左右 6px 不飘出
    }


    private var processingView: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !model.active)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width
                let seg = w * 0.42
                let p = (sin(t * 2.0) + 1) / 2          // 0..1 缓动往返
                let x = (w - seg) * CGFloat(p)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.hudElevated)
                    Capsule().fill(Theme.Palette.accent).frame(width: seg).offset(x: x)
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 16)
    }

    private func iconButton(_ icon: String, bg: AnyShapeStyle, fg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(bg)
                Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(fg)
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
    }
}





struct EqualizerBars: View {
    var levels: [CGFloat]        // 每个频段的柱高(0..1;已在 HUDModel.push 里 = 整体响度 × 频谱相对能量)
    var active: Bool             // 预加载/隐藏时暂停时钟；只在 HUD 真正显示时刷新颜色

    private struct RGB {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        init(_ color: Color) {
            let value = NSColor(color).usingColorSpace(.sRGB) ?? .white
            red = value.redComponent
            green = value.greenComponent
            blue = value.blueComponent
        }
    }


    private static let spectrumRGB = Theme.Palette.spectrum.map(RGB.init)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !active)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let n = max(levels.count, 1)
            HStack(spacing: 1.5) {
                ForEach(0..<levels.count, id: \.self) { i in

                    let h = max(2.5, min(23, 2.5 + levels[i] * 22))
                    Capsule().fill(flowColor(i, n, t)).frame(width: 3.0, height: h)
                }
            }
            .frame(height: 24, alignment: .center)
        }
    }


    private func flowColor(_ i: Int, _ n: Int, _ t: Double) -> Color {
        let s = Self.spectrumRGB
        let cnt = s.count
        let pos = (Double(i) / Double(n) * Double(cnt) + t * 0.8).truncatingRemainder(dividingBy: Double(cnt))
        let a = Int(pos) % cnt
        let b = (a + 1) % cnt
        let f = CGFloat(pos - Double(Int(pos)))
        return Color(.sRGB,
                     red: Double(s[a].red + (s[b].red - s[a].red) * f),
                     green: Double(s[a].green + (s[b].green - s[a].green) * f),
                     blue: Double(s[a].blue + (s[b].blue - s[a].blue) * f),
                     opacity: 1)
    }
}
