import CoreGraphics
import Foundation
import ImageIO
import MascotCore
import UniformTypeIdentifiers

// App Icon: Pip in finished look on black rounded rectangle plate, static pose, drawn using MascotCore look data; icon updates when Pip changes.
// Usage: mascot-icon <output-dir.iconset>; run.sh then builds AppIcon.icns with iconutil.
// Eye mapping onto sphere matches App's layer tree (MascotFigureView: rotate planar eye onto sphere by lat/long, then apply roll -> pitch -> yaw of pose);
// calculated here using orthographic projection without Core Animation.
// @see https://developer.apple.com/design/human-interface-guidelines/app-icons (macOS: 824 rounded rectangle inside 1024 canvas)
// @see https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Optimizing/Optimizing.html (iconset filenames)

let look = Look.finished

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: mascot-icon <output-dir.iconset>\n".utf8))
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
    FileHandle.standardError.write(Data("mascot-icon: \(error)\n".utf8))
    exit(1)
}

func render(side: Int) -> CGImage {
    let s = CGFloat(side)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { preconditionFailure("Parameters are constant, creation must succeed") }
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1) // +y downward matching canvas
    func gradient(_ top: RGB, _ bottom: RGB) -> CGGradient {
        CGGradient(colorsSpace: space, colors: [top.cg, bottom.cg] as CFArray, locations: [0, 1])!
    }

    // Plate: with drop shadow, gradient from dark grey to near black matching notch color
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

    // Center body with decorations onto plate
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
    guard let image = ctx.makeImage() else { preconditionFailure("Bitmap context must yield an image") }
    return image
}

/// Point on eye contour offset by d from rest center, mapped onto sphere and rotated by pose, as projected onto canvas
func onSphere(_ d: CGPoint, rest: CGPoint) -> CGPoint {
    let c = Anatomy.bodyCenter, R = Double(Anatomy.bodyRadius)
    let (pitch, yaw) = Sphere.place(rest)
    let lat = -pitch
    // Planar eye contour at distance R in front of sphere center: rotate around x-axis to latitude, then y-axis to longitude
    var y = Double(d.y) * cos(lat) + R * sin(lat)
    var z = -Double(d.y) * sin(lat) + R * cos(lat)
    var x = Double(d.x) * cos(yaw) + z * sin(yaw)
    z = -Double(d.x) * sin(yaw) + z * cos(yaw)
    // Pose orientation: roll (positive = clockwise) -> pitch (positive = looking up) -> yaw (positive = looking right), same as HeadPose
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
