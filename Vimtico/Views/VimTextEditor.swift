import SwiftUI
import AppKit
import Combine

struct VimTextEditor: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var vimEngine: VimEngine
    @Binding var vimModeEnabled: Bool
    @Binding var fontSize: CGFloat
    let theme: Theme
    
    // Cursor tracking
    @Binding var cursorPosition: Int
    @Binding var cursorRect: CGRect
    
    // Autocomplete support
    @Binding var showingAutocomplete: Bool
    @Binding var cursorPositionAfterCompletion: Int?
    var onAutocompleteAccept: (() -> Void)?
    var onAutocompleteUp: (() -> Void)?
    var onAutocompleteDown: (() -> Void)?
    var onAutocompleteDismiss: (() -> Void)?
    var onTab: (() -> Void)?
    
    private static let gutterWidth: CGFloat = 52
    
    init(text: Binding<String>,
         vimEngine: VimEngine,
         vimModeEnabled: Binding<Bool>,
         fontSize: Binding<CGFloat>,
         theme: Theme,
         cursorPosition: Binding<Int> = .constant(0),
         cursorRect: Binding<CGRect> = .constant(.zero),
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
        self._cursorPosition = cursorPosition
        self._cursorRect = cursorRect
        self._showingAutocomplete = showingAutocomplete
        self._cursorPositionAfterCompletion = cursorPositionAfterCompletion
        self.onAutocompleteAccept = onAutocompleteAccept
        self.onAutocompleteUp = onAutocompleteUp
        self.onAutocompleteDown = onAutocompleteDown
        self.onAutocompleteDismiss = onAutocompleteDismiss
        self.onTab = onTab
    }
    
    func makeNSView(context: Context) -> EditorContainerView {
        // Container view holds gutter + scroll view side by side
        let container = EditorContainerView()
        container.autoresizesSubviews = true
        
        // --- Scroll View (right side) ---
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        // Frame will be set in layout, start with placeholder
        scrollView.frame = NSRect(x: Self.gutterWidth, y: 0,
                                  width: max(container.bounds.width - Self.gutterWidth, 200),
                                  height: max(container.bounds.height, 200))
        
        // --- Text View ---
        let textView = VimEnabledTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize + 4, weight: .regular)
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
        
        // Zero vertical inset so text starts at top
        textView.textContainerInset = NSSize(width: 4, height: 0)
        
        // Ensure no paragraph spacing before first line
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacingBefore = 0
        paragraphStyle.paragraphSpacing = 0
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes[.paragraphStyle] = paragraphStyle
        
        scrollView.documentView = textView
        
        // Set initial frame so text container has non-zero width for layout
        let initialWidth: CGFloat = max(scrollView.contentSize.width, 400)
        textView.frame = NSRect(x: 0, y: 0, width: initialWidth, height: max(scrollView.contentSize.height, 200))
        textView.textContainer?.containerSize = NSSize(width: max(initialWidth - 8, 100), height: CGFloat.greatestFiniteMagnitude)
        
        // --- Gutter View (left side) ---
        let gutter = LineNumberGutterView()
        gutter.textView = textView
        gutter.theme = theme
        gutter.frame = NSRect(x: 0, y: 0, width: Self.gutterWidth, height: max(container.bounds.height, 200))
        gutter.autoresizingMask = [.height]
        
        container.addSubview(gutter)
        container.addSubview(scrollView)
        
        // Store references in the container for easy lookup
        container.scrollView = scrollView
        container.gutterView = gutter
        
        // Observe scroll changes to refresh line numbers
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { _ in
            gutter.needsDisplay = true
        }
        
        applyTheme(to: textView)
        
        return container
    }
    
    func updateNSView(_ container: EditorContainerView, context: Context) {
        guard let scrollView = container.scrollView,
              let textView = scrollView.documentView as? VimEnabledTextView else { return }
        let gutter = container.gutterView
        
        // Update gutter and scroll view frames to match container size
        let containerBounds = container.bounds
        if containerBounds.width > 0 {
            gutter?.frame = NSRect(x: 0, y: 0, width: Self.gutterWidth, height: containerBounds.height)
            scrollView.frame = NSRect(x: Self.gutterWidth, y: 0,
                                      width: containerBounds.width - Self.gutterWidth,
                                      height: containerBounds.height)
        }
        
        if textView.string != text {
            let prevRange = textView.selectedRange()
            textView.string = text
            
            // If we have a cursor position from autocomplete, apply it
            if let cursorPos = cursorPositionAfterCompletion {
                let safePos = min(cursorPos, textView.string.count)
                textView.setSelectedRange(NSRange(location: safePos, length: 0))
                textView.scrollRangeToVisible(NSRange(location: safePos, length: 0))
                DispatchQueue.main.async {
                    self.cursorPositionAfterCompletion = nil
                }
            } else {
                // Preserve cursor position if possible
                let safePos = min(prevRange.location, textView.string.count)
                textView.setSelectedRange(NSRange(location: safePos, length: 0))
            }
        }
        
        // Update font size if changed
        let newFont = NSFont.monospacedSystemFont(ofSize: fontSize + 4, weight: .regular)
        if textView.font != newFont {
            textView.font = newFont
        }
        
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
        
        // Update gutter theme for line numbers
        gutter?.theme = theme
        gutter?.needsDisplay = true
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
        guard fullRange.length > 0 else { return }
        
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
            guard let textView = notification.object as? VimEnabledTextView else { return }
            parent.text = textView.string
            updateCursorInfo(textView)
            // Ensure scroll follows cursor after typing
            textView.scrollRangeToVisible(textView.selectedRange())
            // Refresh line numbers
            if let container = textView.enclosingScrollView?.superview as? EditorContainerView {
                container.gutterView?.needsDisplay = true
            }
        }
        
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? VimEnabledTextView else { return }
            updateCursorInfo(textView)
            // Scroll to keep cursor visible
            textView.scrollRangeToVisible(textView.selectedRange())
            // Refresh line numbers on selection change
            if let container = textView.enclosingScrollView?.superview as? EditorContainerView {
                container.gutterView?.needsDisplay = true
            }
        }
        
        private func updateCursorInfo(_ textView: VimEnabledTextView) {
            let pos = textView.selectedRange().location
            parent.cursorPosition = pos
            
            // Compute cursor rect in the text view's coordinate space,
            // then convert to the container view coordinate space.
            guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
            let nsString = textView.string as NSString
            
            var rect: NSRect
            if pos < nsString.length {
                let glyphIndex = lm.glyphIndexForCharacter(at: pos)
                let glyphRange = NSRange(location: glyphIndex, length: 1)
                rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            } else if nsString.length > 0 {
                let lastIdx = lm.glyphIndexForCharacter(at: nsString.length - 1)
                let glyphRange = NSRange(location: lastIdx, length: 1)
                let lastRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                rect = NSRect(
                    x: lastRect.maxX,
                    y: lastRect.origin.y,
                    width: 1,
                    height: lastRect.height
                )
            } else {
                rect = NSRect(x: 0, y: 0, width: 1, height: (textView.font?.pointSize ?? 14) * 1.2)
            }
            
            // Offset by textContainerOrigin
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            
            // Convert to position relative to the visible editor area.
            // Both textView and clipView are flipped (y=0 at top), so we can
            // compute directly: subtract scroll offset, then add gutter width for X.
            if let scrollView = textView.enclosingScrollView {
                let scrollOffset = scrollView.contentView.bounds.origin
                let gutterWidth = scrollView.frame.origin.x
                let visibleX = rect.origin.x - scrollOffset.x + gutterWidth
                let visibleY = rect.origin.y - scrollOffset.y
                parent.cursorRect = CGRect(x: visibleX, y: visibleY, width: rect.width, height: rect.height)
            }
        }
    }
}

// MARK: - Editor Container View (holds gutter + scroll view side by side)

class EditorContainerView: NSView {
    var scrollView: NSScrollView?
    var gutterView: LineNumberGutterView?
    
    override var isFlipped: Bool { true }
}

// MARK: - Line Number Gutter View (sibling of scroll view in container)

class LineNumberGutterView: NSView {
    weak var textView: VimEnabledTextView?
    var theme: Theme?
    
    override var isFlipped: Bool { true }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let textView = textView,
              let theme = theme,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        
        let gutterWidth = bounds.width
        let textString = textView.string as NSString
        
        // Fill gutter background
        NSColor(theme.editorBackgroundColor).setFill()
        dirtyRect.fill()
        
        // Subtle right border
        let borderColor = NSColor(theme.foregroundColor).withAlphaComponent(0.1)
        borderColor.setStroke()
        let borderPath = NSBezierPath()
        borderPath.move(to: NSPoint(x: gutterWidth - 0.5, y: dirtyRect.minY))
        borderPath.line(to: NSPoint(x: gutterWidth - 0.5, y: dirtyRect.maxY))
        borderPath.lineWidth = 1
        borderPath.stroke()
        
        let numberFont = NSFont.monospacedSystemFont(ofSize: textView.font?.pointSize ?? 14, weight: .regular)
        
        // The scroll offset: how far the text view has been scrolled
        let clipBounds = textView.enclosingScrollView?.contentView.bounds ?? .zero
        let scrollY = clipBounds.origin.y
        
        // For empty text, draw line 1
        if textString.length == 0 {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: NSColor(theme.foregroundColor).withAlphaComponent(0.9)
            ]
            let lineStr = "1" as NSString
            let strSize = lineStr.size(withAttributes: attrs)
            let xPos = gutterWidth - strSize.width - 8
            // textContainerOrigin.y offset minus scroll position
            let yPos = textView.textContainerOrigin.y - scrollY
            lineStr.draw(at: NSPoint(x: xPos, y: yPos), withAttributes: attrs)
            return
        }
        
        // Determine visible range in the text view
        let visibleRect = textView.visibleRect
        guard visibleRect.height > 0 else { return }
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
        
        // Determine cursor line for highlighting
        let cursorPos = textView.selectedRange().location
        var cursorLine = 1
        var idx = 0
        while idx < cursorPos && idx < textString.length {
            if textString.character(at: idx) == 10 { cursorLine += 1 }
            idx += 1
        }
        
        // Count lines up to visible range start
        var lineNumber = 1
        var scanIdx = 0
        while scanIdx < visibleCharRange.location && scanIdx < textString.length {
            if textString.character(at: scanIdx) == 10 { lineNumber += 1 }
            scanIdx += 1
        }
        
        // Draw line numbers for visible lines
        var charIndex = visibleCharRange.location
        while charIndex < NSMaxRange(visibleCharRange) {
            let lineRange = textString.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            // lineRect is in text container coords. Add textContainerOrigin.y, then subtract scroll offset
            // to get position in the gutter view's coordinate space.
            let yPos = lineRect.origin.y + textView.textContainerOrigin.y - scrollY
            
            let isCursorLine = lineNumber == cursorLine
            let attrs: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: isCursorLine
                    ? NSColor(theme.foregroundColor).withAlphaComponent(0.9)
                    : NSColor(theme.foregroundColor).withAlphaComponent(0.35)
            ]
            
            let lineStr = "\(lineNumber)" as NSString
            let strSize = lineStr.size(withAttributes: attrs)
            let xPos = gutterWidth - strSize.width - 8
            lineStr.draw(at: NSPoint(x: xPos, y: yPos), withAttributes: attrs)
            
            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }
    }
}

// MARK: - VimEnabledTextView

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
        // Ensure cursor is always visible after programmatic selection changes
        if !stillSelectingFlag {
            scrollRangeToVisible(charRange)
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
            // Event was handled by vim. Ensure scroll follows cursor.
            scrollRangeToVisible(selectedRange())
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
