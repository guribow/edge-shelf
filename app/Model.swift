// 棚と項目のデータ、保存、ドロップ（貼り付け）の読み取り
import AppKit

enum Edge: String, Codable { case left, right }

/// 棚に置いた 1 つのもの（ファイル・テキスト・リンク）
struct Entry: Codable {
    enum Kind: String, Codable { case file, text, link }
    var kind: Kind
    var path: String? = nil
    var bookmark: Data? = nil   // ファイルが移動されても追いかけられるように
    var owned = false           // 写真や Web の画像から作った、このアプリが持つファイル
    var text: String? = nil

    static func file(_ url: URL, owned: Bool = false) -> Entry {
        let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return Entry(kind: .file, path: url.path, bookmark: bm, owned: owned)
    }
    static func text(_ s: String) -> Entry { Entry(kind: .text, text: s) }
    static func link(_ s: String) -> Entry { Entry(kind: .link, text: s) }

    /// ファイルの今の場所。見つからなければ nil
    var fileURL: URL? {
        guard kind == .file else { return nil }
        if let bm = bookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bm, options: [.withoutUI, .withoutMounting],
                                relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: u.path) { return u }
        }
        guard let p = path, FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    var title: String {
        switch kind {
        case .file:
            return fileURL?.lastPathComponent ?? ((path ?? "") as NSString).lastPathComponent
        case .text:
            let line = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first ?? ""
            return line.isEmpty ? "テキスト" : line
        case .link:
            return text ?? ""
        }
    }

    /// ドラッグやコピーで渡すもの
    var writer: NSPasteboardWriting? {
        switch kind {
        case .file:
            return fileURL as NSURL?
        case .text:
            return text as NSString?
        case .link:
            guard let s = text else { return nil }
            let item = NSPasteboardItem()
            item.setString(s, forType: .URL)
            item.setString(s, forType: .string)
            return item
        }
    }
}

/// 棚の 1 行。複数のファイルを一度に置くと 1 つにまとまり、まとめてドラッグできる
struct ShelfItem: Codable {
    var id = UUID()
    var entries: [Entry]

    var title: String { entries.count == 1 ? entries[0].title : "\(entries.count) 項目" }
    var fileURLs: [URL] { entries.compactMap(\.fileURL) }
    var missing: Bool { entries.allSatisfy { $0.kind == .file && $0.fileURL == nil } }
}

struct ShelfData: Codable {
    var id = UUID()
    var displayID: UInt32
    var edge: Edge
    var position: Double      // つまみの中心が画面の縦のどこにあるか（0 = 下、1 = 上）
    var tabAnchored: Bool? = nil   // position がつまみの中心か（nil は古い形式：開いた棚の中心）
    var items: [ShelfItem] = []
}

extension NSScreen {
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

enum Store {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EdgeShelf")
    static let filesDir = dir.appendingPathComponent("Files")
    private static let jsonURL = dir.appendingPathComponent("shelves.json")

    static func load() -> [ShelfData] {
        guard let data = try? Data(contentsOf: jsonURL) else { return [] }
        return (try? JSONDecoder().decode([ShelfData].self, from: data)) ?? []
    }

    static func save(_ shelves: [ShelfData]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try? enc.encode(shelves).write(to: jsonURL, options: .atomic)
    }

    /// 画像などを受け取るための新しいフォルダ（Files/<UUID>/）
    static func newFolder() -> URL {
        let url = filesDir.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func isInFilesDir(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(filesDir.standardizedFileURL.path + "/")
    }

    /// 棚から取り除いた項目のうち、このアプリが作ったファイルを消す。
    /// Finder などへ移動済みのもの（Files の外にあるもの）は消さない。
    static func discard(_ item: ShelfItem) {
        for e in item.entries where e.owned {
            guard let url = e.fileURL, isInFilesDir(url) else { continue }
            try? FileManager.default.removeItem(at: url)
            let folder = url.deletingLastPathComponent()
            if folder.standardizedFileURL != filesDir.standardizedFileURL,
               (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// どの棚からも使われていない Files 内のフォルダを片付ける
    static func cleanUp(_ shelves: [ShelfData]) {
        let used = shelves.flatMap(\.items).flatMap(\.entries).filter(\.owned)
            .compactMap { $0.fileURL?.standardizedFileURL.path }
        let folders = (try? FileManager.default.contentsOfDirectory(at: filesDir, includingPropertiesForKeys: nil)) ?? []
        for f in folders where !used.contains(where: { $0.hasPrefix(f.standardizedFileURL.path + "/") }) {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

/// ドロップやクリップボードの中身を棚の項目にする
enum DropReader {
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()
    private static let imageTypes: [NSPasteboard.PasteboardType] =
        [.png, .tiff, .init("public.jpeg"), .init("public.heic")]

    /// 読み取れたら true。写真アプリなどの「約束ファイル」は後から届くので、届くたびに add が呼ばれる
    @discardableResult
    static func read(_ pb: NSPasteboard, add: @escaping ([Entry]) -> Void) -> Bool {
        // 1. ファイル
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            add(urls.map { .file($0) })
            return true
        }
        let promises = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
        let webURL = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first { !$0.isFileURL }
        let hasImage = pb.availableType(from: imageTypes) != nil

        // 2. 画像（写真アプリ、Web ページの画像）はファイルにする
        if hasImage {
            if !promises.isEmpty { receive(promises, add); return true }
            if let e = saveImage(pb, name: webURL?.lastPathComponent) { add([e]); return true }
        }
        // 3. リンク
        if let u = webURL { add([.link(u.absoluteString)]); return true }
        // 4. そのほかの約束ファイル
        if !promises.isEmpty { receive(promises, add); return true }
        // 5. テキスト
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.contains(where: \.isWhitespace), let u = URL(string: t), ["http", "https"].contains(u.scheme ?? "") {
                add([.link(t)])
            } else {
                add([.text(s)])
            }
            return true
        }
        return false
    }

    private static func receive(_ promises: [NSFilePromiseReceiver], _ add: @escaping ([Entry]) -> Void) {
        let folder = Store.newFolder()
        for p in promises {
            p.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                if let error { NSLog("EdgeShelf: 受け取りに失敗: \(error.localizedDescription)"); return }
                DispatchQueue.main.async { add([.file(url, owned: true)]) }
            }
        }
    }

    private static func saveImage(_ pb: NSPasteboard, name: String?) -> Entry? {
        var data: Data?
        var ext = "png"
        if let d = pb.data(forType: .png) {
            data = d
        } else if let d = pb.data(forType: .init("public.jpeg")) {
            data = d; ext = "jpg"
        } else if let d = pb.data(forType: .init("public.heic")) {
            data = d; ext = "heic"
        } else if let d = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: d) {
            data = rep.representation(using: .png, properties: [:])
        }
        guard let data else { return nil }
        var base = ((name ?? "") as NSString).deletingPathExtension
        if base.isEmpty || base == "/" {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            base = "画像 " + f.string(from: Date())
        }
        let url = Store.newFolder().appendingPathComponent(base).appendingPathExtension(ext)
        do { try data.write(to: url) } catch { return nil }
        return .file(url, owned: true)
    }
}
