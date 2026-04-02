import SwiftUI
import AppKit

struct VimTextEditor: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var vimEngine: VimEngine
    @Binding var vimModeEnabled: Bool
    let theme: Theme
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        
        let textView = VimEnabledTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
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
        
        scrollView.documentView = textView
        
        applyTheme(to: textView)
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? VimEnabledTextView else { return }
        
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
        
        textView.vimModeEnabledBinding = $vimModeEnabled
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
        
        // Reset to default color
        textStorage.addAttribute(.foregroundColor, value: NSColor(theme.editorForegroundColor), range: fullRange)
        
        let text = textStorage.string
        
        // SQL Keywords
        let keywords = [
            "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN",
            "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "ON",
            "GROUP", "BY", "HAVING", "ORDER", "ASC", "DESC", "LIMIT", "OFFSET",
            "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
            "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CHECK", "DEFAULT",
            "NULL", "NOT", "TRUE", "FALSE", "AS", "DISTINCT", "ALL", "UNION", "EXCEPT", "INTERSECT",
            "CASE", "WHEN", "THEN", "ELSE", "END", "CAST", "COALESCE", "NULLIF",
            "EXISTS", "ANY", "SOME", "WITH", "RECURSIVE", "RETURNING"
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
    
    override func keyDown(with event: NSEvent) {
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
