import SwiftUI

struct QueryEditorView: View {
    @ObservedObject var viewModel: DatabaseViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @State private var vimEngine = VimEngine()
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button(action: {
                    Task { await viewModel.executeQuery() }
                }) {
                    Label("Execute", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!viewModel.isConnected || viewModel.isLoading)
                
                Spacer()
                
                // Vim mode indicator
                if viewModel.vimModeEnabled {
                    VimModeIndicator(mode: vimEngine.mode, theme: themeManager.currentTheme)
                }
                
                Toggle(isOn: $viewModel.vimModeEnabled) {
                    Image(systemName: "character.cursor.ibeam")
                }
                .toggleStyle(.button)
                .help("Toggle Vim Mode")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(themeManager.currentTheme.secondaryBackgroundColor)
            
            Divider()
            
            // Query editor
            VimTextEditor(
                text: $viewModel.queryText,
                vimEngine: vimEngine,
                vimModeEnabled: $viewModel.vimModeEnabled,
                theme: themeManager.currentTheme
            )
            .frame(minHeight: 100)
            
            // Status bar
            if viewModel.vimModeEnabled && !vimEngine.commandBuffer.isEmpty {
                HStack {
                    Text(":\(vimEngine.commandBuffer)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.foregroundColor)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(themeManager.currentTheme.secondaryBackgroundColor)
            }
            
            if !vimEngine.statusMessage.isEmpty {
                HStack {
                    Text(vimEngine.statusMessage)
                        .font(.caption)
                        .foregroundColor(themeManager.currentTheme.foregroundColor.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 2)
                .background(themeManager.currentTheme.secondaryBackgroundColor)
            }
        }
        .background(themeManager.currentTheme.editorBackgroundColor)
        .onReceive(NotificationCenter.default.publisher(for: .executeQuery)) { _ in
            Task { await viewModel.executeQuery() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleVimMode)) { _ in
            viewModel.vimModeEnabled.toggle()
        }
    }
}

struct VimModeIndicator: View {
    let mode: VimModeState
    let theme: Theme
    
    var modeColor: Color {
        switch mode {
        case .normal: return theme.vimNormalModeColor
        case .insert: return theme.vimInsertModeColor
        case .visual, .visualLine: return theme.vimVisualModeColor
        case .command: return theme.vimCommandModeColor
        }
    }
    
    var body: some View {
        Text(mode.rawValue)
            .font(.system(.caption, design: .monospaced).bold())
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(modeColor)
            .cornerRadius(4)
    }
}

#Preview {
    QueryEditorView(viewModel: DatabaseViewModel())
        .environmentObject(ThemeManager())
}
