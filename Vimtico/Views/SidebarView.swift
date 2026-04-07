import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: DatabaseViewModel
    @Binding var showingConnectionSheet: Bool
    @EnvironmentObject var themeManager: ThemeManager
    @State private var expandedConnections: Set<UUID> = []
    
    var body: some View {
        VStack(spacing: 0) {
            // Connection error banner (shown in sidebar so user sees it immediately)
            if let error = viewModel.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(themeManager.currentTheme.errorColor)
                        .font(.system(size: max(viewModel.fontSize - 2, 10)))
                    Text(error)
                        .font(.system(size: max(viewModel.fontSize - 2, 10), design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.errorColor)
                        .lineLimit(3)
                    Spacer()
                    Button(action: { viewModel.errorMessage = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: max(viewModel.fontSize - 4, 9)))
                            .foregroundColor(themeManager.currentTheme.foregroundColor.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(themeManager.currentTheme.errorColor.opacity(0.15))
            }
            
            ScrollViewReader { proxy in
                List(selection: $viewModel.selectedConnection) {
                    Section("Connections") {
                        ForEach(viewModel.connections) { connection in
                            ConnectionRow(
                                connection: connection,
                                isConnected: viewModel.connectedConnection?.id == connection.id,
                                isExpanded: expandedConnections.contains(connection.id),
                                fontSize: viewModel.fontSize,
                                onToggle: { toggleExpanded(connection.id) },
                                onConnect: { Task { await viewModel.connect(to: connection) } },
                                onDisconnect: { viewModel.disconnect() },
                                onDelete: { viewModel.deleteConnection(connection) }
                            )
                        }
                    }
                    
                    if viewModel.isConnected && !viewModel.tables.isEmpty {
                        let filtered = viewModel.filteredTables
                        let allTables = filtered.filter { $0.type == .table }
                        Section("Tables") {
                            ForEach(Array(allTables.enumerated()), id: \.element.id) { index, table in
                                TableRow(
                                    table: table,
                                    isSelected: viewModel.selectedTable?.id == table.id,
                                    isHighlighted: viewModel.focusedPane == .sidebar && viewModel.selectedTableIndex == index,
                                    fontSize: viewModel.fontSize
                                )
                                .id("sidebar-\(index)")
                                .onTapGesture {
                                    viewModel.selectTable(table)
                                }
                            }
                        }
                        
                        let views = filtered.filter { $0.type == .view }
                        if !views.isEmpty {
                            Section("Views") {
                                ForEach(Array(views.enumerated()), id: \.element.id) { index, view in
                                    let globalIndex = allTables.count + index
                                    TableRow(
                                        table: view,
                                        isSelected: viewModel.selectedTable?.id == view.id,
                                        isHighlighted: viewModel.focusedPane == .sidebar && viewModel.selectedTableIndex == globalIndex,
                                        fontSize: viewModel.fontSize
                                    )
                                    .id("sidebar-\(globalIndex)")
                                    .onTapGesture {
                                        viewModel.selectTable(view)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: viewModel.selectedTableIndex) { _, newIndex in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo("sidebar-\(newIndex)", anchor: .center)
                    }
                }
            }
            
            if viewModel.isSidebarFiltering {
                FilterBar(
                    filterText: viewModel.sidebarFilterText,
                    theme: themeManager.currentTheme,
                    fontSize: max(viewModel.fontSize - 2, 10),
                    isActive: true
                )
            } else if !viewModel.sidebarFilterText.isEmpty {
                FilterBar(
                    filterText: viewModel.sidebarFilterText,
                    theme: themeManager.currentTheme,
                    fontSize: max(viewModel.fontSize - 2, 10),
                    isActive: false
                )
            }
        }
        .frame(minWidth: 200)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { showingConnectionSheet = true }) {
                    Image(systemName: "plus")
                }
                .help("New Connection")
            }
        }
    }
    
    private func toggleExpanded(_ id: UUID) {
        if expandedConnections.contains(id) {
            expandedConnections.remove(id)
        } else {
            expandedConnections.insert(id)
        }
    }
}

struct ConnectionRow: View {
    let connection: DatabaseConnection
    let isConnected: Bool
    let isExpanded: Bool
    let fontSize: CGFloat
    let onToggle: () -> Void
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onDelete: () -> Void
    
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        HStack {
            Image(systemName: isConnected ? "cylinder.fill" : "cylinder")
                .foregroundColor(isConnected ? .green : .secondary)
                .font(.system(size: fontSize))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.displayName)
                    .font(.system(size: fontSize))
                
                Text("\(connection.host):\(connection.port)")
                    .font(.system(size: max(fontSize - 2, 10)))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .contextMenu {
            if isConnected {
                Button("Disconnect") {
                    onDisconnect()
                }
            } else {
                Button("Connect") {
                    onConnect()
                }
            }
            
            Divider()
            
            Button("Delete", role: .destructive) {
                showingDeleteConfirmation = true
            }
        }
        .confirmationDialog("Delete Connection?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete '\(connection.displayName)'?")
        }
        .onTapGesture {
            if !isConnected {
                onConnect()
            }
        }
    }
}

struct TableRow: View {
    let table: DatabaseTable
    let isSelected: Bool
    var isHighlighted: Bool = false
    let fontSize: CGFloat
    
    var body: some View {
        HStack {
            Image(systemName: table.type == .view ? "eye" : "tablecells")
                .foregroundColor(.secondary)
                .font(.system(size: max(fontSize - 2, 10)))
            
            VStack(alignment: .leading) {
                Text(table.name)
                    .font(.system(size: max(fontSize - 2, 10)))
                
                Text(table.schema)
                    .font(.system(size: max(fontSize - 4, 9)))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .background(
            isHighlighted ? Color.accentColor.opacity(0.3) :
            (isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .cornerRadius(4)
    }
}

#Preview {
    SidebarView(viewModel: DatabaseViewModel(), showingConnectionSheet: .constant(false))
        .environmentObject(ThemeManager())
}

/// A small bar showing the current filter text, displayed at the bottom of a pane.
/// When `isActive` is true, the user is actively typing a filter.
/// When `isActive` is false, the filter is applied but the input is dismissed.
struct FilterBar: View {
    let filterText: String
    let theme: Theme
    let fontSize: CGFloat
    var isActive: Bool = true
    
    var body: some View {
        HStack(spacing: 4) {
            Text("/")
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .foregroundColor(theme.keywordColor)
            
            if isActive {
                Text(filterText.isEmpty ? "type to filter..." : filterText)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(filterText.isEmpty ? theme.foregroundColor.opacity(0.4) : theme.foregroundColor)
            } else {
                Text(filterText)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(theme.foregroundColor.opacity(0.7))
            }
            
            Spacer()
            
            if isActive {
                Text("esc to clear")
                    .font(.system(size: max(fontSize - 2, 9), design: .monospaced))
                    .foregroundColor(theme.foregroundColor.opacity(0.3))
            } else {
                Text("/ to edit")
                    .font(.system(size: max(fontSize - 2, 9), design: .monospaced))
                    .foregroundColor(theme.foregroundColor.opacity(0.3))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.secondaryBackgroundColor)
    }
}
