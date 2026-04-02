import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DatabaseViewModel()
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var configManager: ConfigurationManager
    @State private var showingConnectionSheet = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var editorHeight: CGFloat = 250
    @State private var awaitingPaneSwitch = false
    @State private var showingKeybindings = false
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                viewModel: viewModel,
                showingConnectionSheet: $showingConnectionSheet
            )
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
        .onReceive(NotificationCenter.default.publisher(for: .focusPane)) { notification in
            if let pane = notification.object as? FocusPane {
                viewModel.focusedPane = pane
                awaitingPaneSwitch = false
            }
        }
        .onAppear {
            if configManager.configuration.vimMode?.enabled ?? false {
                viewModel.vimModeEnabled = true
            }
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                return self.handleGlobalKeyEvent(event)
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
        guard viewModel.vimModeEnabled else { return event }
        
        // Ctrl-w starts pane switch sequence
        if event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "w" {
            awaitingPaneSwitch = true
            return nil
        }
        
        if awaitingPaneSwitch {
            awaitingPaneSwitch = false
            switch event.charactersIgnoringModifiers {
            case "h":
                viewModel.focusedPane = .sidebar
                return nil
            case "j":
                // Move down: editor -> results, sidebar -> results
                if viewModel.focusedPane == .editor {
                    viewModel.focusedPane = .results
                } else {
                    viewModel.focusedPane = .results
                }
                return nil
            case "k":
                // Move up: results -> editor, sidebar -> editor
                if viewModel.focusedPane == .results {
                    viewModel.focusedPane = .editor
                } else {
                    viewModel.focusedPane = .editor
                }
                return nil
            case "l":
                // Move right: sidebar -> editor
                if viewModel.focusedPane == .sidebar {
                    viewModel.focusedPane = .editor
                } else {
                    viewModel.focusedPane = .results
                }
                return nil
            default:
                return event
            }
        }
        
        // Pane-specific key handling
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
        guard let chars = event.charactersIgnoringModifiers else { return event }
        guard let result = viewModel.queryResult, !result.columns.isEmpty else { return event }
        
        let rowCount = result.rows.count
        guard rowCount > 0 else { return event }
        
        switch chars {
        case "j":
            let current = viewModel.selectedResultRow ?? -1
            viewModel.selectedResultRow = min(current + 1, rowCount - 1)
            return nil
        case "k":
            let current = viewModel.selectedResultRow ?? 0
            viewModel.selectedResultRow = max(current - 1, 0)
            return nil
        case "g":
            // gg -> go to first row (simplified: single g goes to top)
            viewModel.selectedResultRow = 0
            return nil
        case "G":
            viewModel.selectedResultRow = rowCount - 1
            return nil
        case "y":
            // Yank (copy) the selected row
            if let row = viewModel.selectedResultRow, row < result.rows.count {
                let rowText = result.rows[row].joined(separator: "\t")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rowText, forType: .string)
            }
            return nil
        default:
            return event
        }
    }
    
    private func handleSidebarPaneKey(_ event: NSEvent) -> NSEvent? {
        guard let chars = event.charactersIgnoringModifiers else { return event }
        
        let tableCount = viewModel.tables.count
        guard tableCount > 0 else { return event }
        
        switch chars {
        case "j":
            viewModel.selectedTableIndex = min(viewModel.selectedTableIndex + 1, tableCount - 1)
            return nil
        case "k":
            viewModel.selectedTableIndex = max(viewModel.selectedTableIndex - 1, 0)
            return nil
        case "g":
            viewModel.selectedTableIndex = 0
            return nil
        case "G":
            viewModel.selectedTableIndex = tableCount - 1
            return nil
        case "\r":
            // Enter: show schema info for the selected table
            if viewModel.selectedTableIndex < tableCount {
                let table = viewModel.tables[viewModel.selectedTableIndex]
                viewModel.selectTable(table)
            }
            return nil
        default:
            return event
        }
    }
}

/// A draggable divider between editor and results panes.
struct ResizableDivider: View {
    let totalHeight: CGFloat
    @Binding var topHeight: CGFloat
    @State private var isDragging = false
    
    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color.gray.opacity(0.4))
            .frame(height: isDragging ? 3 : 1)
            .contentShape(Rectangle().size(width: 10000, height: 12))
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
                        let newHeight = topHeight + value.translation.height
                        let minTop: CGFloat = 100
                        let minBottom: CGFloat = 100
                        topHeight = min(max(newHeight, minTop), totalHeight - minBottom)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager())
        .environmentObject(ConfigurationManager())
}
