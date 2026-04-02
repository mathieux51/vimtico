import Foundation
import SwiftUI

@MainActor
class DatabaseViewModel: ObservableObject {
    @Published var connections: [DatabaseConnection] = []
    @Published var selectedConnection: DatabaseConnection?
    @Published var connectedConnection: DatabaseConnection?
    @Published var tables: [DatabaseTable] = []
    @Published var selectedTable: DatabaseTable?
    @Published var queryText: String = "SELECT * FROM "
    @Published var queryResult: QueryResult?
    @Published var isConnected: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var vimModeEnabled: Bool = false
    @Published var queryHistory: [QueryHistoryItem] = []
    
    private let postgresService = PostgreSQLService()
    private let connectionsKey = "savedConnections"
    private let historyKey = "queryHistory"
    
    init() {
        loadConnections()
        loadHistory()
    }
    
    // MARK: - Connection Management
    
    func saveConnection(_ connection: DatabaseConnection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        persistConnections()
    }
    
    func deleteConnection(_ connection: DatabaseConnection) {
        connections.removeAll { $0.id == connection.id }
        if selectedConnection?.id == connection.id {
            selectedConnection = nil
        }
        if connectedConnection?.id == connection.id {
            disconnect()
        }
        persistConnections()
    }
    
    func connect(to connection: DatabaseConnection) async {
        isLoading = true
        errorMessage = nil
        
        do {
            try await postgresService.connect(to: connection)
            connectedConnection = connection
            isConnected = true
            await loadTables()
        } catch {
            errorMessage = error.localizedDescription
            isConnected = false
        }
        
        isLoading = false
    }
    
    func disconnect() {
        Task {
            await postgresService.disconnect()
        }
        connectedConnection = nil
        isConnected = false
        tables = []
        selectedTable = nil
        queryResult = nil
    }
    
    // MARK: - Query Execution
    
    func executeQuery() async {
        guard isConnected, let connection = connectedConnection else {
            errorMessage = "Not connected to a database"
            return
        }
        
        let query = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            errorMessage = "Query is empty"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        let startTime = Date()
        
        do {
            let result = try await postgresService.executeQuery(query)
            let executionTime = Date().timeIntervalSince(startTime)
            
            queryResult = QueryResult(
                columns: result.columns,
                rows: result.rows,
                rowsAffected: result.rowsAffected,
                executionTime: executionTime
            )
            
            addToHistory(query: query, connectionId: connection.id, wasSuccessful: true)
        } catch {
            let executionTime = Date().timeIntervalSince(startTime)
            queryResult = QueryResult(
                executionTime: executionTime,
                error: error.localizedDescription
            )
            addToHistory(query: query, connectionId: connection.id, wasSuccessful: false)
        }
        
        isLoading = false
    }
    
    func selectTable(_ table: DatabaseTable) {
        selectedTable = table
        queryText = "SELECT * FROM \(table.fullName) LIMIT 100;"
    }
    
    // MARK: - Table Loading
    
    func loadTables() async {
        guard isConnected else { return }
        
        do {
            tables = try await postgresService.fetchTables()
        } catch {
            errorMessage = "Failed to load tables: \(error.localizedDescription)"
        }
    }
    
    func fetchColumns(for table: DatabaseTable) async -> [DatabaseColumn] {
        guard isConnected else { return [] }
        
        do {
            return try await postgresService.fetchColumns(for: table)
        } catch {
            errorMessage = "Failed to load columns: \(error.localizedDescription)"
            return []
        }
    }
    
    // MARK: - History Management
    
    private func addToHistory(query: String, connectionId: UUID, wasSuccessful: Bool) {
        let item = QueryHistoryItem(query: query, connectionId: connectionId, wasSuccessful: wasSuccessful)
        queryHistory.insert(item, at: 0)
        
        // Keep only last 100 items
        if queryHistory.count > 100 {
            queryHistory = Array(queryHistory.prefix(100))
        }
        
        persistHistory()
    }
    
    func clearHistory() {
        queryHistory = []
        persistHistory()
    }
    
    // MARK: - Persistence
    
    private func loadConnections() {
        guard let data = UserDefaults.standard.data(forKey: connectionsKey),
              let decoded = try? JSONDecoder().decode([DatabaseConnection].self, from: data) else {
            return
        }
        connections = decoded
    }
    
    private func persistConnections() {
        guard let encoded = try? JSONEncoder().encode(connections) else { return }
        UserDefaults.standard.set(encoded, forKey: connectionsKey)
    }
    
    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([QueryHistoryItem].self, from: data) else {
            return
        }
        queryHistory = decoded
    }
    
    private func persistHistory() {
        guard let encoded = try? JSONEncoder().encode(queryHistory) else { return }
        UserDefaults.standard.set(encoded, forKey: historyKey)
    }
}
