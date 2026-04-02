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
                        ("I", "Insert at start of line"),
                        ("o", "Open line below"),
                        ("O", "Open line above"),
                        ("v", "Enter visual mode"),
                        ("V", "Enter visual line mode"),
                        (":", "Enter command mode"),
                        ("Return", "Execute query"),
                        ("Esc", "Cancel running query"),
                        ("e", "Open external editor ($EDITOR)"),
                        ("h / j / k / l", "Move left / down / up / right"),
                        ("w", "Move word forward"),
                        ("b", "Move word backward"),
                        ("0", "Move to start of line"),
                        ("$", "Move to end of line"),
                        ("^", "Move to first non-blank"),
                        ("gg", "Move to start of document"),
                        ("G", "Move to end of document"),
                        ("dd", "Delete line"),
                        ("yy", "Yank (copy) line"),
                        ("p", "Paste"),
                        ("u", "Undo"),
                        ("Ctrl + R", "Redo"),
                    ])
                    
                    keybindingSection("Vim - Insert Mode", bindings: [
                        ("Esc", "Return to normal mode"),
                        ("Tab", "Trigger autocomplete"),
                    ])
                    
                    keybindingSection("Vim - Visual Mode", bindings: [
                        ("Esc", "Return to normal mode"),
                        ("Return", "Execute selected text"),
                        ("d / x", "Delete selection"),
                        ("y", "Yank (copy) selection"),
                        ("h / j / k / l", "Extend selection"),
                    ])
                    
                    keybindingSection("Pane Navigation", bindings: [
                        ("Ctrl + W, h", "Focus sidebar"),
                        ("Ctrl + W, j", "Focus results"),
                        ("Ctrl + W, k", "Focus editor"),
                        ("Ctrl + W, l", "Focus editor / results"),
                    ])
                    
                    keybindingSection("Results Pane (when focused)", bindings: [
                        ("j / k", "Move selection down / up"),
                        ("g", "Jump to first row"),
                        ("G", "Jump to last row"),
                        ("y", "Copy selected row"),
                    ])
                    
                    keybindingSection("Sidebar (when focused)", bindings: [
                        ("j / k", "Move selection down / up"),
                        ("g", "Jump to first table"),
                        ("G", "Jump to last table"),
                        ("Return", "Show table schema info"),
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
        .frame(minWidth: 600, idealWidth: 680, minHeight: 650, idealHeight: 780)
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
