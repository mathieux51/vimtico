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
    
    private var pendingOperator: String?
    private var count: Int = 1
    private var countBuffer: String = ""
    
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
    
    private func handleNormalMode(key: String, modifiers: NSEvent.ModifierFlags, textView: NSTextView) -> Bool {
        // Handle count prefix
        if let digit = Int(key), countBuffer.isEmpty ? digit > 0 : true {
            countBuffer += key
            count = Int(countBuffer) ?? 1
            return true
        }
        
        defer {
            countBuffer = ""
            count = 1
        }
        
        switch key {
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
            moveToStartOfLine(textView: textView)
            enterInsertMode()
            return true
        case "o":
            insertLineBelow(textView: textView)
            enterInsertMode()
            return true
        case "O":
            insertLineAbove(textView: textView)
            enterInsertMode()
            return true
        case "h":
            for _ in 0..<count { moveLeft(textView: textView) }
            return true
        case "j":
            for _ in 0..<count { moveDown(textView: textView) }
            return true
        case "k":
            for _ in 0..<count { moveUp(textView: textView) }
            return true
        case "l":
            for _ in 0..<count { moveRight(textView: textView) }
            return true
        case "w":
            for _ in 0..<count { moveWordForward(textView: textView) }
            return true
        case "b":
            for _ in 0..<count { moveWordBackward(textView: textView) }
            return true
        case "0":
            if countBuffer.isEmpty {
                moveToStartOfLine(textView: textView)
                return true
            }
            return false
        case "$":
            moveToEndOfLine(textView: textView)
            return true
        case "^":
            moveToFirstNonBlank(textView: textView)
            return true
        case "G":
            if countBuffer.isEmpty {
                moveToEnd(textView: textView)
            } else {
                moveToLine(count, textView: textView)
            }
            return true
        case "g":
            pendingOperator = "g"
            return true
        case "d":
            if pendingOperator == "d" {
                deleteLine(textView: textView)
                pendingOperator = nil
            } else {
                pendingOperator = "d"
            }
            return true
        case "y":
            if pendingOperator == "y" {
                yankLine(textView: textView)
                pendingOperator = nil
            } else {
                pendingOperator = "y"
            }
            return true
        case "p":
            paste(textView: textView)
            return true
        case "u":
            textView.undoManager?.undo()
            return true
        case "r" where modifiers.contains(.control):
            textView.undoManager?.redo()
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
        case "\u{1B}": // Escape
            mode = .normal
            pendingOperator = nil
            return true
        default:
            if pendingOperator == "g" && key == "g" {
                moveToStart(textView: textView)
                pendingOperator = nil
                return true
            }
            return false
        }
    }
    
    private func handleInsertMode(key: String, modifiers: NSEvent.ModifierFlags, textView: NSTextView) -> Bool {
        if key == "\u{1B}" { // Escape
            mode = .normal
            moveLeft(textView: textView) // Vim behavior: move cursor back when exiting insert
            return true
        }
        return false // Let the text view handle normal typing
    }
    
    private func handleVisualMode(key: String, modifiers: NSEvent.ModifierFlags, textView: NSTextView) -> Bool {
        switch key {
        case "\u{1B}": // Escape
            mode = .normal
            return true
        case "h", "j", "k", "l", "w", "b", "0", "$", "^", "G", "g":
            // Extend selection with movement
            return handleNormalMode(key: key, modifiers: modifiers, textView: textView)
        case "d", "x":
            deleteSelection(textView: textView)
            mode = .normal
            return true
        case "y":
            yankSelection(textView: textView)
            mode = .normal
            return true
        default:
            return false
        }
    }
    
    private func handleCommandMode(key: String, modifiers: NSEvent.ModifierFlags, textView: NSTextView) -> Bool {
        if key == "\u{1B}" { // Escape
            mode = .normal
            commandBuffer = ""
            return true
        }
        
        if key == "\r" { // Enter
            executeCommand(textView: textView)
            mode = .normal
            commandBuffer = ""
            return true
        }
        
        if key == "\u{7F}" { // Backspace
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
    
    // MARK: - Movement operations
    
    private func moveLeft(textView: NSTextView) {
        guard let range = textView.selectedRanges.first?.rangeValue else { return }
        let newLocation = max(0, range.location - 1)
        textView.setSelectedRange(NSRange(location: newLocation, length: 0))
    }
    
    private func moveRight(textView: NSTextView) {
        guard let range = textView.selectedRanges.first?.rangeValue,
              let text = textView.string as NSString? else { return }
        let newLocation = min(text.length, range.location + 1)
        textView.setSelectedRange(NSRange(location: newLocation, length: 0))
    }
    
    private func moveUp(textView: NSTextView) {
        textView.moveUp(nil)
    }
    
    private func moveDown(textView: NSTextView) {
        textView.moveDown(nil)
    }
    
    private func moveWordForward(textView: NSTextView) {
        textView.moveWordForward(nil)
    }
    
    private func moveWordBackward(textView: NSTextView) {
        textView.moveWordBackward(nil)
    }
    
    private func moveToStartOfLine(textView: NSTextView) {
        textView.moveToBeginningOfLine(nil)
    }
    
    private func moveToEndOfLine(textView: NSTextView) {
        textView.moveToEndOfLine(nil)
    }
    
    private func moveToFirstNonBlank(textView: NSTextView) {
        textView.moveToBeginningOfLine(nil)
        // Skip whitespace
        guard let text = textView.string as NSString?,
              let range = textView.selectedRanges.first?.rangeValue else { return }
        
        var location = range.location
        while location < text.length {
            let char = text.character(at: location)
            if char != 32 && char != 9 { // space and tab
                break
            }
            location += 1
        }
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }
    
    private func moveToStart(textView: NSTextView) {
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }
    
    private func moveToEnd(textView: NSTextView) {
        guard let text = textView.string as NSString? else { return }
        textView.setSelectedRange(NSRange(location: text.length, length: 0))
    }
    
    private func moveToLine(_ line: Int, textView: NSTextView) {
        guard let text = textView.string as NSString? else { return }
        var currentLine = 1
        var location = 0
        
        while currentLine < line && location < text.length {
            if text.character(at: location) == 10 { // newline
                currentLine += 1
            }
            location += 1
        }
        
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }
    
    // MARK: - Edit operations
    
    private func insertLineBelow(textView: NSTextView) {
        textView.moveToEndOfLine(nil)
        textView.insertNewline(nil)
    }
    
    private func insertLineAbove(textView: NSTextView) {
        textView.moveToBeginningOfLine(nil)
        textView.insertNewline(nil)
        textView.moveUp(nil)
    }
    
    private func deleteLine(textView: NSTextView) {
        textView.moveToBeginningOfLine(nil)
        textView.moveToEndOfLineAndModifySelection(nil)
        textView.moveForwardAndModifySelection(nil) // Include newline
        textView.delete(nil)
    }
    
    private func yankLine(textView: NSTextView) {
        textView.moveToBeginningOfLine(nil)
        textView.moveToEndOfLineAndModifySelection(nil)
        textView.copy(nil)
        // Deselect
        if let range = textView.selectedRanges.first?.rangeValue {
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
        }
        statusMessage = "1 line yanked"
    }
    
    private func deleteSelection(textView: NSTextView) {
        textView.delete(nil)
    }
    
    private func yankSelection(textView: NSTextView) {
        textView.copy(nil)
        if let range = textView.selectedRanges.first?.rangeValue {
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
        }
    }
    
    private func paste(textView: NSTextView) {
        textView.paste(nil)
    }
    
    // MARK: - Command execution
    
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
}
