// EdgeShelf: 画面の端にものを置いておける棚。
// 何かをドラッグして画面の端へ持っていくと棚がすべり出る。
import AppKit
import ServiceManagement

/// 設定（UserDefaults に保存）
enum Settings {
    /// ドラッグが画面の端に来てから棚が開き始めるまでの時間（ms）
    static var openDelayMs: Int {
        get { UserDefaults.standard.object(forKey: "openDelayMs") as? Int ?? 200 }
        set { UserDefaults.standard.set(newValue, forKey: "openDelayMs") }
    }

    /// つまみに床屋の看板のようなしま模様を流すか：0 = なし、1 = マウスを近づけたとき、2 = いつも（最初は いつも）
    static var stripeMode: Int {
        get { UserDefaults.standard.object(forKey: "stripeMode") as? Int ?? 2 }
        set { UserDefaults.standard.set(newValue, forKey: "stripeMode") }
    }

    /// つまみの色。nil なら標準（ウインドウの背景色）
    static var tabColor: NSColor? {
        get { color("tabColor") }
        set { setColor(newValue, "tabColor") }
    }

    /// つまみの上でマウスを止めてから棚が開くまでの時間（ms）。⌥ を押していればすぐ開く
    static var hoverDelayMs: Int {
        get { UserDefaults.standard.object(forKey: "hoverDelayMs") as? Int ?? 600 }
        set { UserDefaults.standard.set(newValue, forKey: "hoverDelayMs") }
    }

    /// マウスが近づいたとき、つまみを少し太くするか（最初はしない）
    static var growOnNear: Bool {
        get { UserDefaults.standard.bool(forKey: "growOnNear") }
        set { UserDefaults.standard.set(newValue, forKey: "growOnNear") }
    }

    /// 開いた棚のタイルの大きさ：-1 = 極小、0 = 小、1 = 中、2 = 大、3 = 特大（最初は小）
    static var tileSizeMode: Int {
        get { UserDefaults.standard.integer(forKey: "tileSizeMode") }
        set { UserDefaults.standard.set(newValue, forKey: "tileSizeMode") }
    }
    /// 大きさの表を引く番号（0 = 極小 … 4 = 特大）
    static var tileIndex: Int { min(max(tileSizeMode, -1), 3) + 1 }

    /// しま模様の 2 つの帯の色と濃さ（不透明度）。nil なら標準（1 つ目は青、2 つ目は白）
    static var stripeColor: NSColor? {
        get { color("stripeColor") }
        set { setColor(newValue, "stripeColor") }
    }
    static var stripeColor2: NSColor? {
        get { color("stripeColor2") }
        set { setColor(newValue, "stripeColor2") }
    }

    /// トレイを押したときに、つまみの周りを光らせる色。nil なら標準（アクセントカラー）
    static var glowColor: NSColor? {
        get { color("glowColor") }
        set { setColor(newValue, "glowColor") }
    }

    /// 利用者が変えられる設定をすべて消して、最初の値に戻す（アップデートを最後に確かめた時刻などは残す）
    static func resetAll() {
        for key in ["openDelayMs", "hoverDelayMs", "growOnNear", "tileSizeMode", "stripeMode",
                    "tabColor", "glowColor", "stripeColor", "stripeColor2", "autoCheckUpdates"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func color(_ key: String) -> NSColor? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: d)
    }

    private static func setColor(_ c: NSColor?, _ key: String) {
        if let c, let d = try? NSKeyedArchiver.archivedData(withRootObject: c, requiringSecureCoding: true) {
            UserDefaults.standard.set(d, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// ドラッグ中のマウスが画面の端に来たかを見張る。
/// マウスのボタンが押されている間（と棚が開いている間）だけ 1/60 秒ごとに調べる。
final class EdgeWatcher {
    unowned let manager: ShelfManager
    private var timer: Timer?
    private var baseline = NSPasteboard(name: .drag).changeCount   // ドラッグしていないときの値
    private var dragging = false
    private var edgeSince: Date?

    init(manager: ShelfManager) {
        self.manager = manager
        // 他のアプリでのマウス操作（マウスのイベントだけならアクセシビリティの許可は要らない）
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] _ in
            self?.ensureRunning()
        }
        // マウスがつまみに近づいたかを見る（ほかのアプリの上でも、この棚の上でも）
        NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.manager.updateNear(NSEvent.mouseLocation)
        }
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] e in
            self?.manager.updateNear(NSEvent.mouseLocation)
            return e
        }
    }

    func ensureRunning() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        let count = NSPasteboard(name: .drag).changeCount
        // ボタンを押したままドラッグ用の貼り付け板が書き換わった ＝ 何かをドラッグしている
        if pressed && count != baseline { dragging = true }

        let p = NSEvent.mouseLocation
        // つまみはドロップを受けない（クリックを下へ通すため）ので、端の 1 点に届かなくても、つまみの上なら同じように開く
        let onTab = dragging && pressed ? manager.shelves.first { !$0.expanded && $0.tabHitRect.contains(p) } : nil
        if dragging && pressed, onTab != nil || Self.edge(at: p) != nil {
            if edgeSince == nil { edgeSince = Date() }
            if Date().timeIntervalSince(edgeSince!) * 1000 >= Double(Settings.openDelayMs) {
                if let onTab { onTab.expand() }
                else if let (screen, edge) = Self.edge(at: p) { manager.dragReachedEdge(screen: screen, edge: edge, at: p) }
            }
        } else {
            edgeSince = nil
        }

        if !pressed {
            if dragging { dragging = false; manager.dragEnded() }
            baseline = count
        }
        manager.collapseIdle(dragging: dragging)
        if !pressed && !manager.anyExpanded {
            timer?.invalidate()
            timer = nil
        }
    }

    /// 画面の上下左右の端（となりに別の画面がつながっていない側）にいるか。角では左右を先にする
    static func edge(at p: NSPoint) -> (NSScreen, Edge)? {
        let screens = NSScreen.screens
        for s in screens {
            let f = s.frame
            guard p.y >= f.minY - 1, p.y <= f.maxY + 1, p.x >= f.minX - 1, p.x <= f.maxX + 1 else { continue }
            let open = { (q: NSPoint) in !screens.contains { $0 != s && $0.frame.contains(q) } }
            if p.x >= f.maxX - 2, open(NSPoint(x: f.maxX + 2, y: p.y)) { return (s, .right) }
            if p.x <= f.minX + 1, open(NSPoint(x: f.minX - 2, y: p.y)) { return (s, .left) }
            if p.y >= f.maxY - 2, open(NSPoint(x: p.x, y: f.maxY + 2)) { return (s, .top) }
            if p.y <= f.minY + 1, open(NSPoint(x: p.x, y: f.minY - 2)) { return (s, .bottom) }
        }
        return nil
    }
}

final class ShelfManager {
    private(set) var shelves: [Shelf] = []
    private(set) var watcher: EdgeWatcher!
    weak var lastUsed: Shelf?   // 最後にものを置いた棚（サービスで送るときの行き先）

    init() {
        watcher = EdgeWatcher(manager: self)
        let saved = Store.load().filter { !$0.items.isEmpty }
        Store.cleanUp(saved)
        shelves = saved.map { Shelf(data: $0, manager: self) }
        save()   // 古い形式の位置を変換したら保存しておく
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.shelves.forEach { $0.relayout() }
        }
    }

    var anyExpanded: Bool { shelves.contains(where: \.expanded) }

    /// マウスが近くにある閉じた棚の、つまみを目立たせる。つまみの上にあれば開くかを見る
    func updateNear(_ p: NSPoint) {
        for s in shelves where !s.expanded {
            s.setNear(s.nearZone.contains(p))
            s.pointerMoved(p)
        }
    }

    var onChange: (() -> Void)?   // 棚の中身が変わったとき（メニューバーのアイコンを変える）

    var hasItems: Bool { shelves.contains { !$0.data.items.isEmpty } }

    func save() {
        Store.save(shelves.filter { !$0.isTemp && !$0.data.items.isEmpty }.map(\.data))
        onChange?()
    }

    func remove(_ shelf: Shelf) {
        shelf.close()
        shelves.removeAll { $0 === shelf }
        save()
    }

    @discardableResult
    func newShelf(screen: NSScreen, edge: Edge, at p: NSPoint) -> Shelf {
        let vf = screen.visibleFrame
        let t = edge.isHorizontal ? (p.x - vf.minX) / vf.width : (p.y - vf.minY) / vf.height
        let pos = min(max(Double(t), 0), 1)
        let s = Shelf(data: ShelfData(displayID: screen.displayID, edge: edge, position: pos, tabAnchored: true), manager: self)
        shelves.append(s)
        return s
    }

    /// ドラッグが端に来たら、そこにある棚を開く。なければ仮の棚を作る
    func dragReachedEdge(screen: NSScreen, edge: Edge, at p: NSPoint) {
        // 開いている棚は棚全体、閉じている棚はつまみ（端に沿って少し余裕を持たせる）の範囲で判定する
        let here = shelves.first {
            guard $0.screen == screen && $0.data.edge == edge else { return false }
            let h = edge.isHorizontal
            let r = $0.expanded ? $0.frame(expanded: true) : $0.frame(expanded: false).insetBy(dx: h ? -30 : 0, dy: h ? 0 : -30)
            return h ? (r.minX <= p.x && p.x <= r.maxX) : (r.minY <= p.y && p.y <= r.maxY)
        }
        if let here {
            here.expand()
        } else {
            let s = newShelf(screen: screen, edge: edge, at: p)
            s.isTemp = true
            s.expand()
        }
    }

    /// ボタンを離した直後にドロップが届くので、少し待ってから空の仮の棚を消す
    func dragEnded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            for s in shelves where s.isTemp && s.data.items.isEmpty { remove(s) }
        }
    }

    /// マウスが離れてしばらくしたら棚を縮める
    func collapseIdle(dragging: Bool) {
        let now = Date()
        let mouse = NSEvent.mouseLocation
        for s in shelves where s.expanded {
            if s.draggingOut || s.isPreviewing || s.panel.frame.insetBy(dx: -20, dy: -20).contains(mouse) {
                s.lastInside = max(s.lastInside, now)
                continue
            }
            if now.timeIntervalSince(s.lastInside) > (dragging ? 0.4 : 0.8) { s.collapse() }
        }
    }

    /// すべての棚を空にして閉じる
    func clearAll() {
        for s in shelves {
            s.remove(s.data.items.map(\.id), discard: true)
            remove(s)
        }
    }

    /// ほかのアプリの「サービス」から送られたものを置く。
    /// 最後に使った棚へ入れ、なければマウスのある画面の右端に新しい棚を作る。届いたのが分かるよう少し開く
    func receiveFromService(_ pb: NSPasteboard) -> Bool {
        let mouse = NSEvent.mouseLocation
        var target = lastUsed.flatMap { s in shelves.contains { $0 === s } ? s : nil }
            ?? shelves.last(where: { !$0.isTemp })
        var created = false
        if target == nil {
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
            target = newShelf(screen: screen, edge: .right, at: NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY))
            created = true
        }
        guard let shelf = target else { return false }
        guard shelf.accept(pb) else {
            if created { remove(shelf) }
            return false
        }
        shelf.expand(hold: 1.5)
        return true
    }

    /// クリップボードの中身で、主画面の右端に新しい棚を作る
    func pasteToNewShelf() {
        guard let screen = NSScreen.main else { return }
        let s = newShelf(screen: screen, edge: .right, at: NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY))
        s.expand(hold: 3)
        if !s.accept(.general) {
            NSSound.beep()
            remove(s)
        }
    }
}

/// macOS の「サービス」の受け口（ほかのアプリの右クリック →「EdgeShelf に送る」）。
/// Info.plist の NSServices で登録している
final class ServiceProvider: NSObject {
    unowned let manager: ShelfManager
    init(manager: ShelfManager) { self.manager = manager }

    @objc func sendToShelf(_ pboard: NSPasteboard, userData: String?,
                           error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        if !manager.receiveFromService(pboard) {
            error.pointee = L("EdgeShelf に置けるものがありませんでした") as NSString
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var manager: ShelfManager!
    private var services: ServiceProvider!

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager = ShelfManager()
        services = ServiceProvider(manager: manager)
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        manager.onChange = { [weak self] in self?.updateIcon() }
        updateIcon()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        Updater.shared.onChange = { [weak self] in self?.updateIcon() }
        Updater.shared.start()
    }

    /// 画面の枠の右の内側に棚がはり付いた形。棚に何か入っていれば棚を塗りつぶし、空なら線だけ
    private func updateIcon() {
        let full = manager.hasItems
        let image = Self.menuBarIcon(full: full)
        image.accessibilityDescription = full ? L("EdgeShelf（棚にものがあります）") : "EdgeShelf"
        statusItem.button?.image = Updater.shared.badge(image)
    }

    static func menuBarIcon(full: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2.8, width: 15, height: 10.4), xRadius: 1.6, yRadius: 1.6)
            let stand = NSBezierPath()
            stand.move(to: NSPoint(x: 6.5, y: 15.6))
            stand.line(to: NSPoint(x: 11.5, y: 15.6))
            // 画面の右の内側にはり付いた棚（左の角だけ丸い）
            let shelf = NSBezierPath()
            shelf.move(to: NSPoint(x: 16.5, y: 4.9))
            shelf.appendArc(from: NSPoint(x: 11.3, y: 4.9), to: NSPoint(x: 11.3, y: 11.1), radius: 1.3)
            shelf.appendArc(from: NSPoint(x: 11.3, y: 11.1), to: NSPoint(x: 16.5, y: 11.1), radius: 1.3)
            shelf.line(to: NSPoint(x: 16.5, y: 11.1))
            for p in [screen, stand, shelf] {
                p.lineWidth = 1.5
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
            }
            screen.stroke()
            stand.stroke()
            if full { shelf.close(); shelf.fill() }
            shelf.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    // メニューを開くたびに作り直す
    // メニューを開いている間、つまみを光らせて場所を知らせる
    func menuWillOpen(_ menu: NSMenu) { manager.shelves.forEach { $0.setGlow(true) } }
    func menuDidClose(_ menu: NSMenu) { manager.shelves.forEach { $0.setGlow(false) } }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        Updater.shared.topMenuItems().forEach(menu.addItem)
        menu.addItem(MenuAction(L("EdgeShelf について")) { [weak self] in self?.showAbout() })
        menu.addItem(.separator())
        let shelves = manager.shelves.filter { !$0.data.items.isEmpty }
        if shelves.isEmpty {
            let none = NSMenuItem(title: L("棚はありません（ものを画面の端へドラッグ）"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for s in shelves {
            let name = [Edge.left: "左の棚：%d 件", .right: "右の棚：%d 件", .top: "上の棚：%d 件", .bottom: "下の棚：%d 件"][s.data.edge]!
            let side = String(format: L(name), s.data.items.count)
            let multi = NSScreen.screens.count > 1 ? String(format: L("%@・"), s.screen.localizedName) : ""
            menu.addItem(MenuAction(multi + side) { s.expand(hold: 3) })
        }
        if shelves.count > 1 {
            menu.addItem(MenuAction(L("すべての棚を空にする…")) { [weak self] in self?.confirmClearAll() })
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction(L("クリップボードを新しい棚に置く")) { [manager] in manager!.pasteToNewShelf() })
        menu.addItem(.separator())
        menu.addItem(delayMenu())
        menu.addItem(hoverDelayMenu())
        menu.addItem(tileSizeMenu())
        menu.addItem(MenuAction(L("つまみの色…")) { [weak self] in self?.showColorPanel(.tab) })
        menu.addItem(MenuAction(L("点滅の色…")) { [weak self] in self?.showColorPanel(.glow) })
        menu.addItem(stripeMenu())
        let grow = MenuAction(L("近づくとつまみを太くする")) { [weak self] in
            Settings.growOnNear.toggle()
            self?.manager.shelves.forEach { $0.relayout() }
        }
        grow.state = Settings.growOnNear ? .on : .off
        menu.addItem(grow)
        menu.addItem(MenuAction(L("すべての設定を標準に戻す…")) { [weak self] in self?.confirmResetSettings() })
        let login = NSMenuItem(title: L("ログイン時に起動"), action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        Updater.shared.settingsMenuItems().forEach(menu.addItem)
        menu.addItem(NSMenuItem(title: L("終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// 設定を最初の状態に戻す。「ログイン時に起動」（macOS の側の設定）と、棚の中身は残す
    private func confirmResetSettings() {
        let alert = NSAlert()
        alert.messageText = L("すべての設定を標準に戻しますか？")
        alert.informativeText = L("色、しま模様、タイルの大きさ、開くまでの時間などを、最初の状態に戻します。「ログイン時に起動」と、棚に置いたものはそのままです。")
        alert.addButton(withTitle: L("標準に戻す"))
        alert.addButton(withTitle: L("キャンセル"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Settings.resetAll()
        manager.shelves.forEach { $0.tileSizeChanged(); $0.redrawTab() }
    }

    private func confirmClearAll() {
        let shelves = manager.shelves.filter { !$0.data.items.isEmpty }
        let total = shelves.reduce(0) { $0 + $1.data.items.count }
        let alert = NSAlert()
        alert.messageText = L("すべての棚を空にしますか？")
        alert.informativeText = String(format: L("%1$d つの棚にある %2$d 件をすべて取り除きます。元のファイルは消えませんが、写真や Web の画像から作ったファイルは消えます。"), shelves.count, total)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("空にする"))
        alert.addButton(withTitle: L("キャンセル"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager.clearAll()
    }

    private enum ColorTarget { case tab, glow, stripe, stripe2 }
    private var colorTarget = ColorTarget.tab

    /// macOS 標準のカラーパネルで色を選ぶ。つまみの色はその場ですべてのつまみに反映する。
    /// 点滅の色は、選んでいる間つまみを光らせて見せる
    private func showColorPanel(_ target: ColorTarget) {
        colorTarget = target
        let panel = NSColorPanel.shared
        panel.showsAlpha = target != .glow   // しま模様は不透明度で濃さを決める
        panel.isContinuous = true
        panel.setTarget(nil)   // 色を合わせる間に action が呼ばれないように
        switch target {
        case .tab:
            panel.color = Settings.tabColor ?? .windowBackgroundColor
            panel.title = L("つまみの色")
        case .glow:
            panel.color = Settings.glowColor ?? .controlAccentColor
            panel.title = L("点滅の色")
        case .stripe:
            panel.color = Settings.stripeColor ?? TabView.defaultStripeColor
            panel.title = L("しま模様の 1 つ目の色")
        case .stripe2:
            panel.color = Settings.stripeColor2 ?? TabView.defaultStripeColor2
            panel.title = L("しま模様の 2 つ目の色")
        }
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if target == .glow {
            manager.shelves.forEach { $0.setGlow(true) }
            NotificationCenter.default.addObserver(self, selector: #selector(colorPanelClosed),
                                                   name: NSWindow.willCloseNotification, object: panel)
        }
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        switch colorTarget {
        case .tab:
            Settings.tabColor = sender.color
            manager.shelves.forEach { $0.redrawTab() }
        case .glow:
            Settings.glowColor = sender.color
            manager.shelves.forEach { $0.setGlow(true) }   // 新しい色で光らせ直す
        case .stripe:
            Settings.stripeColor = sender.color
            manager.shelves.forEach { $0.redrawTab() }
        case .stripe2:
            Settings.stripeColor2 = sender.color
            manager.shelves.forEach { $0.redrawTab() }
        }
    }

    @objc private func colorPanelClosed() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: NSColorPanel.shared)
        manager.shelves.forEach { $0.setGlow(false) }
    }

    /// つまみのしま模様の出し方と色
    private func stripeMenu() -> NSMenuItem {
        let item = NSMenuItem(title: L("つまみのしま模様"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (mode, title) in [(0, L("なし")), (1, L("マウスを近づけたとき")), (2, L("いつも"))] {
            let i = MenuAction(title) { [weak self] in
                Settings.stripeMode = mode
                self?.manager.shelves.forEach { $0.redrawTab() }
            }
            i.state = Settings.stripeMode == mode ? .on : .off
            sub.addItem(i)
        }
        sub.addItem(.separator())
        sub.addItem(MenuAction(L("1 つ目の色…")) { [weak self] in self?.showColorPanel(.stripe) })
        sub.addItem(MenuAction(L("2 つ目の色…")) { [weak self] in self?.showColorPanel(.stripe2) })
        item.submenu = sub
        return item
    }

    private func tileSizeMenu() -> NSMenuItem {
        let item = NSMenuItem(title: L("タイルの大きさ"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (mode, title) in [(-1, L("極小")), (0, L("小")), (1, L("中")), (2, L("大")), (3, L("特大"))] {
            let i = MenuAction(title) { [weak self] in
                Settings.tileSizeMode = mode
                self?.manager.shelves.forEach { $0.tileSizeChanged() }
            }
            i.state = Settings.tileSizeMode == mode ? .on : .off
            sub.addItem(i)
        }
        item.submenu = sub
        return item
    }

    private func delayMenu() -> NSMenuItem {
        msMenu(title: L("置くときに開くまでの時間：%d ms"), presets: [0, 50, 100, 150, 200, 300, 500, 800, 1000],
               get: { Settings.openDelayMs }, set: { Settings.openDelayMs = $0 },
               askTitle: L("置くときに開くまでの時間"),
               askInfo: L("ドラッグが画面の端に来てから棚が開き始めるまでの時間を、ミリ秒（0〜5000）で入力してください。"))
    }

    private func hoverDelayMenu() -> NSMenuItem {
        msMenu(title: L("見るときに開くまでの時間：%d ms"), presets: [200, 300, 400, 500, 600, 800, 1000, 1500],
               get: { Settings.hoverDelayMs }, set: { Settings.hoverDelayMs = $0 },
               askTitle: L("見るときに開くまでの時間"),
               askInfo: L("つまみの上でマウスを止めてから棚が開くまでの時間を、ミリ秒（0〜5000）で入力してください。⌥ を押していれば、すぐ開きます。"))
    }

    /// ミリ秒の設定のメニュー（決まった値と、カスタムの入力）
    private func msMenu(title: String, presets: [Int], get: @escaping () -> Int, set: @escaping (Int) -> Void,
                        askTitle: String, askInfo: String) -> NSMenuItem {
        let cur = get()
        let item = NSMenuItem(title: String(format: title, cur), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for ms in presets {
            let i = MenuAction("\(ms) ms") { set(ms) }
            i.state = ms == cur ? .on : .off
            sub.addItem(i)
        }
        sub.addItem(.separator())
        let custom = MenuAction(presets.contains(cur) ? L("カスタム…") : String(format: L("カスタム…（%d ms）"), cur)) { [weak self] in
            self?.askMs(title: askTitle, info: askInfo, current: cur, set: set)
        }
        custom.state = presets.contains(cur) ? .off : .on
        sub.addItem(custom)
        item.submenu = sub
        return item
    }

    private func askMs(title: String, info: String, current: Int, set: (Int) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = "\(current)"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L("キャンセル"))
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            .applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? ""
        guard let ms = Int(text), (0...5000).contains(ms) else { NSSound.beep(); return }
        set(ms)
    }

    /// macOS 標準の「このアプリについて」（アイコン・名前・バージョン・著作権は Info.plist から）
    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.version: ""])   // ビルド番号の「(…)」は出さない
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "EdgeShelf"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
