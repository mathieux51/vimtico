import Foundation
import AppKit

enum VimModeState: String {
    case normal = "NORMAL"
    case insert = "INSERT"
    case visual = "VISUAL"
    case visualLine = "V-LINE"
    case command = "COMMAND"
}

class VimEngine: ObservableObject {
    @Published var mode: VimModeState = .normal
    @Published var commandBuffer: String = ""
    @Published var statusMessage: String = ""
    
    // Pending states for multi-key sequences
    private var pendingOperator: String? // "d", "y", "c", "g"
    private var pendingMotion: String?   // "f", "F", "t", "T", "r"
    private var count: Int = 1
    private var countBuffer: String = ""
    
    // Last f/F/t/T search for ; and , repeat
    private var lastFindChar: Character?
    private var lastFindDirection: String? // "f", "F", "t", "T"
    
    // Dot repeat: stores the last edit command description
    private var lastEditCommand: EditCommand?
    private var isReplaying: Bool = false
    
    // Yank register (simple single register)
    private var yankRegister: String = ""
    private var yankIsLinewise: Bool = false
    
    /// Describes a repeatable edit command for dot (.) replay.
    private struct EditCommand {
        let type: EditType
        let count: Int
        let char: Character?   // for r{char}
        let motion: String?    // for operator+motion combos like "dw"
        let motionChar: Character? // for df{char}, ct{char}, etc.
    }
    
    private enum EditType: String {
        case deleteChar         // x
        case deleteCharBefore   // X
        case substitute         // s
        case substituteLine     // S / cc
        case changeToEnd        // C
        case deleteToEnd        // D
        case joinLine           // J
        case replaceChar        // r{char}
        case toggleCase         // ~
        case deleteLine         // dd
        case operatorMotion     // d/c/y + motion
        case insertBelow        // o
        case insertAbove        // O
        case paste              // p
    }
    
    func handleKeyEvent(_ event: NSEvent, in textView: NSTextView) -> Bool {
        guard event.type == .keyDown else { return false }
        
        let key = event.charactersIgnoringModifiers ?? ""
        let modifiers = event.modifierFlags
        
        switch mode {
        case .normal:
            return handleNormalMode(key: key, modifiers: modifiers, textView: textView)
        case .insert:
            return handleInsertMode(key: key, modifiers: modifiers, textView: textView)
        case .visual, .visualLine:
            return handleVisualMode(key: key, modifiers: modifiers, textView: textView)
        case .command:
            return handleCommandMode(key: key, modifiers: modifiers, textView: textView)
        }
    }
    
    // MARK: - Normal Mode
    
    private func handleNormalMode(key: String, modifiers: NSEvent.ModifierFlags, textView: NSTextView) -> Bool {
        // Handle pending motion that needs a char argument (f/F/t/T/r)
        if let pending = pendingMotion {
            guard key.count == 1, let char = key.first else {
                pendingMotion = nil
                pendingOperator = nil
                return true
            }
            
            let savedCount = count
            defer {
                pendingMotion = nil
                countBuffer = ""
                count = 1
            }
            
            // Text object: "i_obj" or "a_obj" + object key (w, ", ', (, {, [)
            if pending == "i_obj" || pending == "a_obj" {
                let outer = pending == "a_obj"
                if let op = pendingOperator {
                    if let range = computeTextObjectRange(key: char, outer: outer, textView: textView) {
                        applyOperator(op, range: range, textView: textView)
                        if !isReplaying {
                            let motionStr = op + (outer ? "a" : "i") + String(char)
                            lastEditCommand = EditCommand(type: .operatorMotion, count: savedCount, char: nil, motion: motionStr, motionChar: nil)
                        }
                    }
                    pendingOperator = nil
                }
                return true
            }
            
            if pending == "r" {
                // Replace char under cursor
                replaceCharUnderCursor(with: char, count: savedCount, textView: textView)
                if !isReplaying {
                    lastEditCommand = EditCommand(type: .replaceChar, count: savedCount, char: char, motion: nil, motionChar: nil)
                }
                pendingOperator = nil
                return true
            }
            
            // f/F/t/T with optional pending operator
            lastFindChar = char
            lastFindDirection = pending
            
            if let op = pendingOperator {
                // operator + f/F/t/T + char
                let range = computeFindRange(direction: pending, char: char, count: savedCount, textView: textView)
                if let range = range {
                    applyOperator(op, range: range, textView: textView)
                    if !isReplaying {
                        lastEditCommand = EditCommand(type: .operatorMotion, count: savedCount, char: char, motion: op + pending, motionChar: char)
                    }
                }
                pendingOperator = nil
                return true
            }
            
            // Plain f/F/t/T movement
            for _ in 0..<savedCount {
                executeFindMotion(direction: pending, char: char, textView: textView)
            }
            return true
        }
        
        // Handle count prefix (digits)
        if let digit = Int(key), countBuffer.isEmpty ? digit > 0 : true {
            // Special case: "0" with no count buffer is "go to start of line"
            if digit == 0 && countBuffer.isEmpty {
                // Fall through to the switch below
            } else {
                countBuffer += key
                count = Int(countBuffer) ?? 1
                return true
            }
        }
        
        let savedCount = count
        defer {
            // Reset count after handling, unless we set a pending state
            if pendingOperator == nil && pendingMotion == nil {
                countBuffer = ""
                count = 1
            }
        }
        
        // Handle pending operator + motion key
        if let op = pendingOperator, op != "g" {
            // Operator is d, y, or c. Next key is a motion.
            pendingOperator = nil
            
            switch key {
            case "d" where op == "d":
                for _ in 0..<savedCount { deleteLine(textView: textView) }
                if !isReplaying { lastEditCommand = EditCommand(type: .deleteLine, count: savedCount, char: nil, motion: nil, motionChar: nil) }
                return true
            case "y" where op == "y":
                yankLine(count: savedCount, textView: textView)
                return true
            case "c" where op == "c":
                for _ in 0..<savedCount { changeLine(textView: textView) }
                if !isReplaying { lastEditCommand = EditCommand(type: .substituteLine, count: savedCount, char: nil, motion: nil, motionChar: nil) }
                return true
            case "w", "e", "b", "W", "E", "B", "$", "0", "^", "G", "g", "h", "l", "j", "k", "{", "}":
                if let range = computeMotionRange(motion: key, count: savedCount, textView: textView) {
                    applyOperator(op, range: range, textView: textView)
                    if !isReplaying {
                        lastEditCommand = EditCommand(type: .operatorMotion, count: savedCount, char: nil, motion: op + key, motionChar: nil)
                    }
                }
                return true
            case "f", "F", "t", "T":
                // operator + find motion, need one more char
                pendingOperator = op
                pendingMotion = key
                return true
            case "i":
                // Inner text objects (basic: iw, i", i', i(, i{, i[)
                // For now, just handle iw
                pendingOperator = op
                pendingMotion = nil
                // Wait for the next key after "i"
                // We handle this inline: store that we have op+"i" pending
                // Actually, let's handle text objects directly
                return handleTextObject(outer: false, operator: op, count: savedCount, textView: textView)
            case "a":
                // Around text objects
                return handleTextObject(outer: true, operator: op, count: savedCount, textView: textView)
            default:
                // Unknown motion, cancel operator
                statusMessage = ""
                return true
            }
        }
        
        // Handle "g" prefix sequences
        if pendingOperator == "g" {
            pendingOperator = nil
            switch key {
            case "g":
                if savedCount > 1 {
                    moveToLine(savedCount, textView: textView)
                } else {
                    moveToStart(textView: textView)
                }
                return true
            default:
                return false
            }
        }
        
        // Ctrl key combos
        if modifiers.contains(.control) {
            switch key {
            case "r":
                textView.undoManager?.redo()
                return true
            case "d":
                for _ in 0..<savedCount { halfPageDown(textView: textView) }
                return true
            case "u":
                for _ in 0..<savedCount { halfPageUp(textView: textView) }
                return true
            case "f":
                for _ in 0..<savedCount { fullPageDown(textView: textView) }
                return true
            case "b":
                for _ in 0..<savedCount { fullPageUp(textView: textView) }
                return true
            default:
                return false
            }
        }
        
        switch key {
        // Mode entry
        case "i":
            enterInsertMode()
            return true
        case "a":
            moveRight(textView: textView)
            enterInsertMode()
            return true
        case "A":
            moveToEndOfLine(textView: textView)
            enterInsertMode()
            return true
        case "I":
            moveToFirstNonBlank(textView: textView)
            enterInsertMode()
            return true
        case "o":
            insertLineBelow(textView: textView)
            enterInsertMode()
            if !isReplaying { lastEditCommand = EditCommand(type: .insertBelow, count: 1, char: nil, motion: nil, motionChar: nil) }
            return true
        case "O":
            insertLineAbove(textView: textView)
            enterInsertMode()
            if !isReplaying { lastEditCommand = EditCommand(type: .insertAbove, count: 1, char: nil, motion: nil, motionChar: nil) }
            return true
        case "v":
            enterVisualMode()
            return true
        case "V":
            enterVisualLineMode()
            return true
        case ":":
            enterCommandMode()
            return true
            
        // Basic movement
        case "h":
            for _ in 0..<savedCount { moveLeft(textView: textView) }
            return true
        case "j":
            for _ in 0..<savedCount { moveDown(textView: textView) }
            return true
        case "k":
            for _ in 0..<savedCount { moveUp(textView: textView) }
            return true
        case "l":
            for _ in 0..<savedCount { moveRight(textView: textView) }
            return true
            
        // Word movement
        case "w":
            for _ in 0..<savedCount { moveWordForward(textView: textView) }
            return true
        case "b":
            for _ in 0..<savedCount { moveWordBackward(textView: textView) }
            return true
        case "e":
            for _ in 0..<savedCount { moveToEndOfWord(textView: textView) }
            return true
        case "W":
            for _ in 0..<savedCount { moveWORDForward(textView: textView) }
            return true
        case "B":
            for _ in 0..<savedCount { moveWORDBackward(textView: textView) }
            return true
        case "E":
            for _ in 0..<savedCount { moveToEndOfWORD(textView: textView) }
            return true
            
        // Line movement
        case "0":
            moveToStartOfLine(textView: textView)
            return true
        case "$":
            moveToEndOfLine(textView: textView)
            return true
        case "^":
            moveToFirstNonBlank(textView: textView)
            return true
            
        // Document/line movement
        case "G":
            if !countBuffer.isEmpty {
                moveToLine(savedCount, textView: textView)
            } else {
                moveToEnd(textView: textView)
            }
            return true
        case "g":
            pendingOperator = "g"
            return true
        case "H":
            moveToScreenTop(textView: textView)
            return true
        case "M":
            moveToScreenMiddle(textView: textView)
            return true
        case "L":
            moveToScreenBottom(textView: textView)
            return true
            
        // Paragraph movement
        case "{":
            for _ in 0..<savedCount { moveParagraphBackward(textView: textView) }
            return true
        case "}":
            for _ in 0..<savedCount { moveParagraphForward(textView: textView) }
            return true
            
        // Find char on line
        case "f", "F", "t", "T":
            pendingMotion = key
            return true
        case ";":
            // Repeat last f/F/t/T
            if let dir = lastFindDirection, let ch = lastFindChar {
                for _ in 0..<savedCount { executeFindMotion(direction: dir, char: ch, textView: textView) }
            }
            return true
        case ",":
            // Reverse last f/F/t/T
            if let dir = lastFindDirection, let ch = lastFindChar {
                let reversed = reverseDirection(dir)
                for _ in 0..<savedCount { executeFindMotion(direction: reversed, char: ch, textView: textView) }
            }
            return true
            
        // Matching bracket
        case "%":
            jumpToMatchingBracket(textView: textView)
            return true
            
        // Operators
        case "d":
            pendingOperator = "d"
            return true
        case "c":
            pendingOperator = "c"
            return true
        case "y":
            pendingOperator = "y"
            return true
            
        // Single-key edits
        case "x":
            for _ in 0..<savedCount { deleteCharUnderCursor(textView: textView) }
            if !isReplaying { lastEditCommand = EditCommand(type: .deleteChar, count: savedCount, char: nil, motion: nil, motionChar: nil) }
            return true
        case "X":
            for _ in 0..<savedCount { deleteCharBeforeCursor(textView: textView) }
            if !isReplaying { lastEditCommand = EditCommand(type: .deleteCharBefore, count: savedCount, char: nil, motion: nil, motionChar: nil) }
            return true
        case "s":
            deleteCharUnderCursor(textView: textView)
            enterInsertMode()
            if !isReplaying { lastEditCommand = EditCommand(type: .substitute, count: savedCount, char: nil, motion: nil, motionChar: nil) }
            return true
        case "S":
            changeLine(textView: textView)
            if !isReplaying { lastEditCommand = EditCommand(type: .substituteLine, count: savedCount, char: nil, motion: nil, motionChar: nil) }
            return true
        case "C":
            deleteToEndOfLine(textView: textView)
            enterInsertMode()
            if !isReplaying { lastEditCommand = EditCommand(type: .changeToEnd, count: savedCount, char: nil, motion: nil, motionChar: nil) }
            return true
        case "D":
            deleteToEndOfLine(textView: textView)
            if !isReplaying { lastEditCommand = EditCommand(type: .deleteToEnd, count: savedCount, char: nil, motion: nil, motionChar: nil) }
            return true
        case "J":
            for _ in 0..<savedCount { joinLines(textView: textView) }
            if !isReplaying { lastEditCommand = EditCommand(type: .joinLine, count: savedCount, char: nil, motion: nil, motionChar: nil) }
            return true
        case "r":
            pendingMotion = "r"
            return true
        case "~":
            for _ in 0..<savedCount { toggleCaseUnderCursor(textView: textView) }
            if !isReplaying { lastEditCommand = EditCommand(type: .toggleCase, count: savedCount, char: nil, motion: nil, motionChar: nil) }
            return true
            
        // Paste
        case "p":
            pasteAfter(textView: textView)
            if !isReplaying { lastEditCommand = EditCommand(type: .paste, count: savedCount, char: nil, motion: nil, motionChar: nil) }
            return true
        case "P":
            pasteBefore(textView: textView)
            return true
            
        // Undo
        case "u":
            textView.undoManager?.undo()
            return true
            
        // Dot repeat
        case ".":
            replayLastEdit(count: savedCount, textView: textView)
            return true
            
        // Execute query / cancel
        case "\r":
            NotificationCenter.default.post(name: .executeQuery, object: nil)
            return true
        case "\u{1B}":
            mode = .normal
            pendingOperator = nil
            pendingMotion = nil
            NotificationCenter.default.post(name: .cancelQuery, object: nil)
            return true
            
        default:
            return false
        }
    }
    
    // MARK: - Insert Mode
    
    private func handleInsertMode(key: String, modifiers: NSEvent.ModifierFlags, textView: NSTextView) -> Bool {
        if key == "\u{1B}" { // Escape
            mode = .normal
            moveLeft(textView: textView)
            return true
        }
        return false
    }
    
    // MARK: - Visual Mode
    
    private func handleVisualMode(key: String, modifiers: NSEvent.ModifierFlags, textView: NSTextView) -> Bool {
        // Ctrl combos in visual mode
        if modifiers.contains(.control) {
            switch key {
            case "d":
                halfPageDown(textView: textView)
                return true
            case "u":
                halfPageUp(textView: textView)
                return true
            case "f":
                fullPageDown(textView: textView)
                return true
            case "b":
                fullPageUp(textView: textView)
                return true
            default:
                break
            }
        }
        
        switch key {
        case "\u{1B}":
            mode = .normal
            if let range = textView.selectedRanges.first?.rangeValue {
                textView.setSelectedRange(NSRange(location: range.location, length: 0))
            }
            return true
        case "h", "j", "k", "l", "w", "b", "e", "W", "B", "E",
             "0", "$", "^", "G", "g", "{", "}", "H", "M", "L", "%":
            return handleNormalMode(key: key, modifiers: modifiers, textView: textView)
        case "f", "F", "t", "T":
            pendingMotion = key
            return true
        case ";", ",":
            return handleNormalMode(key: key, modifiers: modifiers, textView: textView)
        case "d", "x":
            yankSelection(textView: textView)
            deleteSelection(textView: textView)
            mode = .normal
            return true
        case "c":
            yankSelection(textView: textView)
            deleteSelection(textView: textView)
            enterInsertMode()
            return true
        case "y":
            yankSelection(textView: textView)
            mode = .normal
            return true
        case "~":
            toggleCaseSelection(textView: textView)
            mode = .normal
            return true
        case "J":
            // Join selected lines
            joinLines(textView: textView)
            mode = .normal
            return true
        case "\r":
            let nsString = textView.string as NSString
            let selectedRange = textView.selectedRange()
            if selectedRange.length > 0 {
                let selectedText = nsString.substring(with: selectedRange)
                NotificationCenter.default.post(name: .executeSelectedQuery, object: selectedText)
            }
            mode = .normal
            return true
        default:
            return false
        }
    }
    
    // MARK: - Command Mode
    
    private func handleCommandMode(key: String, modifiers: NSEvent.ModifierFlags, textView: NSTextView) -> Bool {
        if key == "\u{1B}" {
            mode = .normal
            commandBuffer = ""
            return true
        }
        
        if key == "\r" {
            executeCommand(textView: textView)
            mode = .normal
            commandBuffer = ""
            return true
        }
        
        if key == "\u{7F}" {
            if !commandBuffer.isEmpty {
                commandBuffer.removeLast()
            }
            if commandBuffer.isEmpty {
                mode = .normal
            }
            return true
        }
        
        commandBuffer += key
        return true
    }
    
    // MARK: - Mode transitions
    
    private func enterInsertMode() {
        mode = .insert
    }
    
    private func enterVisualMode() {
        mode = .visual
    }
    
    private func enterVisualLineMode() {
        mode = .visualLine
    }
    
    private func enterCommandMode() {
        mode = .command
        commandBuffer = ""
    }
    
    // MARK: - Basic Movement
    
    private func moveLeft(textView: NSTextView) {
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        let newLocation = max(0, range.location - 1)
        textView.setSelectedRange(NSRange(location: newLocation, length: 0))
    }
    
    private func moveRight(textView: NSTextView) {
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        let text = textView.string as NSString
        let newLocation = min(text.length, range.location + 1)
        textView.setSelectedRange(NSRange(location: newLocation, length: 0))
    }
    
    private func moveUp(textView: NSTextView) {
        textView.moveUp(nil)
    }
    
    private func moveDown(textView: NSTextView) {
        textView.moveDown(nil)
    }
    
    // MARK: - Word Movement
    
    private func moveWordForward(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        var pos = range.location
        
        guard pos < text.length else { return }
        
        // Skip current word chars
        let startChar = text.character(at: pos)
        if isWordChar(startChar) {
            while pos < text.length && isWordChar(text.character(at: pos)) { pos += 1 }
        } else if !isWhitespace(startChar) {
            // Punctuation
            while pos < text.length && !isWordChar(text.character(at: pos)) && !isWhitespace(text.character(at: pos)) { pos += 1 }
        }
        // Skip whitespace
        while pos < text.length && isWhitespace(text.character(at: pos)) { pos += 1 }
        
        textView.setSelectedRange(NSRange(location: pos, length: 0))
    }
    
    private func moveWordBackward(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        var pos = range.location
        
        guard pos > 0 else { return }
        pos -= 1
        
        // Skip whitespace backwards
        while pos > 0 && isWhitespace(text.character(at: pos)) { pos -= 1 }
        
        // Skip word or punctuation chars backwards
        if pos >= 0 && pos < text.length {
            let ch = text.character(at: pos)
            if isWordChar(ch) {
                while pos > 0 && isWordChar(text.character(at: pos - 1)) { pos -= 1 }
            } else if !isWhitespace(ch) {
                while pos > 0 && !isWordChar(text.character(at: pos - 1)) && !isWhitespace(text.character(at: pos - 1)) { pos -= 1 }
            }
        }
        
        textView.setSelectedRange(NSRange(location: pos, length: 0))
    }
    
    private func moveToEndOfWord(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        var pos = range.location
        
        guard pos < text.length - 1 else { return }
        pos += 1
        
        // Skip whitespace
        while pos < text.length && isWhitespace(text.character(at: pos)) { pos += 1 }
        
        guard pos < text.length else {
            textView.setSelectedRange(NSRange(location: text.length - 1, length: 0))
            return
        }
        
        // Move to end of word
        let ch = text.character(at: pos)
        if isWordChar(ch) {
            while pos < text.length - 1 && isWordChar(text.character(at: pos + 1)) { pos += 1 }
        } else {
            while pos < text.length - 1 && !isWordChar(text.character(at: pos + 1)) && !isWhitespace(text.character(at: pos + 1)) { pos += 1 }
        }
        
        textView.setSelectedRange(NSRange(location: pos, length: 0))
    }
    
    // WORD movement (whitespace-delimited)
    
    private func moveWORDForward(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        var pos = range.location
        
        // Skip non-whitespace
        while pos < text.length && !isWhitespace(text.character(at: pos)) { pos += 1 }
        // Skip whitespace
        while pos < text.length && isWhitespace(text.character(at: pos)) { pos += 1 }
        
        textView.setSelectedRange(NSRange(location: pos, length: 0))
    }
    
    private func moveWORDBackward(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        var pos = range.location
        
        guard pos > 0 else { return }
        pos -= 1
        
        // Skip whitespace backwards
        while pos > 0 && isWhitespace(text.character(at: pos)) { pos -= 1 }
        // Skip non-whitespace backwards
        while pos > 0 && !isWhitespace(text.character(at: pos - 1)) { pos -= 1 }
        
        textView.setSelectedRange(NSRange(location: pos, length: 0))
    }
    
    private func moveToEndOfWORD(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        var pos = range.location
        
        guard pos < text.length - 1 else { return }
        pos += 1
        
        // Skip whitespace
        while pos < text.length && isWhitespace(text.character(at: pos)) { pos += 1 }
        // Move to end of WORD
        while pos < text.length - 1 && !isWhitespace(text.character(at: pos + 1)) { pos += 1 }
        
        textView.setSelectedRange(NSRange(location: min(pos, text.length - 1), length: 0))
    }
    
    // MARK: - Line Movement
    
    private func moveToStartOfLine(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
        textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
    }
    
    private func moveToEndOfLine(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
        var endPos = lineRange.location + lineRange.length
        // Don't include the newline
        if endPos > lineRange.location && endPos <= text.length && endPos > 0 {
            let charBefore = text.character(at: endPos - 1)
            if charBefore == 10 { // newline
                endPos -= 1
            }
        }
        // In normal mode, cursor should be on last char, not past it
        if mode == .normal && endPos > lineRange.location {
            endPos = max(lineRange.location, endPos - 1)
        }
        textView.setSelectedRange(NSRange(location: endPos, length: 0))
    }
    
    private func moveToFirstNonBlank(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
        
        var location = lineRange.location
        let lineEnd = lineRange.location + lineRange.length
        while location < lineEnd {
            let char = text.character(at: location)
            if char != 32 && char != 9 { break }
            location += 1
        }
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }
    
    // MARK: - Document Movement
    
    private func moveToStart(textView: NSTextView) {
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }
    
    private func moveToEnd(textView: NSTextView) {
        let text = textView.string as NSString
        let pos = max(0, text.length - 1)
        textView.setSelectedRange(NSRange(location: pos, length: 0))
    }
    
    private func moveToLine(_ line: Int, textView: NSTextView) {
        let text = textView.string as NSString
        var currentLine = 1
        var location = 0
        
        while currentLine < line && location < text.length {
            if text.character(at: location) == 10 {
                currentLine += 1
            }
            location += 1
        }
        
        textView.setSelectedRange(NSRange(location: min(location, text.length), length: 0))
    }
    
    // MARK: - Screen Movement (H/M/L)
    
    private func moveToScreenTop(textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let visibleRect = textView.visibleRect
        let topPoint = NSPoint(x: 0, y: visibleRect.origin.y + 4)
        let glyphIndex = layoutManager.glyphIndex(for: topPoint, in: container)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        textView.setSelectedRange(NSRange(location: charIndex, length: 0))
    }
    
    private func moveToScreenMiddle(textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let visibleRect = textView.visibleRect
        let midPoint = NSPoint(x: 0, y: visibleRect.midY)
        let glyphIndex = layoutManager.glyphIndex(for: midPoint, in: container)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        textView.setSelectedRange(NSRange(location: charIndex, length: 0))
    }
    
    private func moveToScreenBottom(textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let visibleRect = textView.visibleRect
        let bottomPoint = NSPoint(x: 0, y: visibleRect.maxY - 4)
        let glyphIndex = layoutManager.glyphIndex(for: bottomPoint, in: container)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        textView.setSelectedRange(NSRange(location: charIndex, length: 0))
    }
    
    // MARK: - Page Movement (Ctrl-d/u/f/b)
    
    private func halfPageDown(textView: NSTextView) {
        let visibleRect = textView.visibleRect
        let halfHeight = visibleRect.height / 2
        let newOrigin = NSPoint(x: visibleRect.origin.x, y: visibleRect.origin.y + halfHeight)
        textView.scroll(newOrigin)
        // Move cursor roughly half-page down too
        let lineCount = Int(halfHeight / (textView.font?.boundingRectForFont.height ?? 14))
        for _ in 0..<max(1, lineCount) { textView.moveDown(nil) }
    }
    
    private func halfPageUp(textView: NSTextView) {
        let visibleRect = textView.visibleRect
        let halfHeight = visibleRect.height / 2
        let newOrigin = NSPoint(x: visibleRect.origin.x, y: max(0, visibleRect.origin.y - halfHeight))
        textView.scroll(newOrigin)
        let lineCount = Int(halfHeight / (textView.font?.boundingRectForFont.height ?? 14))
        for _ in 0..<max(1, lineCount) { textView.moveUp(nil) }
    }
    
    private func fullPageDown(textView: NSTextView) {
        let visibleRect = textView.visibleRect
        let newOrigin = NSPoint(x: visibleRect.origin.x, y: visibleRect.origin.y + visibleRect.height)
        textView.scroll(newOrigin)
        let lineCount = Int(visibleRect.height / (textView.font?.boundingRectForFont.height ?? 14))
        for _ in 0..<max(1, lineCount) { textView.moveDown(nil) }
    }
    
    private func fullPageUp(textView: NSTextView) {
        let visibleRect = textView.visibleRect
        let newOrigin = NSPoint(x: visibleRect.origin.x, y: max(0, visibleRect.origin.y - visibleRect.height))
        textView.scroll(newOrigin)
        let lineCount = Int(visibleRect.height / (textView.font?.boundingRectForFont.height ?? 14))
        for _ in 0..<max(1, lineCount) { textView.moveUp(nil) }
    }
    
    // MARK: - Paragraph Movement
    
    private func moveParagraphForward(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        var pos = range.location
        
        // Skip current non-blank lines
        while pos < text.length {
            if text.character(at: pos) == 10 {
                // Check if this is a blank line (next char is also newline or we're at end)
                let nextPos = pos + 1
                if nextPos >= text.length || text.character(at: nextPos) == 10 {
                    pos = nextPos
                    break
                }
            }
            pos += 1
        }
        
        // Skip blank lines
        while pos < text.length && text.character(at: pos) == 10 {
            pos += 1
        }
        
        textView.setSelectedRange(NSRange(location: min(pos, text.length), length: 0))
    }
    
    private func moveParagraphBackward(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        var pos = range.location
        
        guard pos > 0 else { return }
        pos -= 1
        
        // Skip blank lines backwards
        while pos > 0 && text.character(at: pos) == 10 { pos -= 1 }
        
        // Skip non-blank lines backwards until blank line
        while pos > 0 {
            if text.character(at: pos) == 10 {
                let prevPos = pos - 1
                if prevPos >= 0 && text.character(at: prevPos) == 10 {
                    pos += 1
                    break
                }
            }
            pos -= 1
        }
        
        textView.setSelectedRange(NSRange(location: max(0, pos), length: 0))
    }
    
    // MARK: - Find char on line (f/F/t/T)
    
    private func executeFindMotion(direction: String, char: Character, textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
        let pos = range.location
        let charValue = (String(char) as NSString).character(at: 0)
        
        switch direction {
        case "f":
            // Find forward on line
            var searchPos = pos + 1
            let lineEnd = lineRange.location + lineRange.length
            while searchPos < lineEnd {
                if text.character(at: searchPos) == charValue {
                    textView.setSelectedRange(NSRange(location: searchPos, length: 0))
                    return
                }
                searchPos += 1
            }
        case "F":
            // Find backward on line
            var searchPos = pos - 1
            while searchPos >= lineRange.location {
                if text.character(at: searchPos) == charValue {
                    textView.setSelectedRange(NSRange(location: searchPos, length: 0))
                    return
                }
                searchPos -= 1
            }
        case "t":
            // Till forward (one before the char)
            var searchPos = pos + 1
            let lineEnd = lineRange.location + lineRange.length
            while searchPos < lineEnd {
                if text.character(at: searchPos) == charValue {
                    let targetPos = max(pos + 1, searchPos - 1)
                    textView.setSelectedRange(NSRange(location: targetPos, length: 0))
                    return
                }
                searchPos += 1
            }
        case "T":
            // Till backward (one after the char)
            var searchPos = pos - 1
            while searchPos >= lineRange.location {
                if text.character(at: searchPos) == charValue {
                    let targetPos = min(pos - 1, searchPos + 1)
                    textView.setSelectedRange(NSRange(location: targetPos, length: 0))
                    return
                }
                searchPos -= 1
            }
        default:
            break
        }
    }
    
    /// Compute the range from cursor to the found char (for operator+f/F/t/T combos)
    private func computeFindRange(direction: String, char: Character, count: Int, textView: NSTextView) -> NSRange? {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return nil }
        let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
        let pos = range.location
        let charValue = (String(char) as NSString).character(at: 0)
        
        switch direction {
        case "f":
            var searchPos = pos + 1
            let lineEnd = lineRange.location + lineRange.length
            var found = 0
            while searchPos < lineEnd {
                if text.character(at: searchPos) == charValue {
                    found += 1
                    if found == count {
                        return NSRange(location: pos, length: searchPos - pos + 1)
                    }
                }
                searchPos += 1
            }
        case "t":
            var searchPos = pos + 1
            let lineEnd = lineRange.location + lineRange.length
            var found = 0
            while searchPos < lineEnd {
                if text.character(at: searchPos) == charValue {
                    found += 1
                    if found == count {
                        return NSRange(location: pos, length: searchPos - pos)
                    }
                }
                searchPos += 1
            }
        case "F":
            var searchPos = pos - 1
            var found = 0
            while searchPos >= lineRange.location {
                if text.character(at: searchPos) == charValue {
                    found += 1
                    if found == count {
                        return NSRange(location: searchPos, length: pos - searchPos)
                    }
                }
                searchPos -= 1
            }
        case "T":
            var searchPos = pos - 1
            var found = 0
            while searchPos >= lineRange.location {
                if text.character(at: searchPos) == charValue {
                    found += 1
                    if found == count {
                        return NSRange(location: searchPos + 1, length: pos - searchPos - 1)
                    }
                }
                searchPos -= 1
            }
        default:
            break
        }
        return nil
    }
    
    private func reverseDirection(_ dir: String) -> String {
        switch dir {
        case "f": return "F"
        case "F": return "f"
        case "t": return "T"
        case "T": return "t"
        default: return dir
        }
    }
    
    // MARK: - Matching Bracket
    
    private func jumpToMatchingBracket(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        let pos = range.location
        
        guard pos < text.length else { return }
        
        let brackets: [unichar: unichar] = [
            40: 41,   // ( -> )
            41: 40,   // ) -> (
            91: 93,   // [ -> ]
            93: 91,   // ] -> [
            123: 125,  // { -> }
            125: 123   // } -> {
        ]
        
        let openBrackets: Set<unichar> = [40, 91, 123] // (, [, {
        
        let currentChar = text.character(at: pos)
        guard let matchChar = brackets[currentChar] else { return }
        
        let forward = openBrackets.contains(currentChar)
        var depth = 1
        var searchPos = forward ? pos + 1 : pos - 1
        
        while forward ? searchPos < text.length : searchPos >= 0 {
            let ch = text.character(at: searchPos)
            if ch == currentChar {
                depth += 1
            } else if ch == matchChar {
                depth -= 1
                if depth == 0 {
                    textView.setSelectedRange(NSRange(location: searchPos, length: 0))
                    return
                }
            }
            searchPos += forward ? 1 : -1
        }
    }
    
    // MARK: - Edit Operations
    
    private func deleteCharUnderCursor(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        guard range.location < text.length else { return }
        
        let deleteRange = NSRange(location: range.location, length: 1)
        let deleted = text.substring(with: deleteRange)
        yankRegister = deleted
        yankIsLinewise = false
        
        if textView.shouldChangeText(in: deleteRange, replacementString: "") {
            textView.replaceCharacters(in: deleteRange, with: "")
            textView.didChangeText()
        }
    }
    
    private func deleteCharBeforeCursor(textView: NSTextView) {
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        guard range.location > 0 else { return }
        
        let text = textView.string as NSString
        let deleteRange = NSRange(location: range.location - 1, length: 1)
        let deleted = text.substring(with: deleteRange)
        yankRegister = deleted
        yankIsLinewise = false
        
        if textView.shouldChangeText(in: deleteRange, replacementString: "") {
            textView.replaceCharacters(in: deleteRange, with: "")
            textView.didChangeText()
        }
    }
    
    private func deleteToEndOfLine(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
        var lineEnd = lineRange.location + lineRange.length
        
        // Don't include trailing newline
        if lineEnd > range.location && lineEnd <= text.length && lineEnd > 0 {
            if text.character(at: lineEnd - 1) == 10 {
                lineEnd -= 1
            }
        }
        
        guard lineEnd > range.location else { return }
        
        let deleteRange = NSRange(location: range.location, length: lineEnd - range.location)
        let deleted = text.substring(with: deleteRange)
        yankRegister = deleted
        yankIsLinewise = false
        
        if textView.shouldChangeText(in: deleteRange, replacementString: "") {
            textView.replaceCharacters(in: deleteRange, with: "")
            textView.didChangeText()
        }
    }
    
    private func changeLine(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
        
        // Find first non-blank on line
        var firstNonBlank = lineRange.location
        let lineEnd = lineRange.location + lineRange.length
        while firstNonBlank < lineEnd && (text.character(at: firstNonBlank) == 32 || text.character(at: firstNonBlank) == 9) {
            firstNonBlank += 1
        }
        
        // Find end of content (before newline)
        var contentEnd = lineEnd
        if contentEnd > lineRange.location && contentEnd <= text.length && contentEnd > 0 {
            if text.character(at: contentEnd - 1) == 10 {
                contentEnd -= 1
            }
        }
        
        if contentEnd > firstNonBlank {
            let deleteRange = NSRange(location: firstNonBlank, length: contentEnd - firstNonBlank)
            let deleted = text.substring(with: deleteRange)
            yankRegister = deleted
            yankIsLinewise = false
            
            if textView.shouldChangeText(in: deleteRange, replacementString: "") {
                textView.replaceCharacters(in: deleteRange, with: "")
                textView.didChangeText()
            }
        }
        
        textView.setSelectedRange(NSRange(location: firstNonBlank, length: 0))
        enterInsertMode()
    }
    
    private func replaceCharUnderCursor(with char: Character, count: Int, textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        let replaceCount = min(count, text.length - range.location)
        guard replaceCount > 0 else { return }
        
        let replaceRange = NSRange(location: range.location, length: replaceCount)
        let replacement = String(repeating: String(char), count: replaceCount)
        
        if textView.shouldChangeText(in: replaceRange, replacementString: replacement) {
            textView.replaceCharacters(in: replaceRange, with: replacement)
            textView.didChangeText()
        }
        
        // Move cursor to the last replaced char
        textView.setSelectedRange(NSRange(location: range.location + replaceCount - 1, length: 0))
    }
    
    private func toggleCaseUnderCursor(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        guard range.location < text.length else { return }
        
        let charRange = NSRange(location: range.location, length: 1)
        let charStr = text.substring(with: charRange)
        let toggled: String
        if charStr == charStr.uppercased() {
            toggled = charStr.lowercased()
        } else {
            toggled = charStr.uppercased()
        }
        
        if textView.shouldChangeText(in: charRange, replacementString: toggled) {
            textView.replaceCharacters(in: charRange, with: toggled)
            textView.didChangeText()
        }
        
        // Move cursor forward
        textView.setSelectedRange(NSRange(location: min(range.location + 1, text.length - 1), length: 0))
    }
    
    private func toggleCaseSelection(textView: NSTextView) {
        let selectedRange = textView.selectedRange()
        guard selectedRange.length > 0 else { return }
        
        let text = textView.string as NSString
        let selectedStr = text.substring(with: selectedRange)
        var result = ""
        for ch in selectedStr {
            if ch.isUppercase {
                result += ch.lowercased()
            } else {
                result += ch.uppercased()
            }
        }
        
        if textView.shouldChangeText(in: selectedRange, replacementString: result) {
            textView.replaceCharacters(in: selectedRange, with: result)
            textView.didChangeText()
        }
        textView.setSelectedRange(NSRange(location: selectedRange.location, length: 0))
    }
    
    private func joinLines(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
        let lineEnd = lineRange.location + lineRange.length
        
        // Find the newline at end of current line
        guard lineEnd > 0 && lineEnd <= text.length else { return }
        
        // Find newline position
        var newlinePos = lineEnd - 1
        guard newlinePos < text.length && text.character(at: newlinePos) == 10 else { return }
        
        // Delete newline and leading whitespace of next line, replace with a single space
        var deleteEnd = newlinePos + 1
        while deleteEnd < text.length && (text.character(at: deleteEnd) == 32 || text.character(at: deleteEnd) == 9) {
            deleteEnd += 1
        }
        
        let deleteRange = NSRange(location: newlinePos, length: deleteEnd - newlinePos)
        if textView.shouldChangeText(in: deleteRange, replacementString: " ") {
            textView.replaceCharacters(in: deleteRange, with: " ")
            textView.didChangeText()
        }
        
        textView.setSelectedRange(NSRange(location: newlinePos, length: 0))
    }
    
    private func insertLineBelow(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
        
        // Get indentation of current line
        var indent = ""
        var pos = lineRange.location
        while pos < lineRange.location + lineRange.length {
            let ch = text.character(at: pos)
            if ch == 32 || ch == 9 {
                indent += String(Character(UnicodeScalar(ch)!))
                pos += 1
            } else {
                break
            }
        }
        
        let insertPos = lineRange.location + lineRange.length
        let insertion = indent.isEmpty ? "\n" : "\n\(indent)"
        
        let insertRange = NSRange(location: min(insertPos, text.length), length: 0)
        if textView.shouldChangeText(in: insertRange, replacementString: insertion) {
            textView.replaceCharacters(in: insertRange, with: insertion)
            textView.didChangeText()
        }
        
        textView.setSelectedRange(NSRange(location: insertRange.location + insertion.count, length: 0))
    }
    
    private func insertLineAbove(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
        
        // Get indentation of current line
        var indent = ""
        var pos = lineRange.location
        while pos < lineRange.location + lineRange.length {
            let ch = text.character(at: pos)
            if ch == 32 || ch == 9 {
                indent += String(Character(UnicodeScalar(ch)!))
                pos += 1
            } else {
                break
            }
        }
        
        let insertion = indent.isEmpty ? "\n" : "\(indent)\n"
        let insertRange = NSRange(location: lineRange.location, length: 0)
        
        if textView.shouldChangeText(in: insertRange, replacementString: insertion) {
            textView.replaceCharacters(in: insertRange, with: insertion)
            textView.didChangeText()
        }
        
        // Position cursor at end of indentation on the new line
        let cursorPos = lineRange.location + indent.count
        textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
    }
    
    private func deleteLine(textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
        
        let deleted = text.substring(with: lineRange)
        yankRegister = deleted
        yankIsLinewise = true
        
        if textView.shouldChangeText(in: lineRange, replacementString: "") {
            textView.replaceCharacters(in: lineRange, with: "")
            textView.didChangeText()
        }
        
        // Position cursor at first non-blank of new current line
        let newText = textView.string as NSString
        let newPos = min(lineRange.location, newText.length)
        textView.setSelectedRange(NSRange(location: newPos, length: 0))
    }
    
    private func yankLine(count: Int, textView: NSTextView) {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        
        // Yank 'count' lines starting from current
        var endLocation = range.location
        for _ in 0..<count {
            let lineRange = text.lineRange(for: NSRange(location: endLocation, length: 0))
            endLocation = lineRange.location + lineRange.length
            if endLocation >= text.length { break }
        }
        
        let startLineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
        let yankRange = NSRange(location: startLineRange.location, length: endLocation - startLineRange.location)
        let yanked = text.substring(with: yankRange)
        
        yankRegister = yanked
        yankIsLinewise = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(yanked, forType: .string)
        
        statusMessage = "\(count) line\(count > 1 ? "s" : "") yanked"
    }
    
    private func deleteSelection(textView: NSTextView) {
        textView.delete(nil)
    }
    
    private func yankSelection(textView: NSTextView) {
        let selectedRange = textView.selectedRange()
        let text = textView.string as NSString
        if selectedRange.length > 0 {
            yankRegister = text.substring(with: selectedRange)
            yankIsLinewise = false
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(yankRegister, forType: .string)
        }
        if let range = textView.selectedRanges.first?.rangeValue {
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
        }
    }
    
    private func pasteAfter(textView: NSTextView) {
        if yankIsLinewise {
            // Paste on a new line below
            let text = textView.string as NSString
            guard let range = textView.selectedRanges.first?.rangeValue else { return }
            let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
            let insertPos = lineRange.location + lineRange.length
            
            var content = yankRegister
            // Ensure it ends with newline for linewise paste
            if !content.hasSuffix("\n") { content += "\n" }
            
            let insertRange = NSRange(location: min(insertPos, text.length), length: 0)
            if textView.shouldChangeText(in: insertRange, replacementString: content) {
                textView.replaceCharacters(in: insertRange, with: content)
                textView.didChangeText()
            }
            textView.setSelectedRange(NSRange(location: insertPos, length: 0))
        } else {
            // Character-wise paste after cursor
            guard let range = textView.selectedRanges.first?.rangeValue else { return }
            let text = textView.string as NSString
            let insertPos = min(range.location + 1, text.length)
            let insertRange = NSRange(location: insertPos, length: 0)
            
            if textView.shouldChangeText(in: insertRange, replacementString: yankRegister) {
                textView.replaceCharacters(in: insertRange, with: yankRegister)
                textView.didChangeText()
            }
            textView.setSelectedRange(NSRange(location: insertPos + yankRegister.count - 1, length: 0))
        }
    }
    
    private func pasteBefore(textView: NSTextView) {
        if yankIsLinewise {
            let text = textView.string as NSString
            guard let range = textView.selectedRanges.first?.rangeValue else { return }
            let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
            
            var content = yankRegister
            if !content.hasSuffix("\n") { content += "\n" }
            
            let insertRange = NSRange(location: lineRange.location, length: 0)
            if textView.shouldChangeText(in: insertRange, replacementString: content) {
                textView.replaceCharacters(in: insertRange, with: content)
                textView.didChangeText()
            }
            textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
        } else {
            guard let range = textView.selectedRanges.first?.rangeValue else { return }
            let insertRange = NSRange(location: range.location, length: 0)
            
            if textView.shouldChangeText(in: insertRange, replacementString: yankRegister) {
                textView.replaceCharacters(in: insertRange, with: yankRegister)
                textView.didChangeText()
            }
            textView.setSelectedRange(NSRange(location: range.location + yankRegister.count - 1, length: 0))
        }
    }
    
    // MARK: - Operator + Motion
    
    /// Compute the text range that a motion covers from the current cursor position.
    private func computeMotionRange(motion: String, count: Int, textView: NSTextView) -> NSRange? {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return nil }
        let startPos = range.location
        
        // Temporarily move to compute the end position
        let savedRange = textView.selectedRange()
        
        switch motion {
        case "w":
            for _ in 0..<count { moveWordForward(textView: textView) }
        case "e":
            for _ in 0..<count { moveToEndOfWord(textView: textView) }
        case "b":
            for _ in 0..<count { moveWordBackward(textView: textView) }
        case "W":
            for _ in 0..<count { moveWORDForward(textView: textView) }
        case "E":
            for _ in 0..<count { moveToEndOfWORD(textView: textView) }
        case "B":
            for _ in 0..<count { moveWORDBackward(textView: textView) }
        case "$":
            moveToEndOfLine(textView: textView)
        case "0":
            moveToStartOfLine(textView: textView)
        case "^":
            moveToFirstNonBlank(textView: textView)
        case "G":
            moveToEnd(textView: textView)
        case "g":
            moveToStart(textView: textView)
        case "h":
            for _ in 0..<count { moveLeft(textView: textView) }
        case "l":
            for _ in 0..<count { moveRight(textView: textView) }
        case "j":
            // For dj, delete current line + next line
            for _ in 0..<count { moveDown(textView: textView) }
            // Line-wise for j/k
            let endRange = textView.selectedRange()
            let startLineRange = text.lineRange(for: NSRange(location: startPos, length: 0))
            let endLineRange = text.lineRange(for: NSRange(location: endRange.location, length: 0))
            let fullEnd = endLineRange.location + endLineRange.length
            textView.setSelectedRange(savedRange)
            return NSRange(location: startLineRange.location, length: fullEnd - startLineRange.location)
        case "k":
            for _ in 0..<count { moveUp(textView: textView) }
            let endRange = textView.selectedRange()
            let startLineRange = text.lineRange(for: NSRange(location: startPos, length: 0))
            let endLineRange = text.lineRange(for: NSRange(location: endRange.location, length: 0))
            let topLine = min(startLineRange.location, endLineRange.location)
            let bottomEnd = max(startLineRange.location + startLineRange.length, endLineRange.location + endLineRange.length)
            textView.setSelectedRange(savedRange)
            return NSRange(location: topLine, length: bottomEnd - topLine)
        case "{":
            for _ in 0..<count { moveParagraphBackward(textView: textView) }
        case "}":
            for _ in 0..<count { moveParagraphForward(textView: textView) }
        default:
            textView.setSelectedRange(savedRange)
            return nil
        }
        
        let endPos = textView.selectedRange().location
        textView.setSelectedRange(savedRange)
        
        if endPos == startPos { return nil }
        
        let rangeStart = min(startPos, endPos)
        var rangeEnd = max(startPos, endPos)
        
        // For "e" and "E" motions, include the end character
        if motion == "e" || motion == "E" {
            rangeEnd = min(rangeEnd + 1, text.length)
        }
        // For "$", include through end of line content
        if motion == "$" {
            rangeEnd = min(rangeEnd + 1, text.length)
        }
        
        return NSRange(location: rangeStart, length: rangeEnd - rangeStart)
    }
    
    /// Apply an operator (d/c/y) to a given range.
    private func applyOperator(_ op: String, range: NSRange, textView: NSTextView) {
        let text = textView.string as NSString
        guard range.location >= 0 && range.location + range.length <= text.length else { return }
        
        let affectedText = text.substring(with: range)
        
        switch op {
        case "d":
            yankRegister = affectedText
            yankIsLinewise = false
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(affectedText, forType: .string)
            
            if textView.shouldChangeText(in: range, replacementString: "") {
                textView.replaceCharacters(in: range, with: "")
                textView.didChangeText()
            }
            let newText = textView.string as NSString
            textView.setSelectedRange(NSRange(location: min(range.location, newText.length), length: 0))
            
        case "c":
            yankRegister = affectedText
            yankIsLinewise = false
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(affectedText, forType: .string)
            
            if textView.shouldChangeText(in: range, replacementString: "") {
                textView.replaceCharacters(in: range, with: "")
                textView.didChangeText()
            }
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            enterInsertMode()
            
        case "y":
            yankRegister = affectedText
            yankIsLinewise = false
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(affectedText, forType: .string)
            statusMessage = "yanked"
            
        default:
            break
        }
    }
    
    // MARK: - Text Objects (basic: iw/aw)
    
    /// Handle "i" or "a" text object after an operator. This method is called
    /// when we've consumed op + "i"/"a" and need to read the object char.
    /// For simplicity, we handle this by consuming the next key inline.
    /// Returns true if we need to wait for another key (we don't, we wait in the
    /// pending state). Actually, this is called from the operator handler. We need
    /// to return false and set up state for the next key.
    ///
    /// Re-architecture note: text objects need a pending state. For simplicity,
    /// let's just handle common text objects immediately by looking at the char
    /// around the cursor.
    private func handleTextObject(outer: Bool, operator op: String, count: Int, textView: NSTextView) -> Bool {
        // We need the next key to determine which text object.
        // For now, store the pending state and return true.
        // We'll need another pending state. Let's use pendingMotion for this.
        pendingOperator = op
        pendingMotion = outer ? "a_obj" : "i_obj"
        // We need to handle the NEXT key as a text object identifier.
        // But our architecture handles pendingMotion as f/F/t/T/r.
        // Let's extend it: if pendingMotion starts with "a_obj" or "i_obj",
        // the next key is the object char.
        return true
    }
    
    /// Compute the range for a text object (iw, aw, i", a", i(, a(, etc.)
    private func computeTextObjectRange(key: Character, outer: Bool, textView: NSTextView) -> NSRange? {
        let text = textView.string as NSString
        guard let range = textView.selectedRanges.first?.rangeValue else { return nil }
        let pos = range.location
        
        switch key {
        case "w":
            return wordTextObjectRange(at: pos, outer: outer, text: text)
        case "\"", "'", "`":
            return quotedTextObjectRange(at: pos, quote: key, outer: outer, text: text)
        case "(", ")", "b":
            return bracketTextObjectRange(at: pos, open: 40, close: 41, outer: outer, text: text)
        case "[", "]":
            return bracketTextObjectRange(at: pos, open: 91, close: 93, outer: outer, text: text)
        case "{", "}", "B":
            return bracketTextObjectRange(at: pos, open: 123, close: 125, outer: outer, text: text)
        case "<", ">":
            return bracketTextObjectRange(at: pos, open: 60, close: 62, outer: outer, text: text)
        default:
            return nil
        }
    }
    
    private func wordTextObjectRange(at pos: Int, outer: Bool, text: NSString) -> NSRange? {
        guard pos < text.length else { return nil }
        
        let ch = text.character(at: pos)
        var start = pos
        var end = pos
        
        if isWordChar(ch) {
            // Expand to cover word chars
            while start > 0 && isWordChar(text.character(at: start - 1)) { start -= 1 }
            while end < text.length - 1 && isWordChar(text.character(at: end + 1)) { end += 1 }
        } else if !isWhitespace(ch) {
            // Punctuation word
            while start > 0 && !isWordChar(text.character(at: start - 1)) && !isWhitespace(text.character(at: start - 1)) { start -= 1 }
            while end < text.length - 1 && !isWordChar(text.character(at: end + 1)) && !isWhitespace(text.character(at: end + 1)) { end += 1 }
        } else {
            // On whitespace
            while start > 0 && isWhitespace(text.character(at: start - 1)) { start -= 1 }
            while end < text.length - 1 && isWhitespace(text.character(at: end + 1)) { end += 1 }
        }
        
        if outer {
            // Include trailing whitespace (or leading if at end of line)
            while end < text.length - 1 && (text.character(at: end + 1) == 32 || text.character(at: end + 1) == 9) { end += 1 }
        }
        
        return NSRange(location: start, length: end - start + 1)
    }
    
    private func quotedTextObjectRange(at pos: Int, quote: Character, outer: Bool, text: NSString) -> NSRange? {
        let quoteChar = (String(quote) as NSString).character(at: 0)
        let lineRange = text.lineRange(for: NSRange(location: pos, length: 0))
        
        // Find opening quote (search backward from pos, then forward)
        var openPos: Int? = nil
        var closePos: Int? = nil
        
        // Search for pair on the current line
        var searchPos = lineRange.location
        let lineEnd = lineRange.location + lineRange.length
        var quotePositions: [Int] = []
        
        while searchPos < lineEnd {
            if text.character(at: searchPos) == quoteChar {
                quotePositions.append(searchPos)
            }
            searchPos += 1
        }
        
        // Find the pair that surrounds pos
        for i in stride(from: 0, to: quotePositions.count - 1, by: 2) {
            let open = quotePositions[i]
            let close = quotePositions[i + 1]
            if pos >= open && pos <= close {
                openPos = open
                closePos = close
                break
            }
        }
        
        guard let oPos = openPos, let cPos = closePos else { return nil }
        
        if outer {
            return NSRange(location: oPos, length: cPos - oPos + 1)
        } else {
            return NSRange(location: oPos + 1, length: cPos - oPos - 1)
        }
    }
    
    private func bracketTextObjectRange(at pos: Int, open: unichar, close: unichar, outer: Bool, text: NSString) -> NSRange? {
        // Search backward for matching open bracket
        var depth = 0
        var searchPos = pos
        var openPos: Int? = nil
        
        // If we're on the open bracket, start from there
        if searchPos < text.length && text.character(at: searchPos) == open {
            openPos = searchPos
        } else {
            while searchPos >= 0 {
                let ch = text.character(at: searchPos)
                if ch == close { depth += 1 }
                if ch == open {
                    if depth == 0 {
                        openPos = searchPos
                        break
                    }
                    depth -= 1
                }
                if searchPos == 0 { break }
                searchPos -= 1
            }
        }
        
        guard let oPos = openPos else { return nil }
        
        // Search forward for matching close bracket
        depth = 1
        searchPos = oPos + 1
        while searchPos < text.length {
            let ch = text.character(at: searchPos)
            if ch == open { depth += 1 }
            if ch == close {
                depth -= 1
                if depth == 0 {
                    if outer {
                        return NSRange(location: oPos, length: searchPos - oPos + 1)
                    } else {
                        return NSRange(location: oPos + 1, length: searchPos - oPos - 1)
                    }
                }
            }
            searchPos += 1
        }
        
        return nil
    }
    
    // MARK: - Dot Repeat
    
    private func replayLastEdit(count: Int, textView: NSTextView) {
        guard let cmd = lastEditCommand else { return }
        isReplaying = true
        defer { isReplaying = false }
        
        let effectiveCount = count > 1 ? count : cmd.count
        
        switch cmd.type {
        case .deleteChar:
            for _ in 0..<effectiveCount { deleteCharUnderCursor(textView: textView) }
        case .deleteCharBefore:
            for _ in 0..<effectiveCount { deleteCharBeforeCursor(textView: textView) }
        case .substitute:
            deleteCharUnderCursor(textView: textView)
            enterInsertMode()
        case .substituteLine:
            for _ in 0..<effectiveCount { changeLine(textView: textView) }
        case .changeToEnd:
            deleteToEndOfLine(textView: textView)
            enterInsertMode()
        case .deleteToEnd:
            deleteToEndOfLine(textView: textView)
        case .joinLine:
            for _ in 0..<effectiveCount { joinLines(textView: textView) }
        case .replaceChar:
            if let ch = cmd.char {
                replaceCharUnderCursor(with: ch, count: effectiveCount, textView: textView)
            }
        case .toggleCase:
            for _ in 0..<effectiveCount { toggleCaseUnderCursor(textView: textView) }
        case .deleteLine:
            for _ in 0..<effectiveCount { deleteLine(textView: textView) }
        case .operatorMotion:
            if let motionStr = cmd.motion, motionStr.count >= 2 {
                let op = String(motionStr.first!)
                let motion = String(motionStr.dropFirst())
                
                if motion == "f" || motion == "F" || motion == "t" || motion == "T" {
                    if let ch = cmd.motionChar {
                        if let range = computeFindRange(direction: motion, char: ch, count: effectiveCount, textView: textView) {
                            applyOperator(op, range: range, textView: textView)
                        }
                    }
                } else {
                    if let range = computeMotionRange(motion: motion, count: effectiveCount, textView: textView) {
                        applyOperator(op, range: range, textView: textView)
                    }
                }
            }
        case .insertBelow:
            insertLineBelow(textView: textView)
            enterInsertMode()
        case .insertAbove:
            insertLineAbove(textView: textView)
            enterInsertMode()
        case .paste:
            pasteAfter(textView: textView)
        }
    }
    
    // MARK: - Command Execution
    
    private func executeCommand(textView: NSTextView) {
        let command = commandBuffer.trimmingCharacters(in: .whitespaces)
        
        switch command {
        case "w":
            statusMessage = "Write not implemented (use Cmd+S)"
        case "q":
            statusMessage = "Quit not implemented (use Cmd+Q)"
        case "wq":
            statusMessage = "Write and quit not implemented"
        default:
            if let lineNumber = Int(command) {
                moveToLine(lineNumber, textView: textView)
            } else {
                statusMessage = "Unknown command: \(command)"
            }
        }
    }
    
    // MARK: - Character Classification Helpers
    
    private func isWordChar(_ ch: unichar) -> Bool {
        // Word characters: alphanumeric and underscore
        let scalar = Unicode.Scalar(ch)
        if let s = scalar {
            return CharacterSet.alphanumerics.contains(s) || ch == 95 // underscore
        }
        return false
    }
    
    private func isWhitespace(_ ch: unichar) -> Bool {
        return ch == 32 || ch == 9 || ch == 10 || ch == 13
    }
}
