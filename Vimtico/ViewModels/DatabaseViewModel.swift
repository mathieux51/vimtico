import Combine
import Foundation
import SwiftUI

enum FocusPane: String, CaseIterable {
    case sidebar
    case editor
    case results
}

enum ValidationStatus: Equatable {
    case idle
    case validating
    case valid
    case invalid(String)
    case skipped
}

@MainActor
class DatabaseViewModel: ObservableObject {
    @Published var connections: [DatabaseConnection] = []
    @Published var selectedConnection: DatabaseConnection?
    @Published var connectedConnection: DatabaseConnection?
    @Published var tables: [DatabaseTable] = []
    @Published var selectedTable: DatabaseTable?
    @Published var queryText: String = ""
    @Published var queryResult: QueryResult?
    @Published var isConnected: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var vimModeEnabled: Bool = false
    @Published var queryHistory: [QueryHistoryItem] = []
    
    // Shared font size (zoom applies to all panes, default from settings)
    @Published var fontSize: CGFloat = CGFloat(EditorConfig.defaultFontSize)
    
    // Pane focus
    @Published var focusedPane: FocusPane = .editor
    
    // Results navigation
    @Published var selectedResultRow: Int? = nil
    @Published var selectedResultColumn: Int = 0
    
    // Sidebar navigation
    @Published var selectedTableIndex: Int = 0
    
    // Filter (/ search) for sidebar and results
    @Published var sidebarFilterText: String = ""
    @Published var isSidebarFiltering: Bool = false
    @Published var resultsFilterText: String = ""
    @Published var isResultsFiltering: Bool = false
    
    // Selected column in results for schema navigation
    @Published var selectedSchemaRow: Int? = nil
    
    // Yank feedback ("Copied!" toast)
    @Published var showCopiedFeedback: Bool = false
    private var copiedFeedbackTask: Task<Void, Never>?
    
    func flashCopiedFeedback() {
        copiedFeedbackTask?.cancel()
        showCopiedFeedback = true
        copiedFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            showCopiedFeedback = false
        }
    }
    
    // Pane navigation (Ctrl-w sequence)
    var awaitingPaneSwitch: Bool = false
    
    // Global key event monitor handle (for cleanup)
    var eventMonitor: Any? = nil
    
    // Autocomplete
    @Published var autocompleteService = SQLAutocompleteService()
    @Published var autocompleteSuggestions: [SQLCompletion] = []
    @Published var showAutocompleteSuggestions: Bool = false
    @Published var selectedSuggestionIndex: Int = 0
    @Published var cursorPositionAfterCompletion: Int? = nil
    
    // SQL validation
    @Published var validationStatus: ValidationStatus = .idle
    
    // Table schema info (shown when clicking a table in the sidebar)
    @Published var tableInfo: TableSchemaInfo?
    
    private let postgresService = PostgreSQLService()
    private let connectionsKey = "savedConnections"
    private let historyKey = "queryHistory"
    private let lastConnectionKey = "lastConnectedConnectionId"
    private let savedQueryTextKey = "savedQueryText"
    private var runningQueryTask: Task<Void, Never>?
    private var validationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Filtered lists
    
    var filteredTables: [DatabaseTable] {
        guard !sidebarFilterText.isEmpty else { return tables }
        return tables.filter { $0.name.localizedCaseInsensitiveContains(sidebarFilterText) }
    }
    
    /// Returns filtered rows for the current query result or schema info.
    var filteredResultRows: [[String]]? {
        guard let result = queryResult, !result.columns.isEmpty else { return nil }
        let rows = result.rows
        guard !resultsFilterText.isEmpty else { return rows }
        let filter = resultsFilterText.lowercased()
        return rows.filter { row in
            row.contains { $0.lowercased().contains(filter) }
        }
    }
    
    var filteredSchemaRows: [DatabaseColumn]? {
        guard let info = tableInfo else { return nil }
        guard !resultsFilterText.isEmpty else { return info.columns }
        let filter = resultsFilterText.lowercased()
        return info.columns.filter {
            $0.name.lowercased().contains(filter) || $0.dataType.lowercased().contains(filter)
        }
    }
    
    init() {
        // Restore saved query text, or use default placeholder
        if let saved = UserDefaults.standard.string(forKey: savedQueryTextKey), !saved.isEmpty {
            queryText = saved
        } else {
            queryText = "select * from "
        }
        
        loadConnections()
        loadHistory()
        
        // Auto-save query text to UserDefaults (debounced 1s to avoid excessive writes)
        $queryText
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] text in
                guard let self = self else { return }
                UserDefaults.standard.set(text, forKey: self.savedQueryTextKey)
            }
            .store(in: &cancellables)
    }
    
    /// Attempts to auto-connect to the last used database connection.
    func autoConnectIfPossible() {
        guard let idString = UserDefaults.standard.string(forKey: lastConnectionKey),
              let uuid = UUID(uuidString: idString),
              let connection = connections.first(where: { $0.id == uuid }) else {
            return
        }
        Task {
            await connect(to: connection)
        }
    }
    
    // MARK: - Autocomplete
    
    func configureAutocomplete(mode: AutocompleteMode, openAIKey: String?, anthropicKey: String?) {
        autocompleteService.currentMode = mode
        autocompleteService.openAIApiKey = openAIKey
        autocompleteService.anthropicApiKey = anthropicKey
    }
    
    func requestAutocomplete(at cursorPosition: Int) async {
        guard autocompleteService.currentMode != .disabled else {
            showAutocompleteSuggestions = false
            return
        }
        
        let suggestions = await autocompleteService.getCompletions(text: queryText, cursorPosition: cursorPosition)
        autocompleteSuggestions = suggestions
        showAutocompleteSuggestions = !suggestions.isEmpty
        selectedSuggestionIndex = 0
    }
    
    func applyAutocompletion(_ completion: SQLCompletion) {
        // Find the current word to replace
        let currentWord = getCurrentWordForReplacement()
        if !currentWord.isEmpty {
            // Replace the partial word with the completion
            if let range = queryText.range(of: currentWord, options: .backwards) {
                let insertionStart = queryText.distance(from: queryText.startIndex, to: range.lowerBound)
                queryText.replaceSubrange(range, with: completion.text)
                cursorPositionAfterCompletion = insertionStart + completion.text.count
            }
        } else {
            queryText += completion.text
            cursorPositionAfterCompletion = queryText.count
        }
        showAutocompleteSuggestions = false
    }
    
    private func getCurrentWordForReplacement() -> String {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "(),;"))
        let components = queryText.components(separatedBy: separators)
        return components.last ?? ""
    }
    
    func dismissAutocomplete() {
        showAutocompleteSuggestions = false
        autocompleteSuggestions = []
    }
    
    func selectNextSuggestion() {
        if selectedSuggestionIndex < autocompleteSuggestions.count - 1 {
            selectedSuggestionIndex += 1
        }
    }
    
    func selectPreviousSuggestion() {
        if selectedSuggestionIndex > 0 {
            selectedSuggestionIndex -= 1
        }
    }
    
    func applySelectedSuggestion() {
        guard !autocompleteSuggestions.isEmpty,
              selectedSuggestionIndex < autocompleteSuggestions.count else {
            return
        }
        applyAutocompletion(autocompleteSuggestions[selectedSuggestionIndex])
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
            // Remember this connection for auto-connect on next launch
            UserDefaults.standard.set(connection.id.uuidString, forKey: lastConnectionKey)
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
    
    /// Reconnects to the current database (Cmd+R).
    /// Disconnects and then reconnects to the same connection.
    func reconnect() {
        guard let connection = connectedConnection else {
            errorMessage = "No active connection to reconnect"
            return
        }
        Task {
            await postgresService.disconnect()
            isConnected = false
            tables = []
            selectedTable = nil
            queryResult = nil
            tableInfo = nil
            await connect(to: connection)
        }
    }
    
    // MARK: - Query Execution
    
    func executeQuery() {
        guard isConnected, let connection = connectedConnection else {
            errorMessage = "Not connected to a database"
            return
        }
        
        let query = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            errorMessage = "Query is empty"
            return
        }
        
        // Cancel any previously running query
        runningQueryTask?.cancel()
        
        // Clear table info when executing a query
        tableInfo = nil
        isLoading = true
        errorMessage = nil
        
        let startTime = Date()
        
        runningQueryTask = Task {
            do {
                try Task.checkCancellation()
                let result = try await postgresService.executeQuery(query)
                try Task.checkCancellation()
                
                let executionTime = Date().timeIntervalSince(startTime)
                
                queryResult = QueryResult(
                    columns: result.columns,
                    rows: result.rows,
                    rowsAffected: result.rowsAffected,
                    executionTime: executionTime
                )
                
                addToHistory(query: query, connectionId: connection.id, wasSuccessful: true)
            } catch is CancellationError {
                let executionTime = Date().timeIntervalSince(startTime)
                queryResult = QueryResult(
                    executionTime: executionTime,
                    error: "Query cancelled"
                )
            } catch {
                // Don't update UI if the task was cancelled while the query was in flight
                guard !Task.isCancelled else { return }
                
                let executionTime = Date().timeIntervalSince(startTime)
                queryResult = QueryResult(
                    executionTime: executionTime,
                    error: error.localizedDescription
                )
                addToHistory(query: query, connectionId: connection.id, wasSuccessful: false)
            }
            
            isLoading = false
            runningQueryTask = nil
        }
    }
    
    func cancelQuery() {
        guard isLoading, let task = runningQueryTask else { return }
        task.cancel()
        runningQueryTask = nil
        isLoading = false
        queryResult = QueryResult(
            executionTime: 0,
            error: "Query cancelled"
        )
    }
    
    func selectTable(_ table: DatabaseTable) {
        selectedTable = table
        queryResult = nil
        isLoading = true
        
        Task {
            let columns = await fetchColumns(for: table)
            let stats = await postgresService.fetchTableStats(for: table)
            
            tableInfo = TableSchemaInfo(
                table: table,
                columns: columns,
                approximateRowCount: stats.rowCount,
                tableSize: stats.tableSize
            )
            isLoading = false
        }
    }
    
    /// Executes only the provided SQL text (used for visual mode selection).
    func executeSelectedQuery(_ sql: String) {
        guard isConnected, let connection = connectedConnection else {
            errorMessage = "Not connected to a database"
            return
        }
        
        let query = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        
        runningQueryTask?.cancel()
        tableInfo = nil
        isLoading = true
        errorMessage = nil
        
        let startTime = Date()
        
        runningQueryTask = Task {
            do {
                try Task.checkCancellation()
                let result = try await postgresService.executeQuery(query)
                try Task.checkCancellation()
                
                let executionTime = Date().timeIntervalSince(startTime)
                
                queryResult = QueryResult(
                    columns: result.columns,
                    rows: result.rows,
                    rowsAffected: result.rowsAffected,
                    executionTime: executionTime
                )
                
                addToHistory(query: query, connectionId: connection.id, wasSuccessful: true)
            } catch is CancellationError {
                let executionTime = Date().timeIntervalSince(startTime)
                queryResult = QueryResult(
                    executionTime: executionTime,
                    error: "Query cancelled"
                )
            } catch {
                guard !Task.isCancelled else { return }
                
                let executionTime = Date().timeIntervalSince(startTime)
                queryResult = QueryResult(
                    executionTime: executionTime,
                    error: error.localizedDescription
                )
                addToHistory(query: query, connectionId: connection.id, wasSuccessful: false)
            }
            
            isLoading = false
            runningQueryTask = nil
        }
    }
    
    // MARK: - SQL Validation
    
    /// Schedules a debounced syntax validation of the current query using EXPLAIN.
    func scheduleValidation() {
        validationTask?.cancel()
        
        guard isConnected else {
            validationStatus = .skipped
            return
        }
        
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationStatus = .idle
            return
        }
        
        validationStatus = .validating
        
        let query = queryText
        validationTask = Task {
            // Debounce: wait 800ms after last keystroke
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            
            let error = await postgresService.validateQuery(query)
            guard !Task.isCancelled else { return }
            
            if let error = error {
                validationStatus = .invalid(error)
            } else {
                validationStatus = .valid
            }
        }
    }
    
    // MARK: - Table Loading
    
    func loadTables() async {
        guard isConnected else { return }
        
        do {
            tables = try await postgresService.fetchTables()
            
            // Update autocomplete service with table names
            autocompleteService.updateTables(tables.map { $0.name })
            autocompleteService.updateSchemas(Array(Set(tables.map { $0.schema })))
            
            // Load columns for each table (for autocomplete)
            for table in tables.prefix(20) { // Limit to first 20 tables for performance
                let columns = try await postgresService.fetchColumns(for: table)
                autocompleteService.updateColumns(for: table.name, columns: columns.map { $0.name })
            }
        } catch {
            errorMessage = "Failed to load tables: \(error.localizedDescription)"
        }
    }
    
    func fetchColumns(for table: DatabaseTable) async -> [DatabaseColumn] {
        guard isConnected else { return [] }
        
        do {
            let columns = try await postgresService.fetchColumns(for: table)
            // Update autocomplete cache
            autocompleteService.updateColumns(for: table.name, columns: columns.map { $0.name })
            return columns
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
