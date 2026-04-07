import Combine
import Foundation
import SwiftUI

enum FocusPane: String, CaseIterable {
    case sidebar
    case editor
    case results
}

enum ResultsVimMode: String {
    case normal = "NORMAL"
    case visualLine = "V-LINE"
    case visualBlock = "V-BLOCK"
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
    @Published var vimModeEnabled: Bool = true
    @Published var queryHistory: [QueryHistoryItem] = []
    
    // Shared font size (zoom applies to all panes, default from settings)
    @Published var fontSize: CGFloat = CGFloat(EditorConfig.defaultFontSize)
    
    // Pane focus
    @Published var focusedPane: FocusPane = .editor
    
    // Results navigation
    @Published var selectedResultRow: Int? = nil
    @Published var selectedResultColumn: Int = 0
    
    // Results visual mode (V for visual line, Ctrl+V for visual block)
    @Published var resultsVimMode: ResultsVimMode = .normal
    @Published var visualAnchorRow: Int? = nil
    @Published var visualAnchorColumn: Int = 0
    
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
    
    // MARK: - Visual Selection Helpers
    
    /// Row range covered by the visual selection (visual line or visual block).
    var visualRowRange: ClosedRange<Int>? {
        guard resultsVimMode != .normal,
              let anchor = visualAnchorRow,
              let current = selectedResultRow else { return nil }
        return min(anchor, current)...max(anchor, current)
    }
    
    /// Column range covered by the visual block selection. Nil for visual line (all columns).
    var visualColumnRange: ClosedRange<Int>? {
        guard resultsVimMode == .visualBlock,
              visualAnchorRow != nil else { return nil }
        return min(visualAnchorColumn, selectedResultColumn)...max(visualAnchorColumn, selectedResultColumn)
    }
    
    /// Exit visual mode, keeping cursor at current position.
    func exitResultsVisualMode() {
        resultsVimMode = .normal
        visualAnchorRow = nil
        visualAnchorColumn = 0
    }
    
    /// Enter visual line mode from current cursor position.
    func enterVisualLineMode() {
        let row = selectedResultRow ?? 0
        selectedResultRow = row
        visualAnchorRow = row
        resultsVimMode = .visualLine
    }
    
    /// Enter visual block mode from current cursor position.
    func enterVisualBlockMode() {
        let row = selectedResultRow ?? 0
        selectedResultRow = row
        visualAnchorRow = row
        visualAnchorColumn = selectedResultColumn
        resultsVimMode = .visualBlock
    }
    
    /// Build tab-separated text for the current visual selection.
    func yankVisualSelection(rows: [[String]], columns: [String]) -> String? {
        guard let rowRange = visualRowRange else { return nil }
        
        var lines: [String] = []
        
        switch resultsVimMode {
        case .visualLine:
            // Copy all columns for each selected row, with header
            lines.append(columns.joined(separator: "\t"))
            for r in rowRange {
                guard r < rows.count else { continue }
                lines.append(rows[r].joined(separator: "\t"))
            }
        case .visualBlock:
            guard let colRange = visualColumnRange else { return nil }
            // Copy only the selected columns for each selected row, with header
            let headerSlice = colRange.compactMap { c in c < columns.count ? columns[c] : nil }
            lines.append(headerSlice.joined(separator: "\t"))
            for r in rowRange {
                guard r < rows.count else { continue }
                let slice = colRange.compactMap { c in c < rows[r].count ? rows[r][c] : nil }
                lines.append(slice.joined(separator: "\t"))
            }
        case .normal:
            return nil
        }
        
        return lines.joined(separator: "\n")
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
    @Published var cursorPosition: Int = 0
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
    private var autocompleteTask: Task<Void, Never>?
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
              let uuid = UUID(uuidString: idString) else {
            return
        }
        guard let connection = connections.first(where: { $0.id == uuid }) else {
            // Saved connection was deleted. Clear the stale reference.
            UserDefaults.standard.removeObject(forKey: lastConnectionKey)
            errorMessage = "Auto-connect failed: saved connection no longer exists"
            return
        }
        Task {
            await connect(to: connection)
        }
    }
    
    // MARK: - Autocomplete
    
    func configureAutocomplete(mode: AutocompleteMode, openAIKey: String?, anthropicKey: String?, anthropicModel: String? = nil) {
        autocompleteService.currentMode = mode
        autocompleteService.openAIApiKey = openAIKey
        autocompleteService.anthropicApiKey = anthropicKey
        if let model = anthropicModel {
            autocompleteService.anthropicModel = model
        }
        // Fetch available models when Anthropic is configured with an API key
        if mode == .anthropic, let key = anthropicKey, !key.isEmpty {
            Task {
                await autocompleteService.fetchAnthropicModels()
            }
        }
    }
    
    func requestAutocomplete(at cursorPosition: Int) {
        guard autocompleteService.currentMode != .disabled else {
            showAutocompleteSuggestions = false
            return
        }
        
        // Cancel any in-flight autocomplete request
        autocompleteTask?.cancel()
        
        let useDebounce = autocompleteService.currentMode.usesAPI
        
        autocompleteTask = Task { @MainActor in
            // Debounce API calls to avoid hammering on every keystroke
            if useDebounce {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                guard !Task.isCancelled else { return }
            }
            
            let suggestions = await autocompleteService.getCompletions(text: queryText, cursorPosition: cursorPosition)
            guard !Task.isCancelled else { return }
            autocompleteSuggestions = suggestions
            showAutocompleteSuggestions = !suggestions.isEmpty
            selectedSuggestionIndex = 0
        }
    }
    
    func applyAutocompletion(_ completion: SQLCompletion) {
        let pos = min(cursorPosition, queryText.count)
        
        // Check if cursor is on a comment line (-- ...)
        // If so, insert the completion on the next line instead of replacing inline
        if isOnCommentLine(position: pos) {
            let lineEnd = findEndOfLine(position: pos)
            let insertIdx = queryText.index(queryText.startIndex, offsetBy: lineEnd)
            let textToInsert = "\n" + completion.text
            queryText.insert(contentsOf: textToInsert, at: insertIdx)
            cursorPositionAfterCompletion = lineEnd + textToInsert.count
            showAutocompleteSuggestions = false
            return
        }
        
        // Find the current word to replace based on actual cursor position
        let currentWord = getCurrentWordAtCursor(position: pos)
        if !currentWord.isEmpty {
            let completionLower = completion.text.lowercased()
            let wordLower = currentWord.lowercased()
            let wordStart = pos - currentWord.count
            
            if completionLower.hasPrefix(wordLower) {
                // Completion includes the current word (e.g. word="selec", completion="select * from items")
                // Replace the partial word with the full completion
                let startIdx = queryText.index(queryText.startIndex, offsetBy: wordStart)
                let endIdx = queryText.index(queryText.startIndex, offsetBy: pos)
                queryText.replaceSubrange(startIdx..<endIdx, with: completion.text)
                cursorPositionAfterCompletion = wordStart + completion.text.count
            } else {
                // Completion is a suffix/continuation (e.g. word="selec", completion="t * from items")
                // Insert at cursor without removing the current word
                let insertIdx = queryText.index(queryText.startIndex, offsetBy: pos)
                queryText.insert(contentsOf: completion.text, at: insertIdx)
                cursorPositionAfterCompletion = pos + completion.text.count
            }
        } else {
            // Insert at cursor position
            let insertIdx = queryText.index(queryText.startIndex, offsetBy: pos)
            queryText.insert(contentsOf: completion.text, at: insertIdx)
            cursorPositionAfterCompletion = pos + completion.text.count
        }
        showAutocompleteSuggestions = false
    }
    
    /// Returns true if the cursor is on a line that starts with `--`
    private func isOnCommentLine(position: Int) -> Bool {
        let pos = min(position, queryText.count)
        let textBefore = String(queryText.prefix(pos))
        let lines = textBefore.components(separatedBy: "\n")
        guard let currentLine = lines.last else { return false }
        return currentLine.trimmingCharacters(in: .whitespaces).hasPrefix("--")
    }
    
    /// Finds the end-of-line offset for the line containing the given position
    private func findEndOfLine(position: Int) -> Int {
        let pos = min(position, queryText.count)
        var idx = queryText.index(queryText.startIndex, offsetBy: pos)
        while idx < queryText.endIndex {
            if queryText[idx] == "\n" {
                break
            }
            idx = queryText.index(after: idx)
        }
        return queryText.distance(from: queryText.startIndex, to: idx)
    }
    
    private func getCurrentWordAtCursor(position: Int) -> String {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "(),;"))
        let pos = min(position, queryText.count)
        guard pos > 0 else { return "" }
        
        // Walk backwards from cursor to find word start
        var startIdx = queryText.index(queryText.startIndex, offsetBy: pos)
        while startIdx > queryText.startIndex {
            let prevIdx = queryText.index(before: startIdx)
            let ch = queryText[prevIdx]
            if ch.unicodeScalars.allSatisfy({ separators.contains($0) }) {
                break
            }
            startIdx = prevIdx
        }
        
        let endIdx = queryText.index(queryText.startIndex, offsetBy: pos)
        return String(queryText[startIdx..<endIdx])
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
                autocompleteService.recordQuery(query, connectionId: connection.id)
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
            var stats: (rowCount: Int?, tableSize: String?) = (nil, nil)
            do {
                stats = try await postgresService.fetchTableStats(for: table)
            } catch {
                errorMessage = "Failed to load table stats: \(error.localizedDescription)"
            }
            
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
                autocompleteService.recordQuery(query, connectionId: connection.id)
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
            
            // Load columns for all tables (rich metadata for smart autocomplete)
            var columnsByTable: [String: [DatabaseColumn]] = [:]
            for table in tables {
                let columns = try await postgresService.fetchColumns(for: table)
                columnsByTable[table.name] = columns
            }
            
            // Feed the smart engine with full schema + rich column data
            autocompleteService.updateSchemaFromDatabase(tables: tables, columnsByTable: columnsByTable)
            
            // Wire up the fetchValues callback for value-based completions
            let service = postgresService
            autocompleteService.smartEngine.fetchValues = { tableName, columnName, filter, limit in
                await service.fetchDistinctValues(table: tableName, column: columnName, filter: filter, limit: limit)
            }
        } catch {
            errorMessage = "Failed to load tables: \(error.localizedDescription)"
        }
    }
    
    func fetchColumns(for table: DatabaseTable) async -> [DatabaseColumn] {
        guard isConnected else { return [] }
        
        do {
            let columns = try await postgresService.fetchColumns(for: table)
            // Update autocomplete cache with rich column metadata
            autocompleteService.updateRichColumns(for: table.name, columns: columns)
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
        guard let data = UserDefaults.standard.data(forKey: connectionsKey) else {
            return
        }
        do {
            connections = try JSONDecoder().decode([DatabaseConnection].self, from: data)
        } catch {
            errorMessage = "Failed to load saved connections: \(error.localizedDescription)"
        }
    }
    
    private func persistConnections() {
        do {
            let encoded = try JSONEncoder().encode(connections)
            UserDefaults.standard.set(encoded, forKey: connectionsKey)
        } catch {
            errorMessage = "Failed to save connections: \(error.localizedDescription)"
        }
    }
    
    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey) else {
            return
        }
        do {
            queryHistory = try JSONDecoder().decode([QueryHistoryItem].self, from: data)
        } catch {
            errorMessage = "Failed to load query history: \(error.localizedDescription)"
        }
    }
    
    private func persistHistory() {
        do {
            let encoded = try JSONEncoder().encode(queryHistory)
            UserDefaults.standard.set(encoded, forKey: historyKey)
        } catch {
            errorMessage = "Failed to save query history: \(error.localizedDescription)"
        }
    }
}
