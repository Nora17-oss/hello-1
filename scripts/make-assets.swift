import AppKit
import Foundation

let assets = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func png(size: Int, draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.cgContext.scaleBy(x: CGFloat(size) / 512, y: CGFloat(size) / 512)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let data = png(size: size * scale) {
            NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 16, y: 16, width: 480, height: 480), xRadius: 104, yRadius: 104).fill()
            let colors: [NSColor] = [.systemTeal, .systemPink, .systemBlue, .systemGreen]
            for i in 0..<4 {
                colors[i].withAlphaComponent(0.85).setFill()
                let rect = NSRect(x: 82 + (i % 2) * 184, y: 82 + (i / 2) * 184, width: 164, height: 164)
                NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24).fill()
                NSColor.white.withAlphaComponent(0.8).setFill()
                NSRect(x: rect.minX + 24, y: rect.maxY - 46, width: 88, height: 12).fill()
                NSColor.white.withAlphaComponent(0.4).setFill()
                NSRect(x: rect.minX + 24, y: rect.maxY - 76, width: 116, height: 10).fill()
            }
        }
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
if CommandLine.arguments.count > 2 {
    let root = URL(fileURLWithPath: CommandLine.arguments[2])
    guard !FileManager.default.fileExists(atPath: root.path) else {
        fatalError("Demo directory must be new; existing data will not be overwritten.")
    }
    let desktop = root.appendingPathComponent("Desktop")
    let project = root.appendingPathComponent("Projects/小红书杂货铺")
    try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
    try Data("DesktopOrganizer disposable fixtures v1".utf8)
        .write(to: root.appendingPathComponent(".desktop-organizer-demo"))
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Projects/秋季服装企划"), withIntermediateDirectories: true)
    let picture = png(size: 512) {
        NSColor(calibratedRed: 0.91, green: 0.95, blue: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 512, height: 512).fill()
        NSColor.systemTeal.setFill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 172, y: 414)); path.line(to: NSPoint(x: 88, y: 346))
        path.line(to: NSPoint(x: 138, y: 276)); path.line(to: NSPoint(x: 169, y: 301))
        path.line(to: NSPoint(x: 157, y: 107)); path.line(to: NSPoint(x: 355, y: 107))
        path.line(to: NSPoint(x: 343, y: 301)); path.line(to: NSPoint(x: 374, y: 276))
        path.line(to: NSPoint(x: 424, y: 346)); path.line(to: NSPoint(x: 340, y: 414)); path.close(); path.fill()
        NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 218, y: 384, width: 76, height: 60)).fill()
        ("样衣参考" as NSString).draw(at: NSPoint(x: 175, y: 38),
            withAttributes: [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.darkGray])
    }
    try picture.write(to: desktop.appendingPathComponent("秋季样衣参考.png"))
    try Data("面料、版型与颜色待确认。\n这是一份隔离测试文件。".utf8).write(to: desktop.appendingPathComponent("下单前待确认事项.txt"))
    try Data("测试长文件名".utf8).write(to: desktop.appendingPathComponent("这是用于检查看板中文长文件名是否能够正确换行且不会遮挡相邻按钮的测试文件.txt"))
    try Data("unclassified fixture".utf8).write(to: desktop.appendingPathComponent("临时素材.data"))
    let folder = desktop.appendingPathComponent("活动素材包")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("文件夹整体移动，内部结构不变。".utf8).write(to: folder.appendingPathComponent("说明.txt"))
    var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 595)
    let pdfURL = desktop.appendingPathComponent("项目参考资料.pdf")
    let context = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil)!
    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    ("项目参考资料\n\n秋季服装企划\n面料 / 版型 / 色彩" as NSString).draw(in: NSRect(x: 40, y: 320, width: 340, height: 220),
        withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage(); context.closePDF()
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    zip.arguments = ["-c", "-k", "--keepParent", folder.path, desktop.appendingPathComponent("素材备份.zip").path]
    try zip.run(); zip.waitUntilExit()
    guard zip.terminationStatus == 0 else { fatalError("Unable to create fixture archive") }
    print("Demo fixtures: \(root.path)")
}
