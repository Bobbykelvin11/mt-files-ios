import SwiftUI
import UIKit

/// UITextView (TextKit 1) with a line-number gutter.
final class CodeTextView: UITextView {
    let gutter = LineGutterView()
    var lineStarts: [Int] = [0]
    var showLineNumbers = true { didSet { updateGutterWidth(); setNeedsLayout() } }

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        gutter.textView = self
        addSubview(gutter)
        backgroundColor = Theme.uiBG
        textColor = Highlighter.text
        font = Highlighter.font
        autocapitalizationType = .none
        autocorrectionType = .no
        spellCheckingType = .no
        smartDashesType = .no
        smartQuotesType = .no
        smartInsertDeleteType = .no
        keyboardAppearance = .dark
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        layoutManager.allowsNonContiguousLayout = true
        updateGutterWidth()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var gutterWidth: CGFloat {
        guard showLineNumbers else { return 0 }
        let digits = max(2, String(lineStarts.count).count)
        return CGFloat(digits) * 8.2 + 14
    }

    func updateGutterWidth() {
        let w = gutterWidth
        textContainerInset = UIEdgeInsets(top: 8, left: w + 6, bottom: 40, right: 8)
        gutter.isHidden = !showLineNumbers
    }

    func recomputeLines() {
        let ns = (text ?? "") as NSString
        var starts = [0]
        starts.reserveCapacity(ns.length / 30 + 1)
        let len = ns.length
        var i = 0
        // Fast scan of UTF-16 buffer for newlines.
        let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: max(len, 1))
        defer { buffer.deallocate() }
        ns.getCharacters(buffer, range: NSRange(location: 0, length: len))
        while i < len {
            if buffer[i] == 10 { starts.append(i + 1) }
            i += 1
        }
        let oldDigits = String(lineStarts.count).count
        lineStarts = starts
        if String(starts.count).count != oldDigits { updateGutterWidth() }
        gutter.setNeedsDisplay()
    }

    /// 1-based line number for a UTF-16 offset.
    func line(at offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gutter.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width: gutterWidth, height: bounds.height)
        bringSubviewToFront(gutter)
        gutter.setNeedsDisplay()
    }
}

final class LineGutterView: UIView {
    weak var textView: CodeTextView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.uiGutter
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let tv = textView else { return }
        let lm = tv.layoutManager
        let container = tv.textContainer
        let inset = tv.textContainerInset
        let visible = CGRect(x: 0, y: tv.contentOffset.y - inset.top, width: tv.bounds.width, height: tv.bounds.height)
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: container)
        let ns = (tv.text ?? "") as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: UIColor(white: 0.45, alpha: 1)
        ]
        let current = tv.line(at: tv.selectedRange.location)
        let currentAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: UIColor(red: 0.133, green: 0.765, blue: 0.651, alpha: 1)
        ]
        let w = bounds.width
        func drawNumber(_ n: Int, y: CGFloat, h: CGFloat) {
            let s = "\(n)" as NSString
            let a = n == current ? currentAttrs : attrs
            let size = s.size(withAttributes: a)
            s.draw(at: CGPoint(x: w - size.width - 6, y: y + (h - size.height) / 2), withAttributes: a)
        }
        if ns.length == 0 {
            drawNumber(1, y: inset.top - tv.contentOffset.y, h: Highlighter.font.lineHeight)
            return
        }
        lm.enumerateLineFragments(forGlyphRange: glyphs) { fragRect, _, _, glyphRange, _ in
            let charIndex = lm.characterIndexForGlyph(at: glyphRange.location)
            let isStart = charIndex == 0 || (charIndex <= ns.length && charIndex > 0 && ns.character(at: charIndex - 1) == 10)
            guard isStart else { return }
            let y = fragRect.minY + inset.top - tv.contentOffset.y
            drawNumber(tv.line(at: charIndex), y: y, h: fragRect.height)
        }
        // Trailing empty line after final newline
        if ns.length > 0, ns.character(at: ns.length - 1) == 10 {
            let r = lm.extraLineFragmentRect
            if r.height > 0 {
                drawNumber(tv.lineStarts.count, y: r.minY + inset.top - tv.contentOffset.y, h: r.height)
            }
        }
    }
}

/// Bridge so SwiftUI toolbars can drive the text view.
final class EditorController: ObservableObject {
    weak var textView: CodeTextView?
    @Published var dirty = false
    @Published var cursorLine = 1
    @Published var cursorColumn = 1
    @Published var lineCount = 1
    @Published var hasSelection = false
    @Published var canUndo = false
    @Published var canRedo = false
    var language: CodeLanguage = .plain
    var highlightWork: DispatchWorkItem?
    var initialText = ""

    var text: String { textView?.text ?? initialText }

    var selectedText: String? {
        guard let tv = textView, tv.selectedRange.length > 0 else { return nil }
        return ((tv.text ?? "") as NSString).substring(with: tv.selectedRange)
    }

    func refreshState() {
        guard let tv = textView else { return }
        let loc = tv.selectedRange.location
        let line = tv.line(at: loc)
        cursorLine = line
        let lineStart = line - 1 < tv.lineStarts.count ? tv.lineStarts[line - 1] : 0
        cursorColumn = loc - lineStart + 1
        lineCount = tv.lineStarts.count
        hasSelection = tv.selectedRange.length > 0
        canUndo = tv.undoManager?.canUndo ?? false
        canRedo = tv.undoManager?.canRedo ?? false
    }

    func scheduleHighlight(delay: Double = 0.25) {
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.highlightNow()
        }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func highlightNow() {
        guard let tv = textView, tv.markedTextRange == nil else { return }
        let sel = tv.selectedRange
        Highlighter.highlight(tv.textStorage, language: language)
        tv.typingAttributes = [.font: Highlighter.font, .foregroundColor: Highlighter.text]
        tv.selectedRange = sel
    }

    /// Replaces a range through UITextInput so it is undoable.
    private func replace(_ range: NSRange, with s: String) {
        guard let tv = textView,
              let start = tv.position(from: tv.beginningOfDocument, offset: range.location),
              let end = tv.position(from: start, offset: range.length),
              let tr = tv.textRange(from: start, to: end) else { return }
        tv.replace(tr, withText: s)
        tv.selectedRange = NSRange(location: range.location, length: (s as NSString).length)
        tv.scrollRangeToVisible(tv.selectedRange)
    }

    func replaceSelection(_ s: String) {
        guard let tv = textView else { return }
        replace(tv.selectedRange, with: s)
    }

    func replaceAll(_ s: String) {
        guard let tv = textView else { return }
        replace(NSRange(location: 0, length: ((tv.text ?? "") as NSString).length), with: s)
        tv.selectedRange = NSRange(location: 0, length: 0)
        tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    func insert(_ s: String) {
        textView?.insertText(s)
    }

    @discardableResult
    func find(_ q: String, forward: Bool = true, caseSensitive: Bool = false, regex: Bool = false) -> Bool {
        guard let tv = textView, !q.isEmpty else { return false }
        let ns = (tv.text ?? "") as NSString
        let len = ns.length
        let sel = tv.selectedRange
        if regex {
            guard let re = try? NSRegularExpression(pattern: q, options: caseSensitive ? [] : [.caseInsensitive]) else { return false }
            let all = re.matches(in: tv.text, range: NSRange(location: 0, length: len)).map(\.range).filter { $0.length > 0 }
            guard !all.isEmpty else { return false }
            let pick: NSRange
            if forward { pick = all.first { $0.location > sel.location } ?? all[0] }
            else { pick = all.last { $0.location < sel.location } ?? all[all.count - 1] }
            select(pick)
            return true
        }
        var opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var r: NSRange
        if forward {
            let start = min(sel.location + sel.length, len)
            r = ns.range(of: q, options: opts, range: NSRange(location: start, length: len - start))
            if r.location == NSNotFound { r = ns.range(of: q, options: opts, range: NSRange(location: 0, length: len)) }
        } else {
            opts.insert(.backwards)
            r = ns.range(of: q, options: opts, range: NSRange(location: 0, length: sel.location))
            if r.location == NSNotFound { r = ns.range(of: q, options: opts, range: NSRange(location: 0, length: len)) }
        }
        guard r.location != NSNotFound else { return false }
        select(r)
        return true
    }

    func countMatches(_ q: String, caseSensitive: Bool, regex: Bool) -> Int {
        guard let tv = textView, !q.isEmpty else { return 0 }
        let pattern = regex ? q : NSRegularExpression.escapedPattern(for: q)
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else { return 0 }
        return re.numberOfMatches(in: tv.text, range: NSRange(location: 0, length: ((tv.text ?? "") as NSString).length))
    }

    private func select(_ r: NSRange) {
        guard let tv = textView else { return }
        tv.selectedRange = r
        tv.scrollRangeToVisible(r)
        refreshState()
        tv.gutter.setNeedsDisplay()
    }

    func replaceCurrent(find q: String, with rep: String, caseSensitive: Bool, regex: Bool) {
        guard let tv = textView else { return }
        let sel = tv.selectedRange
        let current = ((tv.text ?? "") as NSString).substring(with: sel)
        let matches: Bool
        if regex {
            matches = (try? NSRegularExpression(pattern: "^(?:" + q + ")$", options: caseSensitive ? [] : [.caseInsensitive]))
                .map { $0.firstMatch(in: current, range: NSRange(location: 0, length: (current as NSString).length)) != nil } ?? false
        } else {
            matches = caseSensitive ? current == q : current.lowercased() == q.lowercased()
        }
        if sel.length > 0 && matches {
            var out = rep
            if regex, let re = try? NSRegularExpression(pattern: q, options: caseSensitive ? [] : [.caseInsensitive]) {
                out = re.stringByReplacingMatches(in: current, range: NSRange(location: 0, length: (current as NSString).length), withTemplate: rep)
            }
            replace(sel, with: out)
        }
        find(q, forward: true, caseSensitive: caseSensitive, regex: regex)
    }

    @discardableResult
    func replaceAllMatches(find q: String, with rep: String, caseSensitive: Bool, regex: Bool) -> Int {
        guard let tv = textView, !q.isEmpty else { return 0 }
        let pattern = regex ? q : NSRegularExpression.escapedPattern(for: q)
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else { return 0 }
        let full = NSRange(location: 0, length: ((tv.text ?? "") as NSString).length)
        let n = re.numberOfMatches(in: tv.text, range: full)
        guard n > 0 else { return 0 }
        let template = regex ? rep : NSRegularExpression.escapedTemplate(for: rep)
        let out = re.stringByReplacingMatches(in: tv.text, range: full, withTemplate: template)
        replace(full, with: out)
        tv.selectedRange = NSRange(location: 0, length: 0)
        return n
    }

    func goTo(line: Int) {
        guard let tv = textView else { return }
        let l = max(1, min(line, tv.lineStarts.count))
        let start = tv.lineStarts[l - 1]
        let ns = (tv.text ?? "") as NSString
        let end = l < tv.lineStarts.count ? tv.lineStarts[l] - 1 : ns.length
        select(NSRange(location: start, length: max(0, end - start)))
        tv.becomeFirstResponder()
    }

    func undo() { textView?.undoManager?.undo(); refreshState() }
    func redo() { textView?.undoManager?.redo(); refreshState() }

    func setWrap(_ wrap: Bool) {
        guard let tv = textView else { return }
        tv.textContainer.widthTracksTextView = wrap
        if !wrap {
            tv.textContainer.size = CGSize(width: 20_000, height: CGFloat.greatestFiniteMagnitude)
        } else {
            tv.textContainer.size = CGSize(width: tv.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        }
        tv.layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: ((tv.text ?? "") as NSString).length), actualCharacterRange: nil)
        tv.setNeedsLayout()
        tv.gutter.setNeedsDisplay()
    }
}

struct CodeEditorView: UIViewRepresentable {
    @ObservedObject var controller: EditorController
    let initialText: String
    let language: CodeLanguage
    var editable: Bool = true
    var wrap: Bool = true
    var lineNumbers: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> CodeTextView {
        let tv = CodeTextView()
        tv.delegate = context.coordinator
        tv.text = initialText
        tv.isEditable = editable
        tv.showLineNumbers = lineNumbers
        controller.textView = tv
        controller.language = language
        tv.recomputeLines()
        controller.highlightNow()
        tv.undoManager?.removeAllActions()
        controller.refreshState()
        DispatchQueue.main.async { controller.setWrap(wrap) }
        return tv
    }

    func updateUIView(_ tv: CodeTextView, context: Context) {
        if tv.isEditable != editable { tv.isEditable = editable }
        if tv.showLineNumbers != lineNumbers { tv.showLineNumbers = lineNumbers }
        if tv.textContainer.widthTracksTextView != wrap { controller.setWrap(wrap) }
        if controller.language != language {
            controller.language = language
            controller.highlightNow()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let controller: EditorController
        init(controller: EditorController) { self.controller = controller }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? CodeTextView)?.recomputeLines()
            controller.dirty = true
            controller.scheduleHighlight()
            controller.refreshState()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            controller.refreshState()
            (textView as? CodeTextView)?.gutter.setNeedsDisplay()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? CodeTextView)?.setNeedsLayout()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Auto-indent on newline.
            guard text == "\n", let tv = textView as? CodeTextView else { return true }
            let ns = (tv.text ?? "") as NSString
            let lineIdx = tv.line(at: range.location) - 1
            let start = tv.lineStarts[lineIdx]
            let line = ns.substring(with: NSRange(location: start, length: max(0, range.location - start)))
            var indent = String(line.prefix { $0 == " " || $0 == "\t" })
            if let last = line.trimmingCharacters(in: .whitespaces).last, "{[(:".contains(last) { indent += "    " }
            tv.insertText("\n" + indent)
            return false
        }
    }
}
