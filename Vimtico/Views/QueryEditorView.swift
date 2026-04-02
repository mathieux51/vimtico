import SwiftUI

struct QueryEditorView: View {
    @ObservedObject var viewModel: DatabaseViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var configManager: ConfigurationManager
    @State private var vimEngine = VimEngine()
    @State private var cursorPosition: Int = 0
    
    /// Offset the autocomplete popup below the first line of text,
    /// accounting for the current font size and the text container inset.
    private var autocompleteTopOffset: CGFloat {
        let lineHeight = ceil(viewModel.fontSize * 1.2)
        let textContainerInset: CGFloat = 8
        return textContainerInset + lineHeight + 4
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button(action: {
                    viewModel.executeQuery()
                }) {
                    Label("Execute", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!viewModel.isConnected || viewModel.isLoading)
                
                Spacer()
                
                // Autocomplete mode indicator
                if viewModel.autocompleteService.currentMode != .disabled {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.caption)
                        Text(viewModel.autocompleteService.currentMode.rawValue)
                            .font(.caption)
                    }
                    .foregroundColor(themeManager.currentTheme.foregroundColor.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(themeManager.currentTheme.secondaryBackgroundColor.opacity(0.5))
                    .cornerRadius(4)
                }
                
                // Validation status indicator
                ValidationStatusIndicator(
                    status: viewModel.validationStatus,
                    theme: themeManager.currentTheme
                )
                
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
            
            // Query editor with autocomplete overlay
            ZStack(alignment: .topLeading) {
                VimTextEditor(
                    text: $viewModel.queryText,
                    vimEngine: vimEngine,
                    vimModeEnabled: $viewModel.vimModeEnabled,
                    fontSize: $viewModel.fontSize,
                    theme: themeManager.currentTheme,
                    showingAutocomplete: $viewModel.showAutocompleteSuggestions,
                    cursorPositionAfterCompletion: $viewModel.cursorPositionAfterCompletion,
                    onAutocompleteAccept: {
                        viewModel.applySelectedSuggestion()
                    },
                    onAutocompleteUp: {
                        viewModel.selectPreviousSuggestion()
                    },
                    onAutocompleteDown: {
                        viewModel.selectNextSuggestion()
                    },
                    onAutocompleteDismiss: {
                        viewModel.dismissAutocomplete()
                    },
                    onTab: {
                        Task {
                            await viewModel.requestAutocomplete(at: viewModel.queryText.count)
                        }
                    }
                )
                .frame(minHeight: 100)
                .onChange(of: viewModel.queryText) { _, newValue in
                    // Request autocomplete on text change
                    Task {
                        await viewModel.requestAutocomplete(at: newValue.count)
                    }
                    // Schedule debounced SQL validation
                    viewModel.scheduleValidation()
                }
                
                // Autocomplete popup
                if viewModel.showAutocompleteSuggestions && !viewModel.autocompleteSuggestions.isEmpty {
                    AutocompletePopupView(
                        suggestions: viewModel.autocompleteSuggestions,
                        selectedIndex: viewModel.selectedSuggestionIndex,
                        theme: themeManager.currentTheme,
                        onSelect: { completion in
                            viewModel.applyAutocompletion(completion)
                        },
                        onDismiss: {
                            viewModel.dismissAutocomplete()
                        }
                    )
                    .frame(maxWidth: 400, maxHeight: 200)
                    .padding(.top, autocompleteTopOffset)
                    .padding(.leading, 16)
                    .zIndex(100)
                }
            }
            
            // Validation error bar
            if case .invalid(let message) = viewModel.validationStatus {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(themeManager.currentTheme.errorColor)
                        .font(.caption)
                    Text(message)
                        .font(.system(size: max(viewModel.fontSize - 2, 10), design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.errorColor)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(themeManager.currentTheme.errorColor.opacity(0.1))
                .contentShape(Rectangle())
                .onTapGesture {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
            }
            
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
            viewModel.executeQuery()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleVimMode)) { _ in
            viewModel.vimModeEnabled.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomIn)) { _ in
            if viewModel.fontSize < CGFloat(EditorConfig.maxFontSize) {
                viewModel.fontSize += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomOut)) { _ in
            if viewModel.fontSize > CGFloat(EditorConfig.minFontSize) {
                viewModel.fontSize -= 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomReset)) { _ in
            viewModel.fontSize = CGFloat(EditorConfig.defaultFontSize)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cancelQuery)) { _ in
            viewModel.cancelQuery()
        }
        .onReceive(NotificationCenter.default.publisher(for: .executeSelectedQuery)) { notification in
            if let sql = notification.object as? String {
                viewModel.executeSelectedQuery(sql)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openExternalEditor)) { _ in
            viewModel.openExternalEditor()
        }
        .onAppear {
            // Configure autocomplete
            let mode = configManager.configuration.editor?.autocompleteMode ?? .ruleBased
            let openAIKey = configManager.configuration.editor?.openAIApiKey
            let anthropicKey = configManager.configuration.editor?.anthropicApiKey
            viewModel.configureAutocomplete(mode: mode, openAIKey: openAIKey, anthropicKey: anthropicKey)
        }
    }
}

// MARK: - Autocomplete Popup View

struct AutocompletePopupView: View {
    let suggestions: [SQLCompletion]
    let selectedIndex: Int
    let theme: Theme
    let onSelect: (SQLCompletion) -> Void
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            Button(action: {
                                onSelect(suggestion)
                            }) {
                                AutocompleteRowView(
                                    suggestion: suggestion,
                                    isSelected: index == selectedIndex,
                                    theme: theme
                                )
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                }
                .onChange(of: selectedIndex) { _, newIndex in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .background(theme.secondaryBackgroundColor)
        .cornerRadius(6)
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.foregroundColor.opacity(0.2), lineWidth: 1)
        )
    }
}

struct AutocompleteRowView: View {
    let suggestion: SQLCompletion
    let isSelected: Bool
    let theme: Theme
    
    var iconColor: Color {
        switch suggestion.type {
        case .keyword: return theme.keywordColor
        case .function: return theme.functionColor
        case .table: return Color.green
        case .column: return Color.blue
        case .schema: return Color.purple
        case .operator: return Color.orange
        case .symbol: return theme.foregroundColor
        case .snippet: return Color.cyan
        }
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Text(suggestion.icon)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundColor(iconColor)
                .frame(width: 16)
            
            Text(suggestion.displayText)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(theme.foregroundColor)
            
            Spacer()
            
            if let detail = suggestion.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(theme.foregroundColor.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? theme.editorSelectionColor : Color.clear)
        .contentShape(Rectangle())
    }
}

struct ValidationStatusIndicator: View {
    let status: ValidationStatus
    let theme: Theme
    
    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .validating:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        case .valid:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(theme.successColor)
                .help("SQL syntax valid")
        case .invalid:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(theme.errorColor)
                .help("SQL syntax error")
        case .skipped:
            Image(systemName: "minus.circle")
                .font(.caption)
                .foregroundColor(theme.foregroundColor.opacity(0.4))
                .help("Validation skipped (DDL/utility)")
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
        .environmentObject(ConfigurationManager())
}
