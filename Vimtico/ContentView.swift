import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DatabaseViewModel()
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var configManager: ConfigurationManager
    @State private var showingConnectionSheet = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var editorHeight: CGFloat = 250
    @State private var showingKeybindings = false
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                viewModel: viewModel,
                showingConnectionSheet: $showingConnectionSheet
            )
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                viewModel.focusedPane = .sidebar
                viewModel.dismissAutocomplete()
                Self.resignEditorFocus()
            })
        } detail: {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    QueryEditorView(viewModel: viewModel)
                        .frame(height: editorHeight)
                        .overlay(
                            focusBorder(for: .editor),
                            alignment: .bottom
                        )
                    
                    ResizableDivider(totalHeight: geo.size.height, topHeight: $editorHeight)
                    
                    ResultsTableView(viewModel: viewModel)
                        .frame(minHeight: 100)
                        .overlay(
                            focusBorder(for: .results),
                            alignment: .top
                        )
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded {
                            viewModel.focusedPane = .results
                            viewModel.dismissAutocomplete()
                            Self.resignEditorFocus()
                        })
                }
            }
        }
        .background(themeManager.currentTheme.backgroundColor)
        .sheet(isPresented: $showingConnectionSheet) {
            ConnectionFormView(viewModel: viewModel, isPresented: $showingConnectionSheet)
        }
        .sheet(isPresented: $showingKeybindings) {
            KeybindingsView(isPresented: $showingKeybindings)
                .environmentObject(themeManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newConnection)) { _ in
            showingConnectionSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showKeybindings)) { _ in
            showingKeybindings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .reconnect)) { _ in
            viewModel.reconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vimModeChanged)) { notification in
            if let enabled = notification.object as? Bool {
                viewModel.vimModeEnabled = enabled
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusPane)) { notification in
            if let pane = notification.object as? FocusPane {
                viewModel.focusedPane = pane
                viewModel.awaitingPaneSwitch = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editorBecameFirstResponder)) { _ in
            viewModel.focusedPane = .editor
        }
        .onAppear {
            if configManager.configuration.vimMode?.enabled ?? true {
                viewModel.vimModeEnabled = true
            }
            // Auto-connect to last used database
            viewModel.autoConnectIfPossible()
            viewModel.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                return self.handleGlobalKeyEvent(event)
            }
        }
        .onDisappear {
            if let monitor = viewModel.eventMonitor {
                NSEvent.removeMonitor(monitor)
                viewModel.eventMonitor = nil
            }
        }
    }
    
    @ViewBuilder
    private func focusBorder(for pane: FocusPane) -> some View {
        if viewModel.focusedPane == pane {
            Rectangle()
                .fill(themeManager.currentTheme.vimNormalModeColor)
                .frame(height: 2)
        }
    }
    
    private func handleGlobalKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Esc cancels running query regardless of vim mode or focused pane
        if event.keyCode == 53 && viewModel.isLoading {
            viewModel.cancelQuery()
            // Don't consume: let it also flow to vim engine for mode transition
        }
        
        // Pane navigation (Ctrl-w + h/j/k/l) works regardless of vim mode
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
            && event.charactersIgnoringModifiers == "w" {
            viewModel.awaitingPaneSwitch = true
            return nil
        }
        
        if viewModel.awaitingPaneSwitch {
            viewModel.awaitingPaneSwitch = false
            switch event.charactersIgnoringModifiers {
            case "h":
                viewModel.focusedPane = .sidebar
                viewModel.dismissAutocomplete()
                Self.resignEditorFocus()
                return nil
            case "j":
                viewModel.focusedPane = .results
                viewModel.dismissAutocomplete()
                Self.resignEditorFocus()
                return nil
            case "k":
                viewModel.focusedPane = .editor
                Self.restoreEditorFocus()
                return nil
            case "l":
                if viewModel.focusedPane == .sidebar {
                    viewModel.focusedPane = .editor
                    Self.restoreEditorFocus()
                } else {
                    viewModel.focusedPane = .results
                    viewModel.dismissAutocomplete()
                    Self.resignEditorFocus()
                }
                return nil
            default:
                return event
            }
        }
        
        // Pane-specific key handling (vim navigation works in all non-editor panes)
        switch viewModel.focusedPane {
        case .results:
            return handleResultsPaneKey(event)
        case .sidebar:
            return handleSidebarPaneKey(event)
        case .editor:
            return event
        }
    }
    
    private func handleResultsPaneKey(_ event: NSEvent) -> NSEvent? {
        // Let command/control shortcuts through to the system
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) { return event }
        
        guard let chars = event.charactersIgnoringModifiers else { return nil }
        
        if let result = viewModel.queryResult, !result.columns.isEmpty {
            let rowCount = result.rows.count
            if rowCount > 0 {
                switch chars {
                case "j":
                    let current = viewModel.selectedResultRow ?? -1
                    viewModel.selectedResultRow = min(current + 1, rowCount - 1)
                case "k":
                    let current = viewModel.selectedResultRow ?? 0
                    viewModel.selectedResultRow = max(current - 1, 0)
                case "g":
                    viewModel.selectedResultRow = 0
                case "G":
                    viewModel.selectedResultRow = rowCount - 1
                case "y":
                    if let row = viewModel.selectedResultRow, row < result.rows.count {
                        let rowText = result.rows[row].joined(separator: "\t")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(rowText, forType: .string)
                    }
                default:
                    break
                }
            }
        }
        // Consume all non-modifier keystrokes to prevent typing in editor
        return nil
    }
    
    private func handleSidebarPaneKey(_ event: NSEvent) -> NSEvent? {
        // Let command/control shortcuts through to the system
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) { return event }
        
        guard let chars = event.charactersIgnoringModifiers else { return nil }
        
        let tableCount = viewModel.tables.count
        if tableCount > 0 {
            switch chars {
            case "j":
                viewModel.selectedTableIndex = min(viewModel.selectedTableIndex + 1, tableCount - 1)
            case "k":
                viewModel.selectedTableIndex = max(viewModel.selectedTableIndex - 1, 0)
            case "g":
                viewModel.selectedTableIndex = 0
            case "G":
                viewModel.selectedTableIndex = tableCount - 1
            case "\r":
                if viewModel.selectedTableIndex < tableCount {
                    let table = viewModel.tables[viewModel.selectedTableIndex]
                    viewModel.selectTable(table)
                }
            default:
                break
            }
        }
        // Consume all non-modifier keystrokes to prevent typing in editor
        return nil
    }
    
    // MARK: - Focus Management
    
    private static func resignEditorFocus() {
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
    
    private static func restoreEditorFocus() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow,
                  let contentView = window.contentView else { return }
            if let textView = findTextView(in: contentView) {
                window.makeFirstResponder(textView)
            }
        }
    }
    
    private static func findTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? VimEnabledTextView { return tv }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }
}

/// A draggable divider between editor and results panes.
struct ResizableDivider: View {
    let totalHeight: CGFloat
    @Binding var topHeight: CGFloat
    @State private var isDragging = false
    @State private var dragStartHeight: CGFloat? = nil
    
    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color.gray.opacity(0.4))
            .frame(height: isDragging ? 4 : 2)
            .contentShape(Rectangle().size(width: 10000, height: 16))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDragging = true
                        if dragStartHeight == nil {
                            dragStartHeight = topHeight
                        }
                        let newHeight = dragStartHeight! + value.translation.height
                        let minTop: CGFloat = 100
                        let minBottom: CGFloat = 100
                        topHeight = min(max(newHeight, minTop), totalHeight - minBottom)
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragStartHeight = nil
                    }
            )
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager())
        .environmentObject(ConfigurationManager())
}
