// 棚のウインドウ：画面の端に貼りつき、使わないときは小さなつまみに縮む
import AppKit
import QuickLookThumbnailing
import Quartz

final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class Shelf {
    static let expandedSize = NSSize(width: 272, height: 366)   // 4 件（2 段）がスクロールせずに入る高さ
    static let tabSize = NSSize(width: 12, height: expandedSize.height)   // 開いた棚と同じ長さ

    var data: ShelfData
    var isTemp = false          // ドラッグ中に作った仮の棚。何も置かれなければ消す
    var draggingOut = false     // この棚から外へドラッグ中
    var lastInside = Date()     // 最後にマウスが棚の上にあった時刻
    private(set) var selected: Set<UUID> = []
    private var anchor: UUID?   // ⇧ で範囲選択するときの起点
    private var focus: UUID?    // 矢印キーで動かす位置
    private var qlKeyObserver: NSObjectProtocol?
    private var previousApp: NSRunningApplication?   // プレビューの前に前面だったアプリ
    private(set) var expanded = false
    unowned let manager: ShelfManager
    let panel: ShelfPanel
    private let root: ShelfRootView

    init(data: ShelfData, manager: ShelfManager) {
        self.data = data
        self.manager = manager
        panel = ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        root = ShelfRootView()
        root.shelf = self
        panel.contentView = root
        migratePosition()
        root.showTab()
        panel.setFrame(frame(expanded: false), display: false)
        panel.orderFrontRegardless()
    }

    var screen: NSScreen {
        NSScreen.screens.first { $0.displayID == data.displayID } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// つまみの中心が基準。開いた棚も中心をつまみの中心にそろえ、画面に収まらないときだけ上下にずらす
    func frame(expanded: Bool) -> NSRect {
        let f = screen.frame, vf = screen.visibleFrame
        let size = expanded ? Self.expandedSize : Self.tabSize
        var cy = vf.minY + data.position * vf.height
        cy = min(max(cy, vf.minY + size.height / 2), vf.maxY - size.height / 2)
        let x = data.edge == .right ? f.maxX - size.width : f.minX
        return NSRect(x: x, y: cy - size.height / 2, width: size.width, height: size.height)
    }

    /// 古い形式（開いた棚の中心）で保存された位置を、つまみの中心に直す。棚は同じ場所に残る
    private func migratePosition() {
        guard data.tabAnchored != true else { return }
        let vf = screen.visibleFrame, full = Self.expandedSize
        let cy = min(max(vf.minY + data.position * vf.height, vf.minY + full.height / 2), vf.maxY - full.height / 2)
        data.position = min(max(Double((cy - vf.minY) / vf.height), 0), 1)
        data.tabAnchored = true
    }

    /// 端から棚がすべり出る
    func expand(hold: TimeInterval = 0) {
        setGlow(false)
        lastInside = Date().addingTimeInterval(hold)
        manager.watcher.ensureRunning()
        guard !expanded else { return }
        expanded = true
        let target = frame(expanded: true)
        var start = target
        start.origin.x += data.edge == .right ? target.width - Self.tabSize.width : -(target.width - Self.tabSize.width)
        root.showExpanded()
        panel.setFrame(start, display: false)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().setFrame(target, display: true)
        }
    }

    func collapse() {
        guard expanded else { return }
        expanded = false
        closePreview()
        restorePreviousApp()
        selected = []
        anchor = nil
        focus = nil
        if data.items.isEmpty { manager.remove(self); return }
        if panel.isKeyWindow {   // キーボードの入力先を元のアプリへ返す
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        root.showTab()
        panel.setFrame(frame(expanded: false), display: true)
    }

    func redrawTab() { root.redrawTab() }

    func relayout() {
        panel.setFrame(frame(expanded: expanded), display: true)
    }

    func close() {
        setGlow(false)
        panel.orderOut(nil)
    }

    // MARK: つまみを光らせる（メニューバーのアイコンを押したとき、場所が分かるように）

    private var glow: GlowWindow?

    func setGlow(_ on: Bool) {
        if on {
            guard !expanded, !data.items.isEmpty else { return }
            let g = glow ?? GlowWindow()
            glow = g
            g.show(around: panel.frame, below: panel)
        } else {
            glow?.hide()
        }
    }

    // MARK: 項目の操作

    private func changed() {
        manager.save()
        root.reload()
    }

    /// ドロップ・貼り付けを受け取る。同じドロップで後から届いたファイルは同じ項目にまとめる
    @discardableResult
    func accept(_ pb: NSPasteboard) -> Bool {
        var itemID: UUID?
        let accepted = DropReader.read(pb) { [weak self] entries in
            guard let self else { return }
            self.isTemp = false
            self.manager.lastUsed = self
            if let id = itemID, let i = self.data.items.firstIndex(where: { $0.id == id }) {
                self.data.items[i].entries += entries
            } else {
                let item = ShelfItem(entries: entries)
                itemID = item.id
                self.data.items.append(item)
            }
            self.changed()
        }
        // 写真の書き出しなどは後から届くので、受け付けた時点で仮の棚ではなくする（空のままなら縮んだときに消える）
        if accepted { isTemp = false }
        return accepted
    }

    func insert(_ items: [ShelfItem]) {
        isTemp = false
        manager.lastUsed = self
        data.items += items
        changed()
    }

    /// discard: このアプリが作ったファイルも消すか（別の棚へ移したときは消さない）
    func remove(_ ids: [UUID], discard: Bool) {
        let gone = data.items.filter { ids.contains($0.id) }
        data.items.removeAll { ids.contains($0.id) }
        if discard { gone.forEach(Store.discard) }
        selected.subtract(ids)
        changed()
        if isPreviewing { QLPreviewPanel.shared().reloadData() }
    }

    private func index(_ id: UUID) -> Int? { data.items.firstIndex { $0.id == id } }

    /// 一部だけを消す（項目の ID → 消す entries の番号）。
    /// まとめた項目は、受け取られなかったものを残す
    func removeEntries(_ taken: [UUID: Set<Int>]) {
        for (id, idx) in taken {
            guard let i = index(id) else { continue }
            data.items[i].entries = data.items[i].entries.enumerated()
                .filter { !idx.contains($0.offset) }.map(\.element)
        }
        selected.subtract(data.items.filter(\.entries.isEmpty).map(\.id))
        data.items.removeAll { $0.entries.isEmpty }
        changed()
        if isPreviewing { QLPreviewPanel.shared().reloadData() }
    }

    /// 選んだ項目の画像を JPEG に変換し、棚の中身を置き換える。
    /// 元のファイルは消さない（写真アプリから取り込んだものなど、このアプリが作ったファイルだけ消す）
    func convertToJPEG(_ ids: [UUID]) {
        let targets = data.items.filter { ids.contains($0.id) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for item in targets {
                for (n, e) in item.entries.enumerated() {
                    guard let url = e.fileURL, JPEGConvert.canConvert(url), let jpeg = JPEGConvert.convert(url) else { continue }
                    DispatchQueue.main.async {
                        guard let self, let i = self.index(item.id), n < self.data.items[i].entries.count,
                              self.data.items[i].entries[n].path == e.path else {
                            try? FileManager.default.removeItem(at: jpeg.deletingLastPathComponent())
                            return
                        }
                        self.data.items[i].entries[n] = .file(jpeg, owned: true)
                        Store.discard(ShelfItem(entries: [e]))
                        self.changed()
                        if self.isPreviewing { QLPreviewPanel.shared().reloadData() }
                    }
                }
            }
        }
    }

    /// まとめた項目を 1 つずつに分ける
    func split(_ id: UUID) {
        guard let i = data.items.firstIndex(where: { $0.id == id }) else { return }
        let parts = data.items[i].entries.map { ShelfItem(entries: [$0]) }
        data.items.replaceSubrange(i...i, with: parts)
        changed()
    }

    // MARK: 選択

    /// 棚に並んでいる順の、選択中の項目
    var selectedItems: [ShelfItem] { data.items.filter { selected.contains($0.id) } }

    /// extend：⇧（起点からの範囲を選ぶ）、toggle：⌘（1 つずつ足したり外したり）
    func select(_ id: UUID, extend: Bool = false, toggle: Bool = false) {
        if extend, let a = anchor, let i = index(a), let j = index(id) {
            selected = Set(data.items[min(i, j)...max(i, j)].map(\.id))
        } else if toggle {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
        } else {
            selected = [id]
            anchor = id
        }
        focus = id
        selectionChanged()
    }

    /// 囲んで選んだとき
    func setSelection(_ ids: Set<UUID>) {
        selected = ids
        selectionChanged()
    }

    func selectAll() { setSelection(Set(data.items.map(\.id))) }

    /// 矢印キー
    func moveFocus(by step: Int, extend: Bool) {
        guard !data.items.isEmpty else { return }
        let next = focus.flatMap(index).map { min(max($0 + step, 0), data.items.count - 1) } ?? 0
        select(data.items[next].id, extend: extend)
    }

    private func selectionChanged() {
        root.updateSelection()
        if isPreviewing { QLPreviewPanel.shared().reloadData() }
    }

    // MARK: プレビュー（Quick Look）

    var previewURLs: [URL] { selectedItems.flatMap(\.fileURLs) }

    var isPreviewing: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
            && (QLPreviewPanel.shared().dataSource as AnyObject?) === root
    }

    func togglePreview() {
        guard let ql = QLPreviewPanel.shared() else { return }
        if isPreviewing { closePreview(); return }
        guard !previewURLs.isEmpty else { NSSound.beep(); return }
        // プレビューを開いたら、このアプリを前面にする。前面にしないと、キー入力（閉じるためのスペースなど）が
        // 下のアプリへ流れてしまう（ブラウザならページが送られる）。元のアプリへは棚が縮むときに戻す
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        panel.makeFirstResponder(root)
        // キー入力は棚で受ける。プレビューの窓は表示の少しあとでキーになるので、そのたびに棚へ戻す。
        // スペースで閉じる、矢印キーで選択を動かすとプレビューも追従する
        if qlKeyObserver == nil {
            qlKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: ql, queue: .main) { [weak self] _ in
                guard let self, self.isPreviewing else { return }
                self.panel.makeKey()
            }
        }
        ql.makeKeyAndOrderFront(nil)
        ql.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)   // 棚より手前に
        panel.makeKey()
    }

    func closePreview() {
        if isPreviewing { QLPreviewPanel.shared().orderOut(nil) }
        previewEnded()
    }

    /// プレビューが閉じたら、キー入力は棚で受け続ける（続けてスペースでまた開けるように）
    func previewEnded() {
        guard expanded else { return }
        panel.makeKey()
        panel.makeFirstResponder(root)
    }

    /// プレビューのために前面にしていたなら、元のアプリへ戻す（その間にほかのアプリへ移っていたら何もしない）
    private func restorePreviousApp() {
        guard let app = previousApp else { return }
        previousApp = nil
        if NSApp.isActive { app.activate() }
    }

    func paste() { accept(.general) }

    func copy(_ items: [ShelfItem]) {
        let writers = items.flatMap(\.entries).compactMap(\.writer)
        guard !writers.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(writers)
    }

    func open(_ items: [ShelfItem]) {
        for e in items.flatMap(\.entries) {
            switch e.kind {
            case .file: if let u = e.fileURL { NSWorkspace.shared.open(u) }
            case .link: if let s = e.text, let u = URL(string: s) { NSWorkspace.shared.open(u) }
            case .text: break
            }
        }
    }

    func reveal(_ items: [ShelfItem]) {
        let urls = items.flatMap(\.fileURLs)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// 棚の縦位置を変える（見出しをドラッグしたとき）
    func moveVertically(to midY: CGFloat) {
        let vf = screen.visibleFrame                     // 開いた棚の中心 ＝ つまみの中心
        data.position = min(max(Double((midY - vf.minY) / vf.height), 0), 1)
        relayout()
    }
}

// MARK: - ビュー

/// ウインドウ全体。ドロップを受けつけ、つまみと中身を切り替える
final class ShelfRootView: NSView {
    weak var shelf: Shelf?
    private let tab = TabView()
    private let content = ExpandedView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff, .init("public.jpeg"), .init("public.heic")]
                                + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        for v in [tab, content] as [NSView] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    func showTab() {
        tab.shelf = shelf
        tab.isHidden = false
        content.isHidden = true
        tab.refresh()
    }

    func showExpanded() {
        content.shelf = shelf
        tab.isHidden = true
        content.isHidden = false
        content.reload()
    }

    func reload() {
        content.reload()
        tab.refresh()
    }

    func updateSelection() { content.updateSelection() }

    func redrawTab() { tab.refresh() }

    // ドロップ
    private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        if let src = info.draggingSource as? DragSourceView {
            return src.shelf === shelf ? [] : .move
        }
        let mask = info.draggingSourceOperationMask
        return mask.contains(.copy) ? .copy : mask.contains(.generic) ? .generic : mask
    }

    private var openTimer: Timer?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // つまみの上に来たら、設定した時間だけ待ってから開く（ドラッグ中も動くよう .common で登録）
        if shelf?.expanded == false {
            openTimer?.invalidate()
            let t = Timer(timeInterval: Double(Settings.openDelayMs) / 1000, repeats: false) { [weak self] _ in
                self?.shelf?.expand()
            }
            RunLoop.main.add(t, forMode: .common)
            openTimer = t
        }
        content.highlighted = operation(sender) != []
        return operation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        shelf?.lastInside = Date()
        return operation(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        openTimer?.invalidate()
        content.highlighted = false
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { content.highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        openTimer?.invalidate()
        content.highlighted = false
        guard let shelf, shelf.expanded else { return false }   // 開く前のつまみには落とせない
        if let src = sender.draggingSource as? DragSourceView {
            guard src.shelf !== shelf else { return false }
            shelf.insert(src.draggedItems)
            return true
        }
        return shelf.accept(sender.draggingPasteboard)
    }

    // キーボード（棚をクリックしたあと）
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let shelf, window?.isKeyWindow == true,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
        switch event.charactersIgnoringModifiers {
        case "v": shelf.paste(); return true
        case "c": shelf.copy(shelf.selected.isEmpty ? shelf.data.items : shelf.selectedItems); return true
        case "a": shelf.selectAll(); return true
        default: return false
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let shelf else { return }
        switch event.keyCode {
        case 51, 117:   // delete, forward delete
            shelf.remove(Array(shelf.selected), discard: true)
        case 53:        // esc
            shelf.collapse()
        case 36, 76:    // return
            shelf.open(shelf.selectedItems)
        case 49:        // space
            shelf.togglePreview()
        case 123, 124, 125, 126:  // ← → ↓ ↑（2 列に並んでいるので上下は 2 つ飛ばし）。⇧ で範囲を広げる
            let step = [123: -1, 124: 1, 125: ExpandedView.columns, 126: -ExpandedView.columns][Int(event.keyCode)]!
            shelf.moveFocus(by: step, extend: event.modifierFlags.contains(.shift))
        default:
            super.keyDown(with: event)
        }
    }
}

extension ShelfRootView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        shelf?.previewEnded()   // 閉じるボタンで閉じたとき
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { shelf?.previewURLs.count ?? 0 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        shelf?.previewURLs[index] as NSURL?
    }

    /// プレビュー中にもう一度スペースで閉じる
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49 else { return false }
        shelf?.closePreview()
        return true
    }
}

/// つまみの周りに出す、脈打つ光。クリックは下へ通す
final class GlowWindow: NSPanel {
    static let margin: CGFloat = 36
    private let shape = CAShapeLayer()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        let v = NSView()
        v.wantsLayer = true
        contentView = v
        shape.shadowOffset = .zero
        shape.shadowRadius = 14
        shape.shadowOpacity = 1
        v.layer?.addSublayer(shape)
    }

    func show(around tab: NSRect, below panel: NSWindow) {
        let m = Self.margin
        setFrame(tab.insetBy(dx: -m, dy: -m), display: false)
        let color = (Settings.glowColor ?? NSColor.controlAccentColor).cgColor
        shape.frame = CGRect(origin: .zero, size: frame.size)
        // つまみを囲む輪だけを光らせる（つまみはガラスで透けるので、中は光らせない）
        let tabRect = CGRect(x: m, y: m, width: tab.width, height: tab.height)
        shape.path = CGPath(roundedRect: tabRect.insetBy(dx: -3, dy: -3), cornerWidth: 8, cornerHeight: 8, transform: nil)
        shape.fillColor = nil
        shape.strokeColor = color
        shape.lineWidth = 4
        shape.shadowColor = color
        // 光のにじみがつまみの中に入らないよう、つまみの形を切り抜く
        let mask = CAShapeLayer()
        let hole = CGMutablePath()
        hole.addRect(CGRect(origin: .zero, size: frame.size))
        hole.addPath(CGPath(roundedRect: tabRect.insetBy(dx: 1, dy: 1), cornerWidth: 6, cornerHeight: 6, transform: nil))
        mask.path = hole
        mask.fillRule = .evenOdd
        contentView?.layer?.mask = mask
        hiding = false
        order(.below, relativeTo: panel.windowNumber)
        NSAnimationContext.runAnimationGroup { ctx in   // 消える途中のアニメーションを打ち消す
            ctx.duration = 0
            animator().alphaValue = 1
        }
        // 明るさを行ったり来たりさせる（メニューを開いている間もアニメーションは動く）
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.25
        pulse.toValue = 1
        pulse.duration = 1.1   // ゆっくり（明るくなるまで約 1 秒）
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shape.add(pulse, forKey: "pulse")
    }

    private var hiding = false

    func hide() {
        guard isVisible else { return }
        hiding = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // 消えている途中でまた光らせたとき（色を選ぶときなど）は消さない
            guard let self, self.hiding else { return }
            self.shape.removeAllAnimations()
            self.orderOut(nil)
        })
    }
}

/// 縮んだときのつまみ。マウスを乗せるかクリックすると開く。
/// 背景は棚と同じガラスの素材（macOS 26 以降）。設定した色はガラスの上に重ねる
final class TabView: NSView {
    weak var shelf: Shelf?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // 他のアプリを使っていても 1 回目のクリックで反応する
    private var hoverTimer: Timer?
    private var glass: NSView?          // NSGlassEffectView（macOS 26 以降）
    private let ink = TabInkView()      // 取っ手の線と項目の数

    override init(frame: NSRect) {
        super.init(frame: frame)
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 6
            g.frame = bounds.insetBy(dx: 1, dy: 1)
            g.autoresizingMask = [.width, .height]
            addSubview(g)
            glass = g
        }
        ink.tab = self
        ink.frame = bounds
        ink.autoresizingMask = [.width, .height]
        addSubview(ink)
    }
    required init?(coder: NSCoder) { fatalError() }

    // 中のビューではなく、つまみ自身がマウスを受ける
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    /// 色や件数が変わったときに描き直す（閉じたままでもすぐ反映されるよう、その場で描く）
    func refresh() {
        needsDisplay = true
        ink.needsDisplay = true
        ink.displayIfNeeded()
        displayIfNeeded()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        // ドラッグ中は、端で開くまでの時間の設定に従う（ここでは開かない）
        guard NSEvent.pressedMouseButtons == 0 else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.shelf?.expand()
        }
    }
    override func mouseExited(with event: NSEvent) { hoverTimer?.invalidate() }
    override func mouseDown(with event: NSEvent) { hoverTimer?.invalidate(); shelf?.expand() }

    /// ガラスが使えないとき（macOS 25 以前）は、ここで背景を塗る
    override func draw(_ dirtyRect: NSRect) {
        guard glass == nil else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        (Settings.tabColor ?? NSColor.windowBackgroundColor.withAlphaComponent(0.92)).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    var itemCount: Int { shelf?.data.items.count ?? 0 }
    var hasGlass: Bool { glass != nil }
}

/// つまみの上に描く、取っ手の線と項目の数
final class TabInkView: NSView {
    weak var tab: TabView?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // 線と数字は、つまみの色の明るさに合わせて白か黒にする
        var ink = NSColor.secondaryLabelColor
        if let c = Settings.tabColor?.usingColorSpace(.sRGB), c.alphaComponent > 0.4 {
            let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
            ink = lum < 0.6 ? NSColor.white.withAlphaComponent(0.9) : NSColor.black.withAlphaComponent(0.55)
        }
        // 設定した色は、ガラスの上に重ねる（透明度を下げるとガラスが透けて見える）
        if tab?.hasGlass == true, let c = Settings.tabColor {
            c.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        // ガラスは明るい背景の上だと輪郭が見えにくいので、縁に薄い線を引く
        if tab?.hasGlass == true {
            let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 5.5, yRadius: 5.5)
            edge.lineWidth = 1
            NSColor.tertiaryLabelColor.setStroke()
            edge.stroke()
        }
        ink.setFill()
        let grip = NSRect(x: bounds.midX - 1, y: bounds.midY + 8, width: 2, height: 18)
        NSBezierPath(roundedRect: grip, xRadius: 1, yRadius: 1).fill()
        let n = "\(tab?.itemCount ?? 0)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                                                    .foregroundColor: ink]
        let sz = n.size(withAttributes: attrs)
        n.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - 18), withAttributes: attrs)
    }
}

/// 項目を並べる面。何もないところからドラッグすると、四角で囲んで複数選択できる
final class SelectionListView: NSView {
    weak var shelf: Shelf?
    private var start: NSPoint?
    private var base: Set<UUID> = []   // ⌘・⇧ を押して囲み始めたときの選択
    private let band = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        band.wantsLayer = true
        band.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        band.layer?.borderColor = NSColor.controlAccentColor.cgColor
        band.layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let shelf else { return }
        window?.makeKey()
        window?.makeFirstResponder(window?.contentView)
        start = convert(event.locationInWindow, from: nil)
        let mods = event.modifierFlags
        base = mods.contains(.command) || mods.contains(.shift) ? shelf.selected : []
        shelf.setSelection(base)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let shelf else { return }
        autoscroll(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let r = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        band.frame = r
        if band.superview == nil { addSubview(band) }
        var ids = base
        for case let row as ItemRowView in subviews where row.frame.intersects(r) { ids.insert(row.item.id) }
        shelf.setSelection(ids)
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
        band.removeFromSuperview()
    }
}

/// 開いたときの中身：見出し＋項目の一覧
final class ExpandedView: NSView {
    weak var shelf: Shelf? {
        didSet { header.shelf = shelf; handle.shelf = shelf; list.shelf = shelf }
    }
    var highlighted = false { didSet { updateBorder() } }
    private let header = HeaderView()
    private let handle = DragSourceView()
    private let countLabel = NSTextField(labelWithString: "")
    private let menuButton = NSButton()
    private let clearButton = NSButton()
    private let scroll = NSScrollView()
    private let list = SelectionListView()
    private let emptyLabel = NSTextField(labelWithString: L("ここにドロップ\n⌘V で貼り付け"))
    static let columns = 2
    static let minTileHeight: CGFloat = 150
    static let headerHeight: CGFloat = 32

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        // 背景：メニューと同じ、後ろがうっすら透けるガラスの素材（macOS 26 以降）。それより前は半透明の素材
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 12
            background = glass
        } else {
            let v = NSVisualEffectView()
            v.material = .menu
            v.blendingMode = .behindWindow
            v.state = .active
            background = v
        }
        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        addSubview(background)

        header.autoresizingMask = [.width, .minYMargin]
        addSubview(header)

        handle.image = symbol("square.stack.3d.up.fill", size: 15)
        handle.toolTip = L("ドラッグすると、棚のものをまとめて運べる")
        header.addSubview(handle)

        countLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        countLabel.textColor = .secondaryLabelColor
        header.addSubview(countLabel)

        menuButton.bezelStyle = .inline
        menuButton.isBordered = false
        menuButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: L("メニュー"))
        menuButton.target = self
        menuButton.action = #selector(showMenu(_:))
        menuButton.autoresizingMask = [.minXMargin]
        header.addSubview(menuButton)

        clearButton.bezelStyle = .inline
        clearButton.isBordered = false
        clearButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: L("すべて取り除く"))
        clearButton.toolTip = L("棚のものをすべて取り除く（元のファイルは消えない）")
        clearButton.target = self
        clearButton.action = #selector(clearAll)
        header.addSubview(clearButton)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)

        emptyLabel.alignment = .center
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        addSubview(emptyLabel)
        updateBorder()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = Self.headerHeight
        header.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        handle.frame = NSRect(x: 8, y: 5, width: 22, height: 22)
        countLabel.frame = NSRect(x: 36, y: 8, width: bounds.width - 100, height: 16)
        menuButton.frame = NSRect(x: bounds.width - 32, y: 4, width: 24, height: 24)
        clearButton.frame = NSRect(x: bounds.width - 60, y: 4, width: 24, height: 24)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - h)
        emptyLabel.frame = NSRect(x: 0, y: bounds.midY - 30, width: bounds.width, height: 40)
        layoutRows()
    }

    private func updateBorder() {
        layer?.borderColor = (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.borderWidth = highlighted ? 2 : 1
    }

    func reload() {
        guard let shelf else { return }
        list.subviews.forEach { $0.removeFromSuperview() }
        for item in shelf.data.items {
            let row = ItemRowView(item: item, shelf: shelf)
            row.isSelected = shelf.selected.contains(item.id)
            list.addSubview(row)
        }
        let n = shelf.data.items.count
        handle.dragItems = shelf.data.items
        emptyLabel.isHidden = n != 0
        updateCount()
        layoutRows()
    }

    private func updateCount() {
        guard let shelf else { return }
        let n = shelf.data.items.count, m = shelf.selected.count
        countLabel.stringValue = m > 1 ? String(format: L("%d 件（%d 件選択）"), n, m) : String(format: L("%d 件"), n)
    }

    /// 行を作り直さずに選択の表示だけ変える（ドラッグ中の行を消さないため）
    func updateSelection() {
        for case let row as ItemRowView in list.subviews { row.isSelected = shelf?.selected.contains(row.item.id) == true }
        updateCount()
    }

    private func layoutRows() {
        // 2 列のタイルに並べる
        let w = scroll.contentSize.width
        let pad: CGFloat = 6
        let tileW = (w - pad * 2) / CGFloat(Self.columns)
        // キャプションを折り返すので、段ごとに高い方へそろえる
        let rows = list.subviews.compactMap { $0 as? ItemRowView }
        var y = pad
        for start in stride(from: 0, to: rows.count, by: Self.columns) {
            let line = rows[start..<min(start + Self.columns, rows.count)]
            let h = max(Self.minTileHeight, line.map { $0.neededHeight(width: tileW) }.max() ?? 0)
            for (j, row) in line.enumerated() {
                row.frame = NSRect(x: pad + CGFloat(j) * tileW, y: y, width: tileW, height: h)
            }
            y += h
        }
        list.frame = NSRect(x: 0, y: 0, width: w, height: max(y + pad, scroll.contentSize.height))
    }

    /// 1 クリックで棚を空にする（空になった棚は閉じる）
    @objc private func clearAll() {
        guard let shelf else { return }
        shelf.remove(shelf.data.items.map(\.id), discard: true)
        shelf.collapse()
    }

    @objc private func showMenu(_ sender: NSButton) {
        guard let shelf else { return }
        let menu = NSMenu()
        menu.addItem(MenuAction(L("クリップボードから貼り付け")) { shelf.paste() })
        let copyAll = MenuAction(L("すべてコピー")) { shelf.copy(shelf.data.items) }
        copyAll.isEnabled = !shelf.data.items.isEmpty
        menu.addItem(copyAll)
        menu.addItem(.separator())
        let clear = MenuAction(L("すべて取り除いて棚を閉じる")) {
            shelf.remove(shelf.data.items.map(\.id), discard: true)
            shelf.collapse()
        }
        menu.addItem(clear)
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
}

/// 見出しの何もないところをドラッグすると、棚を上下に動かせる
final class HeaderView: NSView {
    weak var shelf: Shelf?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // 他のアプリを使っていても 1 回目のクリックで反応する
    private var startMouse: NSPoint = .zero
    private var startMidY: CGFloat = 0

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startMidY = window?.frame.midY ?? 0
    }
    override func mouseDragged(with event: NSEvent) {
        shelf?.moveVertically(to: startMidY + NSEvent.mouseLocation.y - startMouse.y)
    }
    override func mouseUp(with event: NSEvent) {
        shelf?.manager.save()
    }
}

/// ドラッグで棚の外へ運べるビュー（1 行、または見出しの「すべて」）
class DragSourceView: NSView, NSDraggingSource {
    weak var shelf: Shelf?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // 他のアプリを使っていても 1 回目のクリックで反応する
    var dragItems: [ShelfItem] = []
    private(set) var draggedItems: [ShelfItem] = []   // いまドラッグしている項目
    var image: NSImage? { didSet { needsDisplay = true } }
    private var downEvent: NSEvent?

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 3 else { return }
        downEvent = nil
        draggedItems = itemsToDrag()
        guard !draggedItems.isEmpty else { return }
        let icon = dragIcon()
        // 表示している大きさで、縦横比を保った枠
        let r = iconRect(), sz = icon?.size ?? r.size
        let k = min(r.width / max(sz.width, 1), r.height / max(sz.height, 1))
        let frame = NSRect(x: r.midX - sz.width * k / 2, y: r.midY - sz.height * k / 2,
                           width: sz.width * k, height: sz.height * k)
        var items: [NSDraggingItem] = []
        for (i, e) in draggedItems.flatMap(\.entries).enumerated() {
            guard let w = e.writer else { continue }
            let d = NSDraggingItem(pasteboardWriter: w)
            let off = CGFloat(min(i, 4)) * 4
            d.setDraggingFrame(frame.offsetBy(dx: off, dy: -off), contents: icon)
            items.append(d)
        }
        guard !items.isEmpty else { return }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func itemsToDrag() -> [ShelfItem] { dragItems }
    func iconRect() -> NSRect { bounds }
    func dragIcon() -> NSImage? { image }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        shelf?.draggingOut = true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let shelf else { return }
        shelf.draggingOut = false
        // 取り出したら棚から消す（移動）。やめたときは残す。
        // Finder が受け取るのはファイルだけなので、テキストとリンクは棚に残す。
        // （どれを受け取ったかは macOS が教えてくれない。ドロップ時にすべてのデータが読まれるため、ドロップ先のアプリで見分ける）
        // 写真などから作ったファイルは、行き先のアプリがまだ読んでいるかもしれないので、ここでは消さず次の起動時に片付ける
        if operation != [] {
            let ontoShelf = shelf.manager.shelves.contains { $0 !== shelf && $0.panel.frame.contains(screenPoint) }
            if !ontoShelf && Self.appBundleID(at: screenPoint) == "com.apple.finder" {
                var taken: [UUID: Set<Int>] = [:]
                for item in draggedItems {
                    taken[item.id] = Set(item.entries.indices.filter { item.entries[$0].kind == .file })
                }
                shelf.removeEntries(taken)
            } else {
                shelf.remove(draggedItems.map(\.id), discard: false)
            }
        }
        draggedItems = []
    }

    /// 画面上の点にある、いちばん手前のウインドウのアプリ（このアプリ自身は除く）
    static func appBundleID(at p: NSPoint) -> String? {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let cg = CGPoint(x: p.x, y: top - p.y)   // ウインドウ一覧は左上が原点
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  // マウスカーソルや、Dock が画面全体に張っている透明なウインドウは除く
                  !["Window Server", "Dock"].contains(w[kCGWindowOwnerName as String] as? String ?? ""),
                  (w[kCGWindowLayer as String] as? Int ?? 0) < 25,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.contains(cg) else { continue }
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
        return nil
    }
}

/// 棚の 1 項目（大きなサムネイルと、その下のキャプション）
final class ItemRowView: DragSourceView {
    let item: ShelfItem
    var isSelected = false { didSet { needsDisplay = true } }
    private let label = NSTextField(wrappingLabelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")   // 縦横のピクセル数・サイズ・文字数
    private static var thumbs: [String: NSImage] = [:]
    private static var infos: [String: String] = [:]

    init(item: ShelfItem, shelf: Shelf) {
        self.item = item
        super.init(frame: .zero)
        self.shelf = shelf
        dragItems = [item]
        label.stringValue = item.title
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        // 省略せず折り返して全部見せる（空白のない長いファイル名も文字単位で折り返す）。
        // テキストのメモは 1 行目が長いこともあるので 6 行まで
        label.maximumNumberOfLines = item.entries[0].kind == .text ? 6 : 0
        label.lineBreakMode = .byCharWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.textColor = item.missing ? .tertiaryLabelColor : .labelColor
        label.autoresizingMask = [.width]
        addSubview(label)
        infoLabel.stringValue = item.missing ? "" : Self.info(for: item)
        infoLabel.font = .systemFont(ofSize: 10)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.alignment = .center
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.maximumNumberOfLines = 2
        infoLabel.isHidden = infoLabel.stringValue.isEmpty
        addSubview(infoLabel)
        toolTip = item.missing ? String(format: L("見つかりません：%@"), item.entries.first?.path ?? "")
                               : item.entries.map { $0.fileURL?.path ?? $0.text ?? "" }.joined(separator: "\n")
        loadIcon()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let r = iconRect()
        let infoH = infoHeight
        label.frame = NSRect(x: 6, y: r.maxY + 6, width: bounds.width - 12, height: bounds.height - r.maxY - 10 - infoH)
        infoLabel.frame = NSRect(x: 6, y: label.frame.maxY, width: bounds.width - 12, height: infoH)
    }

    /// 画像は縦横とサイズの 2 行
    private var infoHeight: CGFloat {
        infoLabel.isHidden ? 0 : CGFloat(infoLabel.stringValue.split(separator: "\n").count) * 13 + 2
    }

    /// 同じファイルを何度も読まないように覚えておく（中身が置き換わるとキーも変わる）
    private static func info(for item: ShelfItem) -> String {
        let key = item.entries.map { $0.path ?? "\($0.text?.count ?? 0)" }.joined(separator: "|")
        if let s = infos[key] { return s }
        let s = ItemInfo.text(for: item)
        infos[key] = s
        return s
    }

    /// 幅 width のとき、キャプションを全部表示するのに要る高さ
    func neededHeight(width: CGFloat) -> CGFloat {
        let labelW = width - 12
        let h = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: labelW, height: 10_000)).height ?? 16
        return 8 + Self.iconSize + 6 + ceil(h) + infoHeight + 10
    }

    static let iconSize: CGFloat = 100
    override func iconRect() -> NSRect {
        NSRect(x: (bounds.width - Self.iconSize) / 2, y: 8, width: Self.iconSize, height: Self.iconSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
        guard let image else { return }
        // 縦横比を保って枠に収める
        let r = iconRect()
        let s = image.size
        var k = min(r.width / max(s.width, 1), r.height / max(s.height, 1))
        if item.entries[0].fileURL == nil { k = min(k, 1) }   // 記号は拡大しない
        let size = NSSize(width: s.width * k, height: s.height * k)
        image.draw(in: NSRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2,
                              width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: item.missing ? 0.4 : 1,
                   respectFlipped: true, hints: nil)
        if item.entries.count > 1 { drawBadge("\(item.entries.count)", in: r) }
    }

    private func drawBadge(_ s: String, in r: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold),
                                                    .foregroundColor: NSColor.white]
        let sz = (s as NSString).size(withAttributes: attrs)
        let w = max(sz.width + 8, 16)
        let badge = NSRect(x: r.maxX - w + 4, y: r.minY - 2, width: w, height: 16)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
        (s as NSString).draw(at: NSPoint(x: badge.midX - sz.width / 2, y: badge.midY - sz.height / 2), withAttributes: attrs)
    }

    override func dragIcon() -> NSImage? {
        guard let image else { return nil }
        let s = image.size, k = Self.iconSize / max(s.width, s.height, 1)
        let out = NSImage(size: NSSize(width: s.width * k, height: s.height * k))
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: out.size))
        out.unlockFocus()
        return out
    }

    private func loadIcon() {
        let first = item.entries[0]
        switch first.kind {
        case .text: image = symbol("doc.plaintext", size: 44)
        case .link: image = symbol("link", size: 44)
        case .file:
            guard let url = first.fileURL else {
                image = symbol("questionmark.folder", size: 44)
                return
            }
            if let t = Self.thumbs[url.path] { image = t; return }
            image = NSWorkspace.shared.icon(forFile: url.path)
            // 画像などは中身のサムネイルに差し替える
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: Self.iconSize, height: Self.iconSize),
                                                   scale: scale, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
                guard let img = rep?.nsImage else { return }
                DispatchQueue.main.async {
                    Self.thumbs[url.path] = img
                    self?.image = img
                }
            }
        }
    }

    private var reduceOnUp = false   // 選択中の項目を押しただけ（ドラッグしなかった）なら、離したときにそれだけを選ぶ

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let shelf else { return }
        window?.makeKey()
        window?.makeFirstResponder(window?.contentView)
        reduceOnUp = false
        let mods = event.modifierFlags
        if event.clickCount == 2 {
            shelf.open(shelf.selectedItems)
        } else if mods.contains(.command) {
            shelf.select(item.id, toggle: true)
        } else if mods.contains(.shift) {
            shelf.select(item.id, extend: true)
        } else if shelf.selected.contains(item.id) {
            reduceOnUp = true   // 複数選択したままドラッグできるように、ここでは選択を変えない
        } else {
            shelf.select(item.id)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if reduceOnUp { shelf?.select(item.id) }
        reduceOnUp = false
    }

    /// 選択中の項目を掴んだら、選択中のものをまとめて運ぶ
    override func itemsToDrag() -> [ShelfItem] {
        guard let shelf, shelf.selected.contains(item.id) else { return [item] }
        return shelf.selectedItems
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let shelf else { return nil }
        if !shelf.selected.contains(item.id) { shelf.select(item.id) }
        let items = shelf.selectedItems
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hasFile = items.contains { !$0.fileURLs.isEmpty }
        let open = MenuAction(L("開く")) { shelf.open(items) }
        open.isEnabled = hasFile || items.flatMap(\.entries).contains { $0.kind == .link }
        menu.addItem(open)
        let preview = MenuAction(L("プレビュー")) { shelf.togglePreview() }
        preview.isEnabled = hasFile
        menu.addItem(preview)
        let reveal = MenuAction(L("Finder で表示")) { shelf.reveal(items) }
        reveal.isEnabled = hasFile
        menu.addItem(reveal)
        menu.addItem(MenuAction(L("コピー")) { shelf.copy(items) })
        if items.flatMap(\.fileURLs).contains(where: JPEGConvert.canConvert) {
            menu.addItem(MenuAction(L("JPEG に変換")) { shelf.convertToJPEG(items.map(\.id)) })
        }
        if items.count == 1, items[0].entries.count > 1 {
            menu.addItem(MenuAction(L("ばらす")) { shelf.split(items[0].id) })
        }
        menu.addItem(.separator())
        let ids = items.map(\.id)
        menu.addItem(MenuAction(items.count > 1 ? String(format: L("%d 件を取り除く"), items.count) : L("取り除く")) {
            shelf.remove(ids, discard: true)
        })
        return menu
    }
}

/// 色つきの SF Symbol（そのまま描くと黒になり、ダークモードで見えないため）
func symbol(_ name: String, size: CGFloat = 22) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        .applying(.init(paletteColors: [.secondaryLabelColor]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
}

/// クロージャで動くメニュー項目
final class MenuAction: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}


