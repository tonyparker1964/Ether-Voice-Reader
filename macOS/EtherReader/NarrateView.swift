import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct NarrateView: View {
    @ObservedObject var engine: VoiceEngine
    @StateObject private var player = Player()
    @AppStorage("narrateText") private var text = ""
    @State private var book: Book? = BookStore.load()
    @State private var opening = false
    @State private var openError = ""

    var body: some View {
        Screen(title: "Your Words. Your Voice.",
               subtitle: "Open a whole book or paste a passage, then generate it in your voice. Everything runs on this Mac.") {
            if !engine.installed {
                Notice(text: "Install the voice engine first (Voice Engine page).")
            }
            if !engine.hasSample {
                Notice(text: "Record your voice first (Record Voice page).")
            }

            Card(title: "Book") {
                HStack {
                    Button {
                        openBook()
                    } label: { Label("Open book…", systemImage: "book") }
                    .disabled(opening)
                    if opening {
                        ProgressView().controlSize(.small)
                        Text("Opening book…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if book != nil {
                        Button("Close book") { closeBook() }
                    }
                }
                if let book {
                    Text(book.title).font(.custom("Georgia", size: 18)).foregroundStyle(Theme.gold)
                    HStack {
                        Button { goToChapter(book.current - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(book.current <= 0)
                        Picker("Chapter", selection: Binding(get: { book.current }, set: { goToChapter($0) })) {
                            ForEach(book.chapters.indices, id: \.self) { i in
                                Text("\(i + 1). \(book.chapters[i].title)").tag(i)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 460)
                        Button { goToChapter(book.current + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(book.current >= book.chapters.count - 1)
                    }
                    Text("Chapter \(book.current + 1) of \(book.chapters.count) · the chapter is placed in the passage below, ready to generate.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("PDF, EPUB, Word (.docx / .doc), RTF, OpenDocument, HTML, Markdown or plain text. The book is split into chapters you can step through.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !openError.isEmpty { Notice(text: openError) }
            }

            Card(title: "Passage") {
                HStack {
                    Spacer()
                    Button("Clear") { text = "" }.disabled(text.isEmpty)
                }
                TextEditor(text: $text)
                    .font(.custom("Georgia", size: 17))
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                Text("\(text.count) characters · long passages are read in parts and joined together")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Card(title: "Generate") {
                HStack {
                    if engine.generating {
                        Button("Stop") { engine.cancel() }
                        ProgressView(value: engine.progress).frame(maxWidth: 240)
                    } else {
                        Button {
                            player.stop()
                            engine.speak(text)
                        } label: { Label("Generate in my voice", systemImage: "waveform") }
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                if !engine.status.isEmpty { Text(engine.status).foregroundStyle(Theme.gold) }
                Text("The first narration downloads and loads the voice model, which can take several minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                PlayerControls(player: player)
                HStack {
                    Button("Save narration…") { saveNarration() }
                        .disabled(player.loadedURL == nil)
                    Button("Show in Finder") {
                        if let url = player.loadedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .disabled(player.loadedURL == nil)
                }
            }
        }
        .onAppear {
            if let last = engine.lastNarration, player.loadedURL == nil { player.load(last) }
        }
        .onDisappear { player.pause() }
        .onChange(of: engine.lastNarration) { _, url in
            if let url, player.load(url) { player.play() }
        }
    }

    private func openBook() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = BookLoader.contentTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choose a book or text file to read"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        opening = true
        openError = ""
        Task.detached(priority: .userInitiated) {
            let result = Result { try BookLoader.load(url) }
            await MainActor.run {
                opening = false
                switch result {
                case .success(let loaded):
                    book = loaded
                    BookStore.save(loaded)
                    text = loaded.chapters[loaded.current].text
                case .failure(let error):
                    openError = "Could not open this file: \(error.localizedDescription)"
                }
            }
        }
    }

    private func goToChapter(_ index: Int) {
        guard var current = book, current.chapters.indices.contains(index) else { return }
        current.current = index
        book = current
        BookStore.save(current)
        text = current.chapters[index].text
    }

    private func closeBook() {
        book = nil
        BookStore.clear()
        openError = ""
    }

    private func saveNarration() {
        guard let source = player.loadedURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        var name = "Ether narration"
        if let book { name = "\(book.title) – \(book.chapters[book.current].title)" }
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + ".wav"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            engine.status = "Could not save: \(error.localizedDescription)"
        }
    }
}

// MARK: - Book model

struct BookChapter: Codable, Hashable {
    var title: String
    var text: String
}

struct Book: Codable {
    var title: String
    var chapters: [BookChapter]
    var current: Int = 0
}

/// Keeps the open book (and the chapter you were on) between launches.
enum BookStore {
    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Ether Reader/current-book.json")
    }

    static func load() -> Book? {
        guard let data = try? Data(contentsOf: url),
              var book = try? JSONDecoder().decode(Book.self, from: data),
              !book.chapters.isEmpty else { return nil }
        book.current = min(max(0, book.current), book.chapters.count - 1)
        return book
    }

    static func save(_ book: Book) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(book) { try? data.write(to: url, options: .atomic) }
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}

// MARK: - Loading books

enum BookError: LocalizedError {
    case unreadable, empty, epub(String)
    var errorDescription: String? {
        switch self {
        case .unreadable: return "the file couldn't be read."
        case .empty: return "no readable text was found (a scanned PDF has pictures of pages, not text)."
        case .epub(let why): return why
        }
    }
}

enum BookLoader {
    static var contentTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .text, .rtf, .rtfd, .html]
        for ext in ["epub", "docx", "doc", "odt", "md", "markdown", "xhtml"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    static func load(_ url: URL) throws -> Book {
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent
        var chapters: [BookChapter]
        var title = name
        switch ext {
        case "pdf":
            (title, chapters) = try loadPDF(url, fallbackTitle: name)
        case "epub":
            (title, chapters) = try loadEPUB(url, fallbackTitle: name)
        case "html", "htm", "xhtml":
            guard let data = try? Data(contentsOf: url) else { throw BookError.unreadable }
            let html = String(decoding: data, as: UTF8.self)
            chapters = splitIntoChapters(htmlToText(html))
        case "docx", "doc", "odt", "rtf", "rtfd":
            let types: [String: NSAttributedString.DocumentType] = [
                "docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument, "rtf": .rtf, "rtfd": .rtfd,
            ]
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            if let type = types[ext] { options[.documentType] = type }
            guard let attributed = try? NSAttributedString(url: url, options: options, documentAttributes: nil)
            else { throw BookError.unreadable }
            chapters = splitIntoChapters(attributed.string)
        default:
            guard let data = try? Data(contentsOf: url) else { throw BookError.unreadable }
            let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            chapters = splitIntoChapters(raw)
        }
        chapters = chapters
            .map { BookChapter(title: $0.title, text: tidy($0.text)) }
            .filter { !$0.text.isEmpty }
        guard !chapters.isEmpty else { throw BookError.empty }
        return Book(title: title.isEmpty ? name : title, chapters: chapters)
    }

    // PDF: chapters from the PDF's table of contents when it has one, otherwise 10 pages at a time.
    private static func loadPDF(_ url: URL, fallbackTitle: String) throws -> (String, [BookChapter]) {
        guard let pdf = PDFDocument(url: url) else { throw BookError.unreadable }
        let count = pdf.pageCount
        guard count > 0 else { throw BookError.empty }
        let pages: [String] = (0..<count).map { pdf.page(at: $0)?.string ?? "" }
        let title = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var marks: [(title: String, page: Int)] = []
        if let root = pdf.outlineRoot {
            for i in 0..<root.numberOfChildren {
                guard let item = root.child(at: i), let page = item.destination?.page else { continue }
                let index = pdf.index(for: page)
                if index >= 0, index < count { marks.append((item.label ?? "Section \(i + 1)", index)) }
            }
        }
        marks.sort { $0.page < $1.page }
        var chapters: [BookChapter] = []
        if marks.count >= 2 {
            if marks[0].page > 0 { marks.insert(("Opening pages", 0), at: 0) }
            for (n, mark) in marks.enumerated() {
                let end = n + 1 < marks.count ? marks[n + 1].page : count
                guard end > mark.page else { continue }
                chapters.append(BookChapter(title: mark.title, text: pdfText(pages[mark.page..<end])))
            }
        } else {
            let size = 10
            for start in stride(from: 0, to: count, by: size) {
                let end = min(start + size, count)
                let label = end - start == 1 ? "Page \(start + 1)" : "Pages \(start + 1)–\(end)"
                chapters.append(BookChapter(title: label, text: pdfText(pages[start..<end])))
            }
        }
        return (title.isEmpty ? fallbackTitle : title, chapters)
    }

    /// Joins PDF page text, re-flowing the hard line breaks inside paragraphs.
    private static func pdfText(_ pages: ArraySlice<String>) -> String {
        pages.map { page in
            var s = page.replacingOccurrences(of: "\r", with: "\n")
            s = s.replacingOccurrences(of: "(\\w)-\\n(\\w)", with: "$1$2", options: .regularExpression)
            s = s.replacingOccurrences(of: "\\n{2,}", with: "\u{2029}", options: .regularExpression)
            s = s.replacingOccurrences(of: "\\n", with: " ", options: .regularExpression)
            return s.replacingOccurrences(of: "\u{2029}", with: "\n\n")
        }.joined(separator: "\n\n")
    }

    // EPUB: a zip of XHTML files; the reading order comes from the package (OPF) spine.
    private static func loadEPUB(_ url: URL, fallbackTitle: String) throws -> (String, [BookChapter]) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ether-epub-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-qq", "-o", url.path, "-d", tmp.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()

        guard let container = try? String(contentsOf: tmp.appendingPathComponent("META-INF/container.xml"), encoding: .utf8),
              let opfPath = firstMatch("full-path\\s*=\\s*\"([^\"]+)\"", in: container)
        else { throw BookError.epub("this EPUB has no package file.") }
        let opfURL = tmp.appendingPathComponent(opfPath)
        guard let opf = try? String(contentsOf: opfURL, encoding: .utf8) else {
            throw BookError.epub("this EPUB's package file couldn't be read.")
        }
        let base = opfURL.deletingLastPathComponent()
        let title = firstMatch("<dc:title[^>]*>([\\s\\S]*?)</dc:title>", in: opf).map { decodeEntities(stripTags($0)) } ?? ""

        var manifest: [String: String] = [:]
        for tag in allMatches("<item\\b[^>]*>", in: opf) {
            if let id = attribute("id", in: tag), let href = attribute("href", in: tag) { manifest[id] = href }
        }
        let spine = allMatches("<itemref\\b[^>]*>", in: opf).compactMap { attribute("idref", in: $0) }

        var chapters: [BookChapter] = []
        for idref in spine {
            guard let href = manifest[idref] else { continue }
            let path = (href.components(separatedBy: "#").first ?? href).removingPercentEncoding ?? href
            guard let data = try? Data(contentsOf: base.appendingPathComponent(path)) else { continue }
            let html = String(decoding: data, as: UTF8.self)
            let body = htmlToText(html)
            guard body.count > 40 else { continue } // skip covers and blank pages
            let heading = firstMatch("<h[1-3][^>]*>([\\s\\S]*?)</h[1-3]>", in: html)
                ?? firstMatch("<title[^>]*>([\\s\\S]*?)</title>", in: html)
            var label = heading.map { decodeEntities(stripTags($0)).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            label = label.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if label.isEmpty || label.count > 80 { label = "Section \(chapters.count + 1)" }
            chapters.append(BookChapter(title: label, text: body))
        }
        guard !chapters.isEmpty else { throw BookError.empty }
        return (title.isEmpty ? fallbackTitle : title, chapters)
    }

    // Plain text: split on lines like "Chapter 4", "Part Two", "Prologue" or Markdown headings;
    // otherwise into parts of about 6,000 characters at paragraph breaks.
    static func splitIntoChapters(_ raw: String) -> [BookChapter] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")
        let pattern = "^\\s*(#{1,2}\\s+\\S.*|(chapter|book|part)\\s+([0-9ivxlcdm]+|[a-z-]+)\\b.{0,60}|(prologue|epilogue|introduction|preface|foreword|afterword)\\b.{0,40})\\s*$"
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        var chapters: [BookChapter] = []
        var currentTitle = "Opening"
        var buffer: [String] = []
        func flush() {
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { chapters.append(BookChapter(title: currentTitle, text: body)) }
            buffer = []
        }
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if line.count <= 80, regex?.firstMatch(in: line, range: range) != nil {
                flush()
                currentTitle = line.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
            } else {
                buffer.append(line)
            }
        }
        flush()
        if chapters.count >= 2 { return chapters }
        return splitBySize(text)
    }

    private static func splitBySize(_ text: String, target: Int = 6000) -> [BookChapter] {
        let paragraphs = text.components(separatedBy: "\n\n")
        var parts: [String] = []
        var current = ""
        for p in paragraphs {
            if current.count + p.count > target, !current.isEmpty {
                parts.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n\n") + p
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(current) }
        if parts.count <= 1 { return [BookChapter(title: "Full text", text: text)] }
        return parts.enumerated().map { BookChapter(title: "Part \($0.offset + 1)", text: $0.element) }
    }

    // MARK: Text helpers

    static func htmlToText(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<(head|script|style)\\b[\\s\\S]*?</\\1>", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(p|div|h[1-6]|li|blockquote|tr|section)>", with: "\n\n", options: [.regularExpression, .caseInsensitive])
        s = stripTags(s)
        s = decodeEntities(s)
        return tidy(s)
    }

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
                     "&#39;": "'", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“",
                     "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") else { return out }
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            let digits = ns.substring(with: m.range(at: 2))
            if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result += String(Character(scalar))
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// Normalises spaces and blank lines.
    static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        t = t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        firstMatch("\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']", in: tag)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}
