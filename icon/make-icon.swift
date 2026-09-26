// アプリアイコン（AppIcon.icns）を作るスクリプト
//   swift icon/make-icon.swift            → icon/AppIcon.icns
//   swift icon/make-icon.swift preview.png → 1024px の PNG だけ書き出す（確認用）
// 青紫のグラデーションの角丸四角。右端（＝画面の端）から白い棚がすべり出ていて、
// 棚には写真・書類・フォルダ・リンクのタイルが並ぶ。左からは写真がドラッグされて棚へ向かっている。
import AppKit

let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // 1024 四方の座標で描く
    let k = CGFloat(px) / 1024
    let t = NSAffineTransform()
    t.scale(by: k)
    t.concat()

    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
    }
    func withShadow(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat, _ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(alpha)
        sh.shadowOffset = NSSize(width: 0, height: dy * k)   // 影はデバイス座標なので倍率をかける
        sh.shadowBlurRadius = blur * k
        sh.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    // macOS のアイコンの枠：1024 のうち 824 四方、角の半径 185
    let bg = rr(100, 100, 824, 824, 185)
    withShadow(20, -10, 0.3) { NSColor.black.setFill(); bg.fill() }
    NSGradient(starting: rgb(99, 142, 255), ending: rgb(64, 58, 214))!.draw(in: bg, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    bg.addClip()

    // 画面の端から出ている棚（右側はアイコンの縁で切れる）
    let shelf = rr(500, 290, 520, 470, 56)
    withShadow(40, -14, 0.35) { NSColor.white.setFill(); shelf.fill() }
    rgb(245, 246, 250).setFill()
    shelf.fill()
    // 見出しの線
    rgb(200, 204, 220).setFill()
    rr(548, 706, 120, 22, 11).fill()
    rr(820, 706, 40, 22, 11).fill()

    // タイル 2×2
    let tile: CGFloat = 138, gap: CGFloat = 26
    let x1: CGFloat = 548, x2 = x1 + tile + gap
    let y1: CGFloat = 516, y2 = y1 - tile - gap

    // 写真（空・太陽・山）
    func photo(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        let p = rr(x, y, w, h, 22)
        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        NSGradient(starting: rgb(140, 205, 255), ending: rgb(255, 214, 170))!.draw(in: p, angle: -90)
        rgb(255, 196, 60).setFill()
        NSBezierPath(ovalIn: NSRect(x: x + w * 0.62, y: y + h * 0.58, width: w * 0.22, height: w * 0.22)).fill()
        let m = NSBezierPath()
        m.move(to: NSPoint(x: x - 10, y: y))
        m.line(to: NSPoint(x: x + w * 0.35, y: y + h * 0.55))
        m.line(to: NSPoint(x: x + w * 0.55, y: y + h * 0.32))
        m.line(to: NSPoint(x: x + w * 0.72, y: y + h * 0.45))
        m.line(to: NSPoint(x: x + w + 10, y: y))
        m.close()
        rgb(72, 170, 110).setFill()
        m.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    photo(x1, y1, tile, tile)

    // 書類（折れた角と文字の線）
    let doc = NSBezierPath()
    let dx = x2 + 22, dy = y1, dw = tile - 44, dh = tile, fold: CGFloat = 30
    doc.move(to: NSPoint(x: dx, y: dy))
    doc.line(to: NSPoint(x: dx + dw, y: dy))
    doc.line(to: NSPoint(x: dx + dw, y: dy + dh - fold))
    doc.line(to: NSPoint(x: dx + dw - fold, y: dy + dh))
    doc.line(to: NSPoint(x: dx, y: dy + dh))
    doc.close()
    withShadow(8, -3, 0.18) { NSColor.white.setFill(); doc.fill() }
    rgb(170, 176, 196).setFill()
    for i in 0..<4 {
        rr(dx + 14, dy + 22 + CGFloat(i) * 22, i == 3 ? dw * 0.45 : dw - 28, 9, 4.5).fill()
    }

    // フォルダ
    let fx = x1 + 6, fy = y2 + 14, fw = tile - 12, fh = tile - 34
    rgb(80, 160, 245).setFill()
    rr(fx, fy + fh - 16, fw * 0.45, 34, 12).fill()
    NSGradient(starting: rgb(120, 190, 255), ending: rgb(70, 150, 240))!.draw(in: rr(fx, fy, fw, fh, 14), angle: -90)

    // リンク
    let lp = rr(x2, y2, tile, tile, 22)
    rgb(226, 230, 244).setFill()
    lp.fill()
    let cfg = NSImage.SymbolConfiguration(pointSize: 70, weight: .semibold)
        .applying(.init(paletteColors: [rgb(80, 90, 220)]))
    if let sym = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = sym.size
        sym.draw(in: NSRect(x: x2 + (tile - sz.width) / 2, y: y2 + (tile - sz.height) / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()

    // ドラッグされて棚へ向かう写真（少し傾けて、白い縁つき）
    NSGraphicsContext.saveGraphicsState()
    let rot = NSAffineTransform()
    rot.translateX(by: 300, yBy: 530)
    rot.rotate(byDegrees: 10)
    rot.concat()
    let card = rr(-120, -100, 240, 200, 28)
    withShadow(36, -18, 0.4) { NSColor.white.setFill(); card.fill() }
    photo(-104, -84, 208, 168)
    NSGraphicsContext.restoreGraphicsState()

    // マウスカーソル
    let c = NSBezierPath()
    let cx: CGFloat = 356, cy: CGFloat = 510
    c.move(to: NSPoint(x: cx, y: cy))
    c.line(to: NSPoint(x: cx, y: cy - 150))
    c.line(to: NSPoint(x: cx + 36, y: cy - 116))
    c.line(to: NSPoint(x: cx + 62, y: cy - 172))
    c.line(to: NSPoint(x: cx + 88, y: cy - 160))
    c.line(to: NSPoint(x: cx + 62, y: cy - 106))
    c.line(to: NSPoint(x: cx + 110, y: cy - 106))
    c.close()
    c.lineJoinStyle = .round
    withShadow(10, -4, 0.35) { NSColor.black.setFill(); c.fill() }
    NSColor.white.setStroke()
    c.lineWidth = 12
    c.stroke()
    NSColor.black.setFill()
    c.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if CommandLine.arguments.count > 1 {
    try! render(1024).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("作成: \(CommandLine.arguments[1])")
    exit(0)
}

let iconset = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).write(to: iconset.appendingPathComponent(name))
    }
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "作成: icon/AppIcon.icns" : "iconutil が失敗しました")
