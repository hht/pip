import CoreGraphics
import Foundation
import ImageIO
import MascotCore
import UniformTypeIdentifiers

// App 图标：黑底圆角方块上一只 finished 造型的 Pip，静止姿态，按 MascotCore 的造型数据画，Pip 改了图标跟着变。
// 用法：mascot-icon <输出目录.iconset>；run.sh 再用 iconutil 合成 AppIcon.icns。
// 眼睛贴球面的算法照 App 的图层树（MascotFigureView：先按经纬度把平面眼形转到球面，再按造型的朝向 roll → pitch → yaw），
// 这里没有 Core Animation，用正交投影自己算。
// @see https://developer.apple.com/design/human-interface-guidelines/app-icons （macOS：1024 画布里 824 的圆角方块）
// @see https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Optimizing/Optimizing.html （iconset 的文件名）

let look = Look.finished

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("用法：mascot-icon <输出目录.iconset>\n".utf8))
    exit(64) // EX_USAGE
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try write(render(side: points * scale), to: dir.appendingPathComponent(name))
        }
    }
} catch {
    FileHandle.standardError.write(Data("mascot-icon：\(error)\n".utf8))
    exit(1)
}

func render(side: Int) -> CGImage {
    let s = CGFloat(side)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { preconditionFailure("参数是写死的，一定建得出来") }
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1) // 和画布一样 +y 向下
    func gradient(_ top: RGB, _ bottom: RGB) -> CGGradient {
        CGGradient(colorsSpace: space, colors: [top.cg, bottom.cg] as CFArray, locations: [0, 1])!
    }

    // 底板：带一点投影，从上到下由深灰到近黑，和刘海一个颜色
    let box = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let plate = CGPath(roundedRect: box, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s * 10 / 1024), blur: s * 24 / 1024, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(plate)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(plate)
    ctx.clip()
    ctx.drawLinearGradient(gradient(RGB(0x2A2B30), RGB(0x0B0B0D)), start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY), options: [])

    // 身体加装饰的外框居中放进底板
    let c = Anatomy.bodyCenter, r = Anatomy.bodyRadius
    let deco = look.decoration
    let body = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    let content = deco.reduce(body) { $0.union($1.spec.path.boundingBoxOfPath.insetBy(dx: -0.6, dy: -0.6)) }
    let unit = min(box.width * 0.62 / (2 * r), box.width * 0.72 / max(content.width, content.height))
    var map = CGAffineTransform(translationX: s / 2 - content.midX * unit, y: s / 2 - content.midY * unit).scaledBy(x: unit, y: unit)

    ctx.saveGState()
    ctx.addPath(CGPath(ellipseIn: body, transform: &map))
    ctx.clip()
    ctx.drawLinearGradient(gradient(look.gradient.top, look.gradient.bottom),
                           start: CGPoint(x: 0, y: body.minY).applying(map), end: CGPoint(x: 0, y: body.maxY).applying(map), options: [])
    ctx.setFillColor(RGB.ink.cg)
    let eyes = look.eyes
    for (rest, outline) in [(Anatomy.leftEye, eyes.left), (Anatomy.rightEye, eyes.right)] {
        let path = CGMutablePath()
        path.addLines(between: outline.map { onSphere($0 * Eyes.scale, rest: rest).applying(map) })
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
    }
    ctx.restoreGState()

    for part in deco {
        let spec = part.spec
        ctx.saveGState()
        ctx.setAlpha(spec.opacity)
        ctx.addPath(spec.path.copy(using: &map)!)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setFillColor(spec.color.cg)
        ctx.setStrokeColor(spec.color.cg)
        switch spec.paint {
        case .fill: ctx.fillPath()
        case .stroke(let w): ctx.setLineWidth(w * unit); ctx.strokePath()
        case .fillAndStroke(let w): ctx.setLineWidth(w * unit); ctx.drawPath(using: .fillStroke)
        }
        ctx.restoreGState()
    }
    guard let image = ctx.makeImage() else { preconditionFailure("位图上下文一定出得了图") }
    return image
}

/// 眼形上相对静止中心偏 d 的点，贴到球面、按造型朝向转过之后，正面看过去在画布上的位置
func onSphere(_ d: CGPoint, rest: CGPoint) -> CGPoint {
    let c = Anatomy.bodyCenter, R = Double(Anatomy.bodyRadius)
    let (pitch, yaw) = Sphere.place(rest)
    let lat = -pitch
    // 平面眼形在球心前方 R 处：先绕 x 轴转到纬度，再绕 y 轴转到经度
    var y = Double(d.y) * cos(lat) + R * sin(lat)
    var z = -Double(d.y) * sin(lat) + R * cos(lat)
    var x = Double(d.x) * cos(yaw) + z * sin(yaw)
    z = -Double(d.x) * sin(yaw) + z * cos(yaw)
    // 造型朝向：roll（正 = 顺时针）→ pitch（正 = 抬头）→ yaw（正 = 脸朝右），约定同 HeadPose
    let p = look.pose
    (x, y) = (x * cos(p.roll) - y * sin(p.roll), x * sin(p.roll) + y * cos(p.roll))
    (y, z) = (y * cos(p.pitch) - z * sin(p.pitch), y * sin(p.pitch) + z * cos(p.pitch))
    x = x * cos(p.yaw) + z * sin(p.yaw)
    return CGPoint(x: c.x + x, y: c.y + y)
}

func write(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
}

private func * (p: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: p.x * k, y: p.y * k) }
