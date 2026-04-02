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
                        onToggle: { toggleExpanded(connection.id) },
                        onConnect: { Task { await viewModel.connect(to: connection) } },
                        onDisconnect: { viewModel.disconnect() },
                        onDelete: { viewModel.deleteConnection(connection) }
                    )
                }
            }
            
            if viewModel.isConnected && !viewModel.tables.isEmpty {
                Section("Tables") {
                    ForEach(viewModel.tables.filter { $0.type == .table }) { table in
                        TableRow(table: table, isSelected: viewModel.selectedTable?.id == table.id)
                            .onTapGesture {
                                viewModel.selectTable(table)
                            }
                    }
                }
                
                let views = viewModel.tables.filter { $0.type == .view }
                if !views.isEmpty {
                    Section("Views") {
                        ForEach(views) { view in
                            TableRow(table: view, isSelected: viewModel.selectedTable?.id == view.id)
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
    let onToggle: () -> Void
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onDelete: () -> Void
    
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        HStack {
            Image(systemName: isConnected ? "cylinder.fill" : "cylinder")
                .foregroundColor(isConnected ? .green : .secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.displayName)
                    .font(.body)
                
                Text("\(connection.host):\(connection.port)")
                    .font(.caption)
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
    }
}

struct TableRow: View {
    let table: DatabaseTable
    let isSelected: Bool
    
    var body: some View {
        HStack {
            Image(systemName: table.type == .view ? "eye" : "tablecells")
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading) {
                Text(table.name)
                    .font(.body)
                
                Text(table.schema)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(4)
    }
}

#Preview {
    SidebarView(viewModel: DatabaseViewModel(), showingConnectionSheet: .constant(false))
        .environmentObject(ThemeManager())
}
