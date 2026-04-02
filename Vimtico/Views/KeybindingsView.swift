import SwiftUI

struct KeybindingsView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Keybindings")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            .background(themeManager.currentTheme.secondaryBackgroundColor)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    keybindingSection("Global", bindings: [
                        ("Cmd + Return", "Execute query"),
                        ("Cmd + N", "New connection"),
                        ("Cmd + R", "Reconnect to database"),
                        ("Cmd + Shift + V", "Toggle vim mode"),
                        ("Cmd + +", "Zoom in"),
                        ("Cmd + -", "Zoom out"),
                        ("Cmd + 0", "Reset zoom"),
                        ("Cmd + /", "Show keybindings"),
                    ])
                    
                    keybindingSection("Vim - Normal Mode", bindings: [
                        ("i", "Enter insert mode"),
                        ("a", "Append after cursor"),
                        ("A", "Append at end of line"),
                        ("I", "Insert at first non-blank"),
                        ("o", "Open line below"),
                        ("O", "Open line above"),
                        ("s", "Substitute char (delete + insert)"),
                        ("S / cc", "Substitute entire line"),
                        ("C", "Change to end of line"),
                        ("v", "Enter visual mode"),
                        ("V", "Enter visual line mode"),
                        (":", "Enter command mode"),
                        ("Return", "Execute query"),
                        ("Esc", "Cancel running query"),
                    ])
                    
                    keybindingSection("Vim - Movement", bindings: [
                        ("h / j / k / l", "Move left / down / up / right"),
                        ("w / b", "Word forward / backward"),
                        ("e", "Move to end of word"),
                        ("W / B", "WORD forward / backward"),
                        ("E", "Move to end of WORD"),
                        ("0", "Move to start of line"),
                        ("$", "Move to end of line"),
                        ("^", "Move to first non-blank"),
                        ("gg", "Move to start of document"),
                        ("G", "Move to end of document"),
                        ("{count}G", "Go to line number"),
                        ("f{char}", "Find char forward on line"),
                        ("F{char}", "Find char backward on line"),
                        ("t{char}", "Till char forward on line"),
                        ("T{char}", "Till char backward on line"),
                        ("; / ,", "Repeat / reverse last f/F/t/T"),
                        ("%", "Jump to matching bracket"),
                        ("{ / }", "Paragraph backward / forward"),
                        ("H / M / L", "Screen top / middle / bottom"),
                        ("Ctrl + D / U", "Half page down / up"),
                        ("Ctrl + F / B", "Full page down / up"),
                    ])
                    
                    keybindingSection("Vim - Editing", bindings: [
                        ("x", "Delete char under cursor"),
                        ("X", "Delete char before cursor"),
                        ("r{char}", "Replace char under cursor"),
                        ("~", "Toggle case of char"),
                        ("D", "Delete to end of line"),
                        ("J", "Join current line with next"),
                        ("dd", "Delete entire line"),
                        ("yy", "Yank (copy) line"),
                        ("p / P", "Paste after / before cursor"),
                        ("u", "Undo"),
                        ("Ctrl + R", "Redo"),
                        (".", "Repeat last edit"),
                    ])
                    
                    keybindingSection("Vim - Operators + Motions", bindings: [
                        ("d{motion}", "Delete (e.g. dw, de, d$, dG)"),
                        ("c{motion}", "Change (e.g. cw, ce, c$, cG)"),
                        ("y{motion}", "Yank (e.g. yw, ye, y$, yG)"),
                        ("df{char}", "Delete to char (inclusive)"),
                        ("dt{char}", "Delete till char"),
                        ("cf{char} / ct{char}", "Change to/till char"),
                    ])
                    
                    keybindingSection("Vim - Text Objects", bindings: [
                        ("diw / daw", "Delete inner/around word"),
                        ("ciw / caw", "Change inner/around word"),
                        ("di\" / da\"", "Delete inner/around quotes"),
                        ("di( / da(", "Delete inner/around parens"),
                        ("di{ / da{", "Delete inner/around braces"),
                        ("di[ / da[", "Delete inner/around brackets"),
                    ])
                    
                    keybindingSection("Vim - Insert Mode", bindings: [
                        ("Esc", "Return to normal mode"),
                        ("Tab", "Trigger autocomplete"),
                    ])
                    
                    keybindingSection("Vim - Visual Mode", bindings: [
                        ("Esc", "Return to normal mode"),
                        ("Return", "Execute selected text"),
                        ("d / x", "Delete selection"),
                        ("c", "Change selection"),
                        ("y", "Yank (copy) selection"),
                        ("~", "Toggle case of selection"),
                        ("J", "Join selected lines"),
                        ("All motions", "Extend selection"),
                    ])
                    
                    keybindingSection("Pane Navigation", bindings: [
                        ("Ctrl + W, h", "Focus sidebar"),
                        ("Ctrl + W, j", "Focus results"),
                        ("Ctrl + W, k", "Focus editor"),
                        ("Ctrl + W, l", "Focus editor / results"),
                    ])
                    
                    keybindingSection("Results Pane (when focused)", bindings: [
                        ("j / k", "Move selection down / up"),
                        ("h / l", "Move column left / right"),
                        ("g", "Jump to first row"),
                        ("G", "Jump to last row"),
                        ("0 / $", "Jump to first / last column"),
                        ("y", "Copy selected cell value"),
                        ("/", "Filter results"),
                    ])
                    
                    keybindingSection("Sidebar (when focused)", bindings: [
                        ("j / k", "Move selection down / up"),
                        ("g", "Jump to first table"),
                        ("G", "Jump to last table"),
                        ("Return", "Show table schema info"),
                        ("y", "Copy table name"),
                        ("/", "Filter tables"),
                    ])
                    
                    keybindingSection("Autocomplete", bindings: [
                        ("Tab", "Trigger autocomplete"),
                        ("Up / Down", "Navigate suggestions"),
                        ("Return", "Accept suggestion"),
                        ("Esc", "Dismiss popup"),
                    ])
                }
                .padding()
            }
        }
        .frame(minWidth: 600, idealWidth: 700, minHeight: 700, idealHeight: 850)
        .background(themeManager.currentTheme.backgroundColor)
        .foregroundColor(themeManager.currentTheme.foregroundColor)
    }
    
    @ViewBuilder
    private func keybindingSection(_ title: String, bindings: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(themeManager.currentTheme.keywordColor)
            
            ForEach(Array(bindings.enumerated()), id: \.offset) { _, binding in
                HStack(spacing: 0) {
                    Text(binding.0)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.functionColor)
                        .frame(width: 200, alignment: .leading)
                    
                    Text(binding.1)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.foregroundColor.opacity(0.8))
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
            }
        }
    }
}
