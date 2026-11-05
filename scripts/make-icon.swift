// 生成 App 图标：蓝色渐变圆角方块 + 两道首尾相接的同步箭头。
// 用法：swift scripts/make-icon.swift <输出 1024px png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

    // macOS 图标网格：824×824 的圆角方块居中，留出投影空间
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let colors = [
        NSColor(red: 0.20, green: 0.78, blue: 1.00, alpha: 1).cgColor,
        NSColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1).cgColor,
        NSColor(red: 0.36, green: 0.22, blue: 0.85, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 150, y: 924), end: CGPoint(x: 874, y: 100), options: [])
    ctx.restoreGState()

    // 两道弧形箭头：上弧从左到右、下弧从右到左
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 230
    let lineWidth: CGFloat = 64
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)

    func arrow(from start: CGFloat, to end: CGFloat) {
        let a0 = start * .pi / 180, a1 = end * .pi / 180
        ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: true)
        ctx.strokePath()
        // 箭头：在终点沿顺时针切线方向
        let tip = CGPoint(x: center.x + radius * cos(a1), y: center.y + radius * sin(a1))
        let dir = CGPoint(x: sin(a1), y: -cos(a1))
        let normal = CGPoint(x: cos(a1), y: sin(a1))
        let head: CGFloat = 96, half: CGFloat = 78
        ctx.move(to: CGPoint(x: tip.x + dir.x * head, y: tip.y + dir.y * head))
        ctx.addLine(to: CGPoint(x: tip.x + normal.x * half, y: tip.y + normal.y * half))
        ctx.addLine(to: CGPoint(x: tip.x - normal.x * half, y: tip.y - normal.y * half))
        ctx.closePath()
        ctx.fillPath()
    }
    arrow(from: 170, to: 30)
    arrow(from: -10, to: -150)
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
