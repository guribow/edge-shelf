// 棚と項目のデータ、保存、ドロップ（貼り付け）の読み取り
import AppKit
import Photos
import UniformTypeIdentifiers

enum Edge: String, Codable { case left, right }

/// 画面に出す文字列。日本語をキーにし、英語は en.lproj/Localizable.strings で訳す（Mac の言語設定で自動で切り替わる）
func L(_ ja: String) -> String { NSLocalizedString(ja, comment: "") }

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
            return line.isEmpty ? L("テキスト") : line
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

    var title: String { entries.count == 1 ? entries[0].title : String(format: L("%d 項目"), entries.count) }
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
        // 1. ファイル。写真アプリは、ライブラリの中のファイル（名前が UUID、編集前の元のもの）をそのまま渡してくる。
        //    参照で置くと、棚から Finder へ出したときにライブラリから抜き取ってしまうので、写真アプリから書き出して置く
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let (photos, files) = (urls.filter(PhotosImport.isInLibrary), urls.filter { !PhotosImport.isInLibrary($0) })
            if !files.isEmpty { add(files.map { .file($0) }) }
            if !photos.isEmpty { PhotosImport.receive(photos, add) }
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
            base = L("画像") + " " + f.string(from: Date())
        }
        let url = Store.newFolder().appendingPathComponent(base).appendingPathExtension(ext)
        do { try data.write(to: url) } catch { return nil }
        return .file(url, owned: true)
    }
}

/// 写真アプリのライブラリの中のファイルを、写真アプリ（PhotoKit）から書き出して受け取る
enum PhotosImport {
    static func isInLibrary(_ url: URL) -> Bool {
        url.pathComponents.contains { $0.hasSuffix(".photoslibrary") }
    }

    /// ライブラリの中のファイル名は「<UUID>.拡張子」や「<UUID>_1_201_a.jpeg」。先頭の UUID が写真の ID になる
    private static func assetID(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count >= 36, UUID(uuidString: String(name.prefix(36))) != nil else { return nil }
        return String(name.prefix(36)) + "/L0/001"
    }

    static func receive(_ urls: [URL], _ add: @escaping ([Entry]) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            let allowed = status == .authorized || status == .limited
            for url in urls {
                guard allowed, let id = assetID(url),
                      let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
                else { copy(url, add); continue }
                export(asset) { exported in
                    guard let exported else { copy(url, add); return }
                    DispatchQueue.main.async { add([.file(exported, owned: true)]) }
                }
            }
        }
    }

    /// 写真へのアクセスを許可されていないときは、ライブラリのファイルをそのままコピーして置く（名前は UUID のまま）
    private static func copy(_ url: URL, _ add: @escaping ([Entry]) -> Void) {
        let dest = Store.newFolder().appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            DispatchQueue.main.async { add([.file(dest, owned: true)]) }
        } catch {
            NSLog("EdgeShelf: 写真を受け取れなかった: \(error.localizedDescription)")
            removeFolder(of: dest)
        }
    }

    /// 今の見た目（編集してあれば編集後）を、元のファイル名・フルサイズで書き出す。iCloud にしかなければダウンロードする
    private static func export(_ asset: PHAsset, done: @escaping (URL?) -> Void) {
        let resources = PHAssetResource.assetResources(for: asset)
        let isVideo = asset.mediaType == .video
        let original = resources.first { $0.type == (isVideo ? .video : .photo) }
        let current = resources.first { $0.type == (isVideo ? .fullSizeVideo : .fullSizePhoto) } ?? original
        guard let original, let current else { done(nil); return }
        let base = (original.originalFilename as NSString).deletingPathExtension
        let ext = (current.originalFilename as NSString).pathExtension
        let dest = Store.newFolder().appendingPathComponent(base).appendingPathExtension(ext)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().writeData(for: current, toFile: dest, options: options) { error in
            if let error {
                NSLog("EdgeShelf: 写真の書き出しに失敗: \(error.localizedDescription)")
                removeFolder(of: dest)
                done(nil)
            } else {
                done(dest)
            }
        }
    }

    private static func removeFolder(of file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}

/// タイルの名前の下に出す情報（画像は縦横のピクセル数とサイズ、ファイルはサイズ、テキストは文字数）
enum ItemInfo {
    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// 画像はファイルの先頭（ヘッダー）だけを読むので軽い
    static func text(for item: ShelfItem) -> String {
        if item.entries.count > 1 {
            let urls = item.fileURLs
            guard urls.count == item.entries.count, let total = totalSize(urls) else { return "" }
            return String(format: L("合計 %@"), bytes.string(fromByteCount: total))
        }
        let e = item.entries[0]
        switch e.kind {
        case .text: return String(format: L("%d 文字"), (e.text ?? "").count)
        case .link: return ""
        case .file:
            guard let url = e.fileURL, let size = fileSize(url) else { return "" }
            let s = bytes.string(fromByteCount: size)
            if let (w, h) = pixelSize(url) { return "\(w) × \(h)\n\(s)" }   // 1 行だとタイルの幅に収まらない
            return s
        }
    }

    /// フォルダやアプリは中身を数えないので nil
    private static func fileSize(_ url: URL) -> Int64? {
        guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              v.isRegularFile == true, let s = v.fileSize else { return nil }
        return Int64(s)
    }

    private static func totalSize(_ urls: [URL]) -> Int64? {
        var total: Int64 = 0
        for u in urls { guard let s = fileSize(u) else { return nil }; total += s }
        return total
    }

    /// 画像の縦横。写真の向き（回転）を反映する
    private static func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(o) ? (h, w) : (w, h)
    }
}

/// 画像を JPEG に変換する。撮影日時や位置情報などの Exif はそのまま残す
enum JPEGConvert {
    static func canConvert(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .jpeg)
            && CGImageSourceCreateWithURL(url as CFURL, nil).map { CGImageSourceGetCount($0) > 0 } == true
    }

    /// 変換したファイル（Files/<UUID>/元の名前.jpg）。読めない画像なら nil
    static func convert(_ url: URL) -> URL? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        if hasAlpha(image), let flat = onWhite(image) { image = flat }   // JPEG は透明を扱えないので白で埋める
        let dest = Store.newFolder().appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("jpg")
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        var options = props
        options[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(out, image, options as CFDictionary)
        guard CGImageDestinationFinalize(out) else {
            try? FileManager.default.removeItem(at: dest.deletingLastPathComponent())
            return nil
        }
        return dest
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }

    private static func onWhite(_ image: CGImage) -> CGImage? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}
