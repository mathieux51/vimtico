import SwiftUI
import AppKit
import Combine

struct VimTextEditor: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var vimEngine: VimEngine
    @Binding var vimModeEnabled: Bool
    @Binding var fontSize: CGFloat
    let theme: Theme
    
    // Autocomplete support
    @Binding var showingAutocomplete: Bool
    @Binding var cursorPositionAfterCompletion: Int?
    var onAutocompleteAccept: (() -> Void)?
    var onAutocompleteUp: (() -> Void)?
    var onAutocompleteDown: (() -> Void)?
    var onAutocompleteDismiss: (() -> Void)?
    var onTab: (() -> Void)?
    
    init(text: Binding<String>,
         vimEngine: VimEngine,
         vimModeEnabled: Binding<Bool>,
         fontSize: Binding<CGFloat>,
         theme: Theme,
         showingAutocomplete: Binding<Bool> = .constant(false),
         cursorPositionAfterCompletion: Binding<Int?> = .constant(nil),
         onAutocompleteAccept: (() -> Void)? = nil,
         onAutocompleteUp: (() -> Void)? = nil,
         onAutocompleteDown: (() -> Void)? = nil,
         onAutocompleteDismiss: (() -> Void)? = nil,
         onTab: (() -> Void)? = nil) {
        self._text = text
        self.vimEngine = vimEngine
        self._vimModeEnabled = vimModeEnabled
        self._fontSize = fontSize
        self.theme = theme
        self._showingAutocomplete = showingAutocomplete
        self._cursorPositionAfterCompletion = cursorPositionAfterCompletion
        self.onAutocompleteAccept = onAutocompleteAccept
        self.onAutocompleteUp = onAutocompleteUp
        self.onAutocompleteDown = onAutocompleteDown
        self.onAutocompleteDismiss = onAutocompleteDismiss
        self.onTab = onTab
    }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        
        let textView = VimEnabledTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize + 4, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        
        // Store references for vim mode
        textView.vimEngine = vimEngine
        textView.vimModeEnabledBinding = $vimModeEnabled
        
        // Store autocomplete callbacks
        textView.autocompleteCallbacks = VimEnabledTextView.AutocompleteCallbacks(
            onAccept: onAutocompleteAccept,
            onUp: onAutocompleteUp,
            onDown: onAutocompleteDown,
            onDismiss: onAutocompleteDismiss,
            onTab: onTab
        )
        
        scrollView.documentView = textView
        
        applyTheme(to: textView)
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? VimEnabledTextView else { return }
        
        if textView.string != text {
            textView.string = text
            
            // If we have a cursor position from autocomplete, apply it
            if let cursorPos = cursorPositionAfterCompletion {
                let safePos = min(cursorPos, textView.string.count)
                textView.setSelectedRange(NSRange(location: safePos, length: 0))
                DispatchQueue.main.async {
                    self.cursorPositionAfterCompletion = nil
                }
            }
        }
        
        // Update font size if changed
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize + 4, weight: .regular)
        
        textView.vimModeEnabledBinding = $vimModeEnabled
        textView.isShowingAutocomplete = showingAutocomplete
        textView.autocompleteCallbacks = VimEnabledTextView.AutocompleteCallbacks(
            onAccept: onAutocompleteAccept,
            onUp: onAutocompleteUp,
            onDown: onAutocompleteDown,
            onDismiss: onAutocompleteDismiss,
            onTab: onTab
        )
        applyTheme(to: textView)
        applySyntaxHighlighting(to: textView)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    private func applyTheme(to textView: NSTextView) {
        textView.backgroundColor = NSColor(theme.editorBackgroundColor)
        textView.textColor = NSColor(theme.editorForegroundColor)
        textView.insertionPointColor = NSColor(theme.editorCursorColor)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(theme.editorSelectionColor)
        ]
    }
    
    private func applySyntaxHighlighting(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        
        let fullRange = NSRange(location: 0, length: textStorage.length)
        
        // Reset to default color and font
        textStorage.addAttribute(.foregroundColor, value: NSColor(theme.editorForegroundColor), range: fullRange)
        textStorage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: fontSize + 4, weight: .regular), range: fullRange)
        
        let text = textStorage.string
        
        // SQL Keywords
        let keywords = [
            "select", "from", "where", "and", "or", "not", "in", "like", "between",
            "join", "left", "right", "inner", "outer", "full", "cross", "on",
            "group", "by", "having", "order", "asc", "desc", "limit", "offset",
            "insert", "into", "values", "update", "set", "delete",
            "create", "alter", "drop", "table", "index", "view", "database", "schema",
            "primary", "key", "foreign", "references", "unique", "check", "default",
            "null", "not", "true", "false", "as", "distinct", "all", "union", "except", "intersect",
            "case", "when", "then", "else", "end", "cast", "coalesce", "nullif",
            "exists", "any", "some", "with", "recursive", "returning"
        ]
        
        for keyword in keywords {
            let pattern = "\\b\(keyword)\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let matches = regex.matches(in: text, options: [], range: fullRange)
                for match in matches {
                    textStorage.addAttribute(.foregroundColor, value: NSColor(theme.keywordColor), range: match.range)
                }
            }
        }
        
        // Strings (single quotes)
        if let stringRegex = try? NSRegularExpression(pattern: "'[^']*'", options: []) {
            let matches = stringRegex.matches(in: text, options: [], range: fullRange)
            for match in matches {
                textStorage.addAttribute(.foregroundColor, value: NSColor(theme.stringColor), range: match.range)
            }
        }
        
        // Numbers
        if let numberRegex = try? NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?\\b", options: []) {
            let matches = numberRegex.matches(in: text, options: [], range: fullRange)
            for match in matches {
                textStorage.addAttribute(.foregroundColor, value: NSColor(theme.numberColor), range: match.range)
            }
        }
        
        // Comments (-- style)
        if let commentRegex = try? NSRegularExpression(pattern: "--.*$", options: .anchorsMatchLines) {
            let matches = commentRegex.matches(in: text, options: [], range: fullRange)
            for match in matches {
                textStorage.addAttribute(.foregroundColor, value: NSColor(theme.commentColor), range: match.range)
            }
        }
        
        // Block comments /* */
        if let blockCommentRegex = try? NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/", options: []) {
            let matches = blockCommentRegex.matches(in: text, options: [], range: fullRange)
            for match in matches {
                textStorage.addAttribute(.foregroundColor, value: NSColor(theme.commentColor), range: match.range)
            }
        }
        
        // Functions (word followed by parenthesis)
        if let funcRegex = try? NSRegularExpression(pattern: "\\b([a-zA-Z_][a-zA-Z0-9_]*)\\s*\\(", options: []) {
            let matches = funcRegex.matches(in: text, options: [], range: fullRange)
            for match in matches {
                if match.numberOfRanges > 1 {
                    textStorage.addAttribute(.foregroundColor, value: NSColor(theme.functionColor), range: match.range(at: 1))
                }
            }
        }
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: VimTextEditor
        
        init(_ parent: VimTextEditor) {
            self.parent = parent
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

class VimEnabledTextView: NSTextView {
    var vimEngine: VimEngine?
    var vimModeEnabledBinding: Binding<Bool>?
    var isShowingAutocomplete: Bool = false
    
    struct AutocompleteCallbacks {
        var onAccept: (() -> Void)?
        var onUp: (() -> Void)?
        var onDown: (() -> Void)?
        var onDismiss: (() -> Void)?
        var onTab: (() -> Void)?
    }
    
    var autocompleteCallbacks = AutocompleteCallbacks()
    
    private var modeObservation: NSKeyValueObservation?
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Observe vim mode changes to update cursor style
        if let engine = vimEngine {
            // Use Combine to observe mode changes
            let cancellable = engine.$mode.sink { [weak self] (_: VimModeState) in
                DispatchQueue.main.async {
                    self?.needsDisplay = true
                }
            }
            // Store the cancellable (using objc_setAssociatedObject to keep it alive)
            objc_setAssociatedObject(self, "vimModeCancellable", cancellable, .OBJC_ASSOCIATION_RETAIN)
        }
    }
    
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            NotificationCenter.default.post(name: .editorBecameFirstResponder, object: nil)
        }
        return result
    }
    
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        let isNormalOrVisual: Bool = {
            guard let binding = vimModeEnabledBinding, binding.wrappedValue,
                  let engine = vimEngine else { return false }
            return engine.mode == .normal || engine.mode == .visual || engine.mode == .visualLine
        }()
        
        if isNormalOrVisual {
            // Suppress the system line cursor; we draw our own block in draw(_:)
            return
        } else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBlockCursorIfNeeded()
    }
    
    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
        if let engine = vimEngine, vimModeEnabledBinding?.wrappedValue == true,
           engine.mode == .normal {
            needsDisplay = true
        }
    }
    
    /// Draws a full-width block cursor at the current insertion point in normal mode.
    private func drawBlockCursorIfNeeded() {
        guard let binding = vimModeEnabledBinding, binding.wrappedValue,
              let engine = vimEngine,
              engine.mode == .normal else { return }
        
        let cursorPos = selectedRange().location
        let nsString = string as NSString
        guard let lm = layoutManager, let tc = textContainer else { return }
        
        let charWidth = NSString("M").size(withAttributes: [
            .font: self.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ]).width
        
        var rect: NSRect
        if cursorPos < nsString.length {
            let glyphIndex = lm.glyphIndexForCharacter(at: cursorPos)
            let glyphRange = NSRange(location: glyphIndex, length: 1)
            rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            // Ensure minimum width (e.g. newline chars have zero width)
            if rect.size.width < 2 {
                rect.size.width = charWidth
            }
        } else {
            // Cursor at end of text
            if nsString.length > 0 {
                let lastIndex = lm.glyphIndexForCharacter(at: nsString.length - 1)
                let glyphRange = NSRange(location: lastIndex, length: 1)
                let lastRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                rect = NSRect(
                    x: lastRect.origin.x + lastRect.size.width + textContainerOrigin.x,
                    y: lastRect.origin.y + textContainerOrigin.y,
                    width: charWidth,
                    height: lastRect.size.height
                )
            } else {
                let lineHeight = (self.font?.pointSize ?? 14) * 1.2
                rect = NSRect(
                    x: textContainerOrigin.x,
                    y: textContainerOrigin.y,
                    width: charWidth,
                    height: lineHeight
                )
            }
        }
        
        insertionPointColor.withAlphaComponent(0.5).set()
        rect.fill()
    }
    
    // Need to override to return a wider rect so the block cursor area gets properly invalidated
    override var rangeForUserCompletion: NSRange {
        return super.rangeForUserCompletion
    }
    
    override func keyDown(with event: NSEvent) {
        // Tab always triggers autocomplete regardless of popup state
        if event.keyCode == 48 && !event.modifierFlags.contains(.shift) {
            autocompleteCallbacks.onTab?()
            return
        }
        
        // Handle autocomplete keys when popup is showing
        if isShowingAutocomplete {
            switch event.keyCode {
            case 36: // Return/Enter - accept selected suggestion
                autocompleteCallbacks.onAccept?()
                return
            case 126: // Up arrow - move selection up
                autocompleteCallbacks.onUp?()
                return
            case 125: // Down arrow - move selection down
                autocompleteCallbacks.onDown?()
                return
            case 53: // Escape - dismiss autocomplete, then fall through to vim engine
                autocompleteCallbacks.onDismiss?()
                break
            default:
                // Dismiss autocomplete for other keys, then process normally
                autocompleteCallbacks.onDismiss?()
            }
        } else {
            // Escape dismisses any leftover state
            if event.keyCode == 53 {
                autocompleteCallbacks.onDismiss?()
            }
        }
        
        // Check if vim mode is enabled
        guard let binding = vimModeEnabledBinding, binding.wrappedValue,
              let engine = vimEngine else {
            super.keyDown(with: event)
            return
        }
        
        // Let vim engine handle the key event
        if engine.handleKeyEvent(event, in: self) {
            // Event was handled by vim
            return
        }
        
        // Pass through to normal handling if vim didn't handle it
        super.keyDown(with: event)
    }
    
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Always let command key shortcuts through
        if event.modifierFlags.contains(.command) {
            return super.performKeyEquivalent(with: event)
        }
        return super.performKeyEquivalent(with: event)
    }
}
