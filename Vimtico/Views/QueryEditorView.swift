import SwiftUI

struct QueryEditorView: View {
    @ObservedObject var viewModel: DatabaseViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var configManager: ConfigurationManager
    @State private var vimEngine = VimEngine()
    @State private var cursorRect: CGRect = .zero
    @State private var showGoToLine: Bool = false
    @State private var goToLineText: String = ""
    
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
                
                // Line:Col indicator
                let lineCol = computeLineCol()
                Text("Ln \(lineCol.line), Col \(lineCol.col)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.foregroundColor.opacity(0.5))
                    .onTapGesture {
                        showGoToLine = true
                    }
                    .help("Click to go to line (Ctrl+G)")
                
                // Autocomplete mode indicator
                if viewModel.autocompleteService.currentMode != .disabled {
                    HStack(spacing: 4) {
                        if viewModel.autocompleteService.isLoading {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        } else if viewModel.autocompleteService.lastAPIError != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(themeManager.currentTheme.errorColor)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.caption)
                        }
                        Text(viewModel.autocompleteService.currentMode.rawValue)
                            .font(.caption)
                    }
                    .foregroundColor(
                        viewModel.autocompleteService.lastAPIError != nil
                            ? themeManager.currentTheme.errorColor
                            : themeManager.currentTheme.foregroundColor.opacity(0.6)
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(themeManager.currentTheme.secondaryBackgroundColor.opacity(0.5))
                    .cornerRadius(4)
                    .help(viewModel.autocompleteService.lastAPIError ?? viewModel.autocompleteService.currentMode.displayName)
                    .onTapGesture {
                        if let error = viewModel.autocompleteService.lastAPIError {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(error, forType: .string)
                        }
                    }
                }
                
                // Validation status indicator
                ValidationStatusIndicator(
                    status: viewModel.validationStatus,
                    theme: themeManager.currentTheme
                )
                
                // Vim mode indicator (always shown)
                VimModeIndicator(mode: vimEngine.mode, theme: themeManager.currentTheme)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(themeManager.currentTheme.secondaryBackgroundColor)
            
            Divider()
            
            // Query editor with autocomplete overlay
            GeometryReader { editorGeo in
                ZStack(alignment: .topLeading) {
                    VimTextEditor(
                        text: $viewModel.queryText,
                        vimEngine: vimEngine,
                        vimModeEnabled: $viewModel.vimModeEnabled,
                        fontSize: $viewModel.fontSize,
                        theme: themeManager.currentTheme,
                        cursorPosition: $viewModel.cursorPosition,
                        cursorRect: $cursorRect,
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
                            viewModel.requestAutocomplete(at: viewModel.cursorPosition)
                        }
                    )
                .frame(minHeight: 100)
                .onChange(of: viewModel.queryText) { _, newValue in
                    // Request autocomplete on text change using actual cursor position
                    viewModel.requestAutocomplete(at: viewModel.cursorPosition)
                    // Schedule debounced SQL validation
                    viewModel.scheduleValidation()
                }
                
                // Autocomplete popup positioned at cursor
                if viewModel.showAutocompleteSuggestions && !viewModel.autocompleteSuggestions.isEmpty {
                    let popupMaxWidth: CGFloat = 600
                    let popupMaxHeight: CGFloat = 300
                    let cursorX = max(0, cursorRect.origin.x)
                    let cursorY = cursorRect.origin.y + cursorRect.height + 2
                    // Clamp X so popup doesn't overflow the editor's right edge
                    let clampedX = min(cursorX, max(0, editorGeo.size.width - popupMaxWidth))
                    
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
                    .frame(maxWidth: popupMaxWidth, maxHeight: popupMaxHeight)
                    .fixedSize(horizontal: true, vertical: true)
                    .offset(
                        x: clampedX,
                        y: cursorY
                    )
                    .zIndex(100)
                }
                }
            }
            
            // API error bar
            if let apiError = viewModel.autocompleteService.lastAPIError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(themeManager.currentTheme.errorColor)
                        .font(.caption)
                    Text("Autocomplete: \(apiError)")
                        .font(.system(size: max(viewModel.fontSize - 2, 10), design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.errorColor)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") {
                        viewModel.autocompleteService.lastAPIError = nil
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(themeManager.currentTheme.foregroundColor.opacity(0.6))
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(themeManager.currentTheme.errorColor.opacity(0.1))
                .contentShape(Rectangle())
                .onTapGesture {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(apiError, forType: .string)
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
            if !vimEngine.commandBuffer.isEmpty {
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
        .sheet(isPresented: $showGoToLine) {
            GoToLineSheet(
                lineText: $goToLineText,
                isPresented: $showGoToLine,
                theme: themeManager.currentTheme,
                onGoToLine: { line in
                    goToLine(line)
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .executeQuery)) { _ in
            viewModel.executeQuery()
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
            viewModel.fontSize = CGFloat(configManager.configuration.editor?.effectiveFontSize ?? EditorConfig.defaultFontSize)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fontSizeChanged)) { notification in
            if let newSize = notification.object as? Int {
                viewModel.fontSize = CGFloat(newSize)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cancelQuery)) { _ in
            viewModel.cancelQuery()
        }
        .onReceive(NotificationCenter.default.publisher(for: .executeSelectedQuery)) { notification in
            if let sql = notification.object as? String {
                viewModel.executeSelectedQuery(sql)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .goToLine)) { _ in
            showGoToLine = true
        }
        .onAppear {
            // Load font size from config
            viewModel.fontSize = CGFloat(configManager.configuration.editor?.effectiveFontSize ?? EditorConfig.defaultFontSize)
            // Configure autocomplete
            let mode = configManager.configuration.editor?.autocompleteMode ?? .ruleBased
            let openAIKey = configManager.configuration.editor?.openAIApiKey
            let anthropicKey = configManager.configuration.editor?.anthropicApiKey
            let anthropicModel = configManager.configuration.editor?.anthropicModel?.rawValue
            viewModel.configureAutocomplete(mode: mode, openAIKey: openAIKey, anthropicKey: anthropicKey, anthropicModel: anthropicModel)
        }
    }
    
    // MARK: - Helpers
    
    private func computeLineCol() -> (line: Int, col: Int) {
        let text = viewModel.queryText
        let pos = min(viewModel.cursorPosition, text.count)
        var line = 1
        var col = 1
        var idx = text.startIndex
        var count = 0
        while count < pos && idx < text.endIndex {
            if text[idx] == "\n" {
                line += 1
                col = 1
            } else {
                col += 1
            }
            idx = text.index(after: idx)
            count += 1
        }
        return (line, col)
    }
    
    private func goToLine(_ lineNumber: Int) {
        let text = viewModel.queryText
        var currentLine = 1
        var pos = 0
        for (i, ch) in text.enumerated() {
            if currentLine == lineNumber {
                pos = i
                break
            }
            if ch == "\n" {
                currentLine += 1
            }
            pos = i + 1
        }
        // If the target line is beyond the text, go to the end
        if currentLine < lineNumber {
            pos = text.count
        }
        viewModel.cursorPosition = min(pos, text.count)
        viewModel.cursorPositionAfterCompletion = viewModel.cursorPosition
    }
}

// MARK: - Go To Line Sheet

struct GoToLineSheet: View {
    @Binding var lineText: String
    @Binding var isPresented: Bool
    let theme: Theme
    let onGoToLine: (Int) -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Go to Line")
                .font(.headline)
            
            TextField("Line number", text: $lineText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit {
                    if let line = Int(lineText), line > 0 {
                        onGoToLine(line)
                        isPresented = false
                        lineText = ""
                    }
                }
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                    lineText = ""
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Go") {
                    if let line = Int(lineText), line > 0 {
                        onGoToLine(line)
                        isPresented = false
                        lineText = ""
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Int(lineText) == nil || (Int(lineText) ?? 0) <= 0)
            }
        }
        .padding(24)
        .frame(width: 280)
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
        case .value: return Color.yellow
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
                .lineLimit(1)
            
            if let detail = suggestion.detail {
                Spacer()
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
