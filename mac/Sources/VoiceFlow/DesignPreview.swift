import AppKit
import SwiftUI








enum DesignPreview {
    private struct Spec {
        let view: AnyView
        let size: CGSize
        let backdrop: Color?
    }

    @MainActor
    static func render(which: String, to outPath: String) {
        let spec = spec(for: which)
        let canvas = ZStack {
            if let bg = spec.backdrop { bg }
            spec.view
        }
        .frame(width: spec.size.width, height: spec.size.height)
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 2.0

        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let bm = NSBitmapImageRep(data: tiff),
              let png = bm.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("[preview] 渲染失败:ImageRenderer 没出图\n".utf8))
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: outPath))
            FileHandle.standardError.write(Data("[preview] ✅ 写出 \(outPath)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("[preview] 写盘失败 \(error)\n".utf8))
        }
    }

    @MainActor
    private static func spec(for which: String) -> Spec {
        switch which {
        case "hud-wait", "hud-use-transcript":
            let m = HUDModel()
            m.processing = true
            m.slowPolish = true
            m.usingTranscript = which == "hud-use-transcript"
            return Spec(view: AnyView(WaveformHUD(model: m, onCancel: {}, onConfirm: {})),
                        size: CGSize(width: 396, height: 130), backdrop: Theme.Palette.bgBase)
        case "hud":
            let m = HUDModel()
            m.levels = [0.28, 0.42, 0.6, 0.82, 0.95, 1.0, 0.95, 0.82, 0.6, 0.42, 0.28].map { $0 * 0.8 }
            return Spec(view: AnyView(WaveformHUD(model: m, onCancel: {}, onConfirm: {})),
                        size: CGSize(width: 360, height: 180),
                        backdrop: Color(red: 0.55, green: 0.55, blue: 0.58))
        case "home":
            return Spec(view: AnyView(ZStack(alignment: .top) { Theme.Palette.bgBase; HomeView().homeContent }),
                        size: CGSize(width: 880, height: 780),
                        backdrop: nil)
        case "icon-green":
            return Spec(view: AnyView(AppIconView(variant: .green)), size: CGSize(width: 512, height: 512), backdrop: nil)
        case "icon-dark":
            return Spec(view: AnyView(AppIconView(variant: .dark)), size: CGSize(width: 512, height: 512), backdrop: nil)
        case "icon-cream":
            return Spec(view: AnyView(AppIconView(variant: .cream)), size: CGSize(width: 512, height: 512), backdrop: nil)
        default:
            return Spec(view: AnyView(Text("未知预览: \(which)").foregroundStyle(.white)),
                        size: CGSize(width: 360, height: 180),
                        backdrop: Color.black)
        }
    }
}
