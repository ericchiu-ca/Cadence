// Cadence App Store promotional screenshots: caption + framed device on a colour wash.
// Usage: swift docs/appstore/make-promo.swift docs/appstore docs/appstore/promo
import Foundation
import CoreGraphics
import CoreText
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let P3 = CGColorSpace(name: CGColorSpace.displayP3)!
let SRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: SRGB, components: [r, g, b, a])! }
func load(_ p: String) -> CGImage { CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!, 0, nil)! }
func save(_ img: CGImage, _ p: String) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: p) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.93] as CFDictionary)
    CGImageDestinationFinalize(d)
}
let ci = CIContext()
/// Average colour of a horizontal band of the screenshot (0 = top).
func average(_ img: CGImage, from: CGFloat, to: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
    let h = CGFloat(img.height), w = CGFloat(img.width)
    let rect = CGRect(x: 0, y: h * (1 - to), width: w, height: h * (to - from))
    let f = CIFilter(name: "CIAreaAverage")!
    f.setValue(CIImage(cgImage: img), forKey: kCIInputImageKey)
    f.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
    var px = [UInt8](repeating: 0, count: 4)
    ci.render(f.outputImage!, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: SRGB)
    return (CGFloat(px[0]) / 255, CGFloat(px[1]) / 255, CGFloat(px[2]) / 255)
}
func boost(_ c: (CGFloat, CGFloat, CGFloat), _ k: CGFloat, floor: CGFloat = 0) -> CGColor {
    rgb(max(floor, min(1, c.0 * k)), max(floor, min(1, c.1 * k)), max(floor, min(1, c.2 * k)))
}

func font(_ size: CGFloat, bold: Bool, lang: String) -> CTFont {
    CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, lang as CFString)!
}
/// Centred, wrapped text drawn with its top at `top` (y measured from the top edge).
func drawText(_ c: CGContext, _ s: String, font f: CTFont, color: CGColor, width: CGFloat, centerX: CGFloat, top: CGFloat, canvasH: CGFloat, lineSpacing: CGFloat) -> CGFloat {
    var align = CTTextAlignment.center
    var spacing = lineSpacing
    let para = withUnsafePointer(to: &align) { a in
        withUnsafePointer(to: &spacing) { sp in
            let settings = [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a),
                            CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: sp)]
            return CTParagraphStyleCreate(settings, settings.count)
        }
    }
    let attr = NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para])
    let fs = CTFramesetterCreateWithAttributedString(attr)
    let size = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: 2000), nil)
    let rect = CGRect(x: centerX - width / 2, y: canvasH - top - size.height, width: width, height: ceil(size.height) + 2)
    let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, c)
    return size.height
}

struct Spec { let shot: String; let out: String; let title: String; let sub: String; let lang: String }
struct Device { let W: CGFloat; let H: CGFloat; let scale: CGFloat; let bezel: CGFloat; let screenRadius: CGFloat; let top: CGFloat; let titleSize: CGFloat; let subSize: CGFloat; let textWidth: CGFloat }
let phone = Device(W: 1206, H: 2622, scale: 0.74, bezel: 24, screenRadius: 118, top: 570, titleSize: 96, subSize: 46, textWidth: 1040)
let pad = Device(W: 2064, H: 2752, scale: 0.74, bezel: 30, screenRadius: 52, top: 560, titleSize: 112, subSize: 54, textWidth: 1700)

func render(_ s: Spec, _ d: Device, src: String, out: String) {
    let shot = load(src + "/" + s.shot)
    let W = Int(d.W), H = Int(d.H)
    let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: SRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.interpolationQuality = .high
    // Background: the screenshot's own colours, deepened, top to bottom.
    let topC = average(shot, from: 0.0, to: 0.35), botC = average(shot, from: 0.55, to: 1.0)
    let g = CGGradient(colorsSpace: SRGB, colors: [boost(topC, 0.95, floor: 0.04), boost(botC, 0.45, floor: 0.02), rgb(0.02, 0.02, 0.03)] as CFArray, locations: [0, 0.6, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: d.H), end: CGPoint(x: 0, y: 0), options: [])
    // Soft glow behind the device
    let glow = CGGradient(colorsSpace: SRGB, colors: [boost(topC, 1.4, floor: 0.1).copy(alpha: 0.55)!, rgb(0, 0, 0, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: CGPoint(x: d.W / 2, y: d.H * 0.55), startRadius: 0, endCenter: CGPoint(x: d.W / 2, y: d.H * 0.55), endRadius: d.W * 0.75, options: [])

    // Caption
    let th = drawText(c, s.title, font: font(d.titleSize, bold: true, lang: s.lang), color: rgb(1, 1, 1), width: d.textWidth, centerX: d.W / 2, top: 150, canvasH: d.H, lineSpacing: d.titleSize * 0.08)
    _ = drawText(c, s.sub, font: font(d.subSize, bold: false, lang: s.lang), color: rgb(1, 1, 1, 0.72), width: d.textWidth, centerX: d.W / 2, top: 150 + th + d.subSize * 0.7, canvasH: d.H, lineSpacing: d.subSize * 0.2)

    // Device
    let sw = CGFloat(shot.width) * d.scale * (d.W / CGFloat(shot.width)) , sh = sw * CGFloat(shot.height) / CGFloat(shot.width)
    let screen = CGRect(x: (d.W - sw) / 2, y: d.H - d.top - sh, width: sw, height: sh)
    let body = screen.insetBy(dx: -d.bezel, dy: -d.bezel)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: d.screenRadius + d.bezel, cornerHeight: d.screenRadius + d.bezel, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -30), blur: 90, color: rgb(0, 0, 0, 0.6))
    c.addPath(bodyPath); c.setFillColor(rgb(0.07, 0.07, 0.08)); c.fillPath()
    c.restoreGState()
    c.addPath(bodyPath); c.setStrokeColor(rgb(1, 1, 1, 0.18)); c.setLineWidth(3); c.strokePath()
    c.saveGState()
    c.addPath(CGPath(roundedRect: screen, cornerWidth: d.screenRadius, cornerHeight: d.screenRadius, transform: nil)); c.clip()
    c.draw(shot, in: screen)
    c.restoreGState()
    save(c.makeImage()!, out + "/" + s.out)
}

let src = CommandLine.arguments[1], outRoot = CommandLine.arguments[2]
let en = "en-US", zh = "zh-Hans"
let phoneSpecs: [(String, String, String, String, String, String)] = [
    ("iphone-1-player.jpg", "01-player.jpg", "Colours from the cover", "The player takes its look from your artwork.", "随封面变色的播放界面", "播放界面的颜色取自你的专辑封面"),
    ("iphone-3-lyrics.jpg", "02-lyrics.jpg", "Lyrics, word by word", "Synced lyrics that light up in time with the song.", "逐字同步的歌词", "歌词随歌曲逐字点亮，点一行即可跳转"),
    ("iphone-4-library.jpg", "03-library.jpg", "Lossless. Offline. Yours.", "FLAC, ALAC, MP3 and more. No account, no ads.", "无损、离线、只属于你", "支持 FLAC、ALAC、MP3 等格式，无需账号，没有广告"),
    ("iphone-2-album.jpg", "04-album.jpg", "Albums that look the part", "Every page built from your own files and artwork.", "好好呈现每一张专辑", "专辑页直接取自你的音乐文件和封面"),
    ("iphone-5-queue.jpg", "05-queue.jpg", "Up next, within reach", "See and reorder the queue right above the controls.", "播放队列触手可及", "接下来播放什么，就在控制按钮上方"),
]
let padSpecs: [(String, String, String, String, String, String)] = [
    ("ipad-1-player.jpg", "01-player.jpg", "Made for iPad too", "A player that fills the big screen with your artwork.", "iPad 上同样出色", "大屏幕上，封面与色彩铺满整个播放界面"),
    ("ipad-3-lyrics.jpg", "02-lyrics.jpg", "Lyrics across the room", "Large, word-by-word lyrics sized for iPad.", "大屏逐字歌词", "为 iPad 放大的逐字同步歌词"),
    ("ipad-2-library.jpg", "03-library.jpg", "Your whole library at a glance", "Recently added albums, artists and playlists.", "整个音乐库，一目了然", "最近添加、艺人与播放列表，尽收眼底"),
]
for (dir, specs, dev) in [("iphone", phoneSpecs, phone), ("ipad", padSpecs, pad)] {
    for (lang, isZh) in [(en, false), (zh, true)] {
        let out = "\(outRoot)/\(lang)/\(dir)"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for s in specs {
            render(Spec(shot: s.0, out: s.1, title: isZh ? s.4 : s.2, sub: isZh ? s.5 : s.3, lang: lang), dev, src: src, out: out)
        }
    }
}
print("ok")
