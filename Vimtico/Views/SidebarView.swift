import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: DatabaseViewModel
    @Binding var showingConnectionSheet: Bool
    @EnvironmentObject var themeManager: ThemeManager
    @State private var expandedConnections: Set<UUID> = []
    
    var body: some View {
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
                let allTables = viewModel.tables.filter { $0.type == .table }
                Section("Tables") {
                    ForEach(Array(allTables.enumerated()), id: \.element.id) { index, table in
                        TableRow(
                            table: table,
                            isSelected: viewModel.selectedTable?.id == table.id,
                            isHighlighted: viewModel.focusedPane == .sidebar && viewModel.selectedTableIndex == index,
                            fontSize: viewModel.fontSize
                        )
                        .onTapGesture {
                            viewModel.selectTable(table)
                        }
                    }
                }
                
                let views = viewModel.tables.filter { $0.type == .view }
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
                            .onTapGesture {
                                viewModel.selectTable(view)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
                .font(.system(size: fontSize))
            
            VStack(alignment: .leading) {
                Text(table.name)
                    .font(.system(size: fontSize))
                
                Text(table.schema)
                    .font(.system(size: max(fontSize - 2, 10)))
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
