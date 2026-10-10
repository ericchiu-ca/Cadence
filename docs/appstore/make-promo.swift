// Cadence App Store promotional screenshots: caption + framed device on a colour wash.
// Usage: swift docs/appstore/make-promo.swift docs/appstore docs/appstore/promo\n// Captions per language are in docs/appstore/captions.json.
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
    func lineCount(_ w: CGFloat) -> Int {
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: w, height: 4000), transform: nil), nil)
        return CFArrayGetCount(CTFrameGetLines(frame))
    }
    // Balance wrapped text: narrow the box while the line count holds, so a
    // second line never carries a single word or character.
    var w = width
    let lines = lineCount(width)
    if lines > 1 { while w > width / 2, lineCount(w - 8) == lines { w -= 8 } }
    let size = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil, CGSize(width: w, height: 2000), nil)
    let rect = CGRect(x: centerX - w / 2, y: canvasH - top - size.height, width: w, height: ceil(size.height) + 2)
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
    let subTop = 150 + th + d.subSize * 0.7
    let subH = drawText(c, s.sub, font: font(d.subSize, bold: false, lang: s.lang), color: rgb(1, 1, 1, 0.72), width: d.textWidth, centerX: d.W / 2, top: subTop, canvasH: d.H, lineSpacing: d.subSize * 0.2)
    if subTop + subH > d.top - d.bezel - 40 { print("warning: caption crowds the device in \(s.lang) \(s.out): \(s.title)") }

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
// captions.json: { "<language>": { "iphone": [[title, subtitle], ...], "ipad": [...] } }
// Source captures, in caption order.
let shots = ["iphone": ["iphone-1-player.jpg", "iphone-3-lyrics.jpg", "iphone-4-library.jpg", "iphone-2-album.jpg", "iphone-5-queue.jpg"],
             "ipad": ["ipad-1-player.jpg", "ipad-3-lyrics.jpg", "ipad-2-library.jpg"]]
let names = ["player", "lyrics", "library", "album", "queue"]
let captionData = try! Data(contentsOf: URL(fileURLWithPath: src + "/captions.json"))
let captions = try! JSONDecoder().decode([String: [String: [[String]]]].self, from: captionData)
for (lang, devices) in captions.sorted(by: { $0.key < $1.key }) {
    for (dir, dev) in [("iphone", phone), ("ipad", pad)] {
        let out = "\(outRoot)/\(lang)/\(dir)"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for (i, caption) in devices[dir]!.enumerated() {
            let file = String(format: "%02d-%@.jpg", i + 1, names[i])
            render(Spec(shot: shots[dir]![i], out: file, title: caption[0], sub: caption[1], lang: lang), dev, src: src, out: out)
        }
    }
}
print("ok")
