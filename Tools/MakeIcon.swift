// 用 CoreGraphics 矢量绘制 App 图标，每个尺寸独立渲染保证锐利
import AppKit
import ImageIO
import UniformTypeIdentifiers

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

/// 盾牌路径（单位坐标，y 向下）
func shieldPath(x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let cx = (x0 + x1) / 2
    let hw = (x1 - x0) / 2
    let shoulder = y0 + (y1 - y0) * 0.10
    let waist = y0 + (y1 - y0) * 0.46
    let r = hw * 0.22                       // 肩部圆角
    p.move(to: CGPoint(x: cx, y: y0))
    p.addLine(to: CGPoint(x: x1 - r * 0.4, y: shoulder - r * 0.5))
    p.addQuadCurve(to: CGPoint(x: x1, y: shoulder + r * 0.5),
                   control: CGPoint(x: x1, y: shoulder - r * 0.1))
    p.addLine(to: CGPoint(x: x1, y: waist))
    p.addCurve(to: CGPoint(x: cx, y: y1),                 // 收成尖底
               control1: CGPoint(x: x1, y: waist + (y1 - waist) * 0.48),
               control2: CGPoint(x: cx + hw * 0.46, y: y1 - (y1 - waist) * 0.06))
    p.addCurve(to: CGPoint(x: x0, y: waist),
               control1: CGPoint(x: cx - hw * 0.46, y: y1 - (y1 - waist) * 0.06),
               control2: CGPoint(x: x0, y: waist + (y1 - waist) * 0.48))
    p.addLine(to: CGPoint(x: x0, y: shoulder + r * 0.5))
    p.addQuadCurve(to: CGPoint(x: x0 + r * 0.4, y: shoulder - r * 0.5),
                   control: CGPoint(x: x0, y: shoulder - r * 0.1))
    p.closeSubpath()
    return p
}

/// 钥匙孔：圆 + 下方梯形
func keyholePath(cx: CGFloat, cy: CGFloat, r: CGFloat, tail: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    let top = cy + r * 0.55
    let bot = cy + tail
    p.move(to: CGPoint(x: cx - r * 0.52, y: top))
    p.addLine(to: CGPoint(x: cx + r * 0.52, y: top))
    p.addLine(to: CGPoint(x: cx + r * 0.95, y: bot))
    p.addLine(to: CGPoint(x: cx - r * 0.95, y: bot))
    p.closeSubpath()
    return p
}

func plusPath(cx: CGFloat, cy: CGFloat, arm: CGFloat, thick: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addRoundedRect(in: CGRect(x: cx - arm, y: cy - thick/2, width: arm*2, height: thick),
                     cornerWidth: thick/2, cornerHeight: thick/2)
    p.addRoundedRect(in: CGRect(x: cx - thick/2, y: cy - arm, width: thick, height: arm*2),
                     cornerWidth: thick/2, cornerHeight: thick/2)
    return p
}

func render(px: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // 翻转成 y 向下的单位坐标系
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: CGFloat(px), y: -CGFloat(px))
    ctx.setAllowsAntialiasing(true)

    let inset: CGFloat = 0.075
    let body = CGRect(x: inset, y: inset, width: 1 - inset*2, height: 1 - inset*2)
    let squircle = CGPath(roundedRect: body, cornerWidth: 0.2, cornerHeight: 0.2, transform: nil)

    // 底座阴影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -0.018), blur: 0.035,
                  color: rgb(0, 0, 0, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(rgb(90, 110, 250))
    ctx.fillPath()
    ctx.restoreGState()

    // 主渐变
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs,
                          colors: [rgb(108, 140, 255), rgb(88, 86, 235), rgb(120, 58, 220)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0.15, y: inset),
                           end: CGPoint(x: 0.9, y: 1 - inset), options: [])
    // 顶部高光
    let gloss = CGGradient(colorsSpace: cs,
                           colors: [rgb(255, 255, 255, 0.30), rgb(255, 255, 255, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0.5, y: inset),
                           end: CGPoint(x: 0.5, y: 0.62), options: [])
    ctx.restoreGState()

    // 内描边
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 0.006, dy: 0.006),
                       cornerWidth: 0.195, cornerHeight: 0.195, transform: nil))
    ctx.setStrokeColor(rgb(255, 255, 255, 0.28))
    ctx.setLineWidth(0.011)
    ctx.strokePath()

    // 盾牌
    let shield = shieldPath(x0: 0.285, x1: 0.715, y0: 0.200, y1: 0.790)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 0.012), blur: 0.03, color: rgb(20, 20, 80, 0.45))
    ctx.addPath(shield)
    ctx.setFillColor(rgb(255, 255, 255, 0.97))
    ctx.fillPath()
    ctx.restoreGState()

    // 钥匙孔（挖空，露出底色）
    ctx.saveGState()
    ctx.addPath(keyholePath(cx: 0.5, cy: 0.430, r: 0.066, tail: 0.165))
    ctx.clip()
    let inner = CGGradient(colorsSpace: cs,
                           colors: [rgb(96, 118, 250), rgb(112, 62, 216)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(inner, start: CGPoint(x: 0.4, y: 0.36),
                           end: CGPoint(x: 0.6, y: 0.66), options: [])
    ctx.restoreGState()

    // 右下角绿色 "+" 徽章
    let bx: CGFloat = 0.760, by: CGFloat = 0.755, br: CGFloat = 0.140
    ctx.setFillColor(rgb(255, 255, 255, 0.95))
    ctx.fillEllipse(in: CGRect(x: bx - br - 0.022, y: by - br - 0.022,
                               width: (br + 0.022) * 2, height: (br + 0.022) * 2))
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: bx - br, y: by - br, width: br*2, height: br*2))
    ctx.clip()
    let badge = CGGradient(colorsSpace: cs,
                           colors: [rgb(78, 220, 128), rgb(24, 168, 84)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(badge, start: CGPoint(x: bx - br, y: by - br),
                           end: CGPoint(x: bx + br, y: by + br), options: [])
    ctx.restoreGState()
    ctx.addPath(plusPath(cx: bx, cy: by, arm: 0.070, thick: 0.033))
    ctx.setFillColor(rgb(255, 255, 255))
    ctx.fillPath()

    return ctx.makeImage()!
}

func write(_ img: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dst = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for (pt, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let px = pt * scale
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    write(render(px: px), to: (outDir as NSString).appendingPathComponent(name))
}
write(render(px: 1024), to: (outDir as NSString).appendingPathComponent("../icon-preview.png"))
print("图标已生成：\(outDir)")
