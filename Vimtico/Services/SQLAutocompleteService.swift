import Foundation

/// SQL Autocomplete service that orchestrates completions across all layers.
/// Delegates schema-aware completions to SmartAutocompleteEngine.
/// Handles API-based completions (OpenAI, Anthropic) and merges with smart results.
class SQLAutocompleteService: ObservableObject {
    
    @Published var isLoading: Bool = false
    @Published var currentMode: AutocompleteMode = .ruleBased
    @Published var lastAPIError: String?
    @Published var availableAnthropicModels: [AnthropicModelInfo] = []
    @Published var isFetchingModels: Bool = false
    
    // API Keys
    var openAIApiKey: String?
    var anthropicApiKey: String?
    var anthropicModel: String = AnthropicModel.haiku.rawValue
    
    /// The smart engine that handles schema-aware, value-lookup, and history completions
    let smartEngine = SmartAutocompleteEngine()
    
    // MARK: - Schema Cache (delegated to smart engine)
    
    /// Update the schema cache with table names (legacy compat + engine update)
    func updateTables(_ tables: [String]) {
        // Legacy: still used for API schema context fallback
    }
    
    /// Update the schema cache with schema names
    func updateSchemas(_ schemas: [String]) {
        // Handled by smartEngine.updateSchema
    }
    
    /// Add columns for a table to cache (legacy, name-only)
    func updateColumns(for tableName: String, columns: [String]) {
        // Legacy: prefer updateRichColumns which passes full ColumnInfo
    }
    
    /// Update schema with rich metadata (tables + typed columns).
    /// This is the preferred path that feeds the smart engine.
    func updateSchemaFromDatabase(tables: [DatabaseTable], columnsByTable: [String: [DatabaseColumn]]) {
        let tableTuples = tables.map { (name: $0.name, schema: $0.schema, type: $0.type.rawValue) }
        var richColumns: [String: [ColumnInfo]] = [:]
        for (table, cols) in columnsByTable {
            richColumns[table] = cols.map { col in
                ColumnInfo(
                    name: col.name,
                    dataType: col.dataType,
                    isNullable: col.isNullable,
                    defaultValue: col.defaultValue,
                    isPrimaryKey: col.isPrimaryKey
                )
            }
        }
        smartEngine.updateSchema(tables: tableTuples, columns: richColumns)
    }
    
    /// Update columns for a single table with rich metadata
    func updateRichColumns(for tableName: String, columns: [DatabaseColumn]) {
        smartEngine.updateColumns(for: tableName, columns: columns.map { col in
            ColumnInfo(
                name: col.name,
                dataType: col.dataType,
                isNullable: col.isNullable,
                defaultValue: col.defaultValue,
                isPrimaryKey: col.isPrimaryKey
            )
        })
    }
    
    /// Record a query for history-based predictions
    func recordQuery(_ sql: String, connectionId: UUID?) {
        smartEngine.recordQuery(sql, connectionId: connectionId)
    }
    
    // MARK: - Get Completions
    
    /// Get completions based on current mode.
    /// For rule-based mode: uses SmartAutocompleteEngine directly (fast, sync).
    /// For API modes: calls API with rich schema context, merges with smart engine results.
    func getCompletions(text: String, cursorPosition: Int) async -> [SQLCompletion] {
        switch currentMode {
        case .disabled:
            return []
        case .ruleBased:
            // Use smart engine with async value lookups
            return await smartEngine.getCompletionsWithValues(text: text, cursorPosition: cursorPosition)
        case .openAI:
            return await getOpenAICompletions(text: text, cursorPosition: cursorPosition)
        case .anthropic:
            return await getAnthropicCompletions(text: text, cursorPosition: cursorPosition)
        }
    }
    
    // MARK: - OpenAI API Completions
    
    private func getOpenAICompletions(text: String, cursorPosition: Int) async -> [SQLCompletion] {
        guard let apiKey = openAIApiKey, !apiKey.isEmpty else {
            await MainActor.run { lastAPIError = "No OpenAI API key configured" }
            return smartEngine.getCompletions(text: text, cursorPosition: cursorPosition)
        }
        
        await MainActor.run { isLoading = true; lastAPIError = nil }
        defer { Task { @MainActor in isLoading = false } }
        
        let ctx = smartEngine.parseCursorContext(text: text, cursorPosition: cursorPosition)
        let schemaContext = smartEngine.buildRichSchemaContext()
        let prompt: String
        let systemPrompt: String
        
        if let comment = ctx.commentText, !comment.isEmpty {
            // Smart comment mode: natural language -> SQL
            systemPrompt = "You are a PostgreSQL expert. Convert natural language descriptions into SQL queries. You know the exact database schema. Return only valid JSON arrays. Use lowercase SQL keywords."
            prompt = """
            \(schemaContext)
            
            The user wrote this comment describing what they want:
            -- \(comment)
            
            Generate 3-5 complete SQL queries that match this description. Return a JSON array:
            [{"text": "complete SQL query", "description": "what this query does"}]
            
            Rules:
            - Return ONLY the JSON array, nothing else
            - Use lowercase SQL keywords
            - Use actual table and column names from the schema above
            - Each suggestion should be a complete, runnable query
            - Vary the suggestions (different approaches or interpretations)
            """
        } else {
            // Normal autocomplete mode
            let queryContext = smartEngine.buildQueryContext(text: text, cursorPosition: cursorPosition)
            systemPrompt = "You are a PostgreSQL SQL autocomplete assistant. You know the exact database schema. Return only valid JSON arrays. Use lowercase SQL keywords. Suggest completions that are contextually relevant."
            prompt = """
            \(schemaContext)
            
            \(queryContext)
            
            Provide 5 completion suggestions for the cursor position. Return a JSON array:
            [{"text": "completion text to insert", "description": "brief description"}]
            
            Rules:
            - Only return the JSON array, nothing else
            - Use lowercase SQL keywords
            - Suggest completions that continue from the cursor position
            - Be aware of table relationships and column types
            - For WHERE clauses, suggest relevant columns and operators
            - For JOINs, suggest the likely join condition
            """
        }
        
        do {
            let apiCompletions = try await callOpenAI(prompt: prompt, systemPrompt: systemPrompt, apiKey: apiKey)
            let smartResults = smartEngine.getCompletions(text: text, cursorPosition: cursorPosition)
            return mergeCompletions(primary: apiCompletions, secondary: smartResults)
        } catch {
            await MainActor.run { lastAPIError = error.localizedDescription }
            return smartEngine.getCompletions(text: text, cursorPosition: cursorPosition)
        }
    }
    
    private func callOpenAI(prompt: String, systemPrompt: String, apiKey: String) async throws -> [SQLCompletion] {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        
        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 500,
            "temperature": 0.3
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AutocompleteAPIError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AutocompleteAPIError.invalidResponse
        }
        
        return parseAPICompletions(content)
    }
    
    // MARK: - Anthropic Model Fetching
    
    func fetchAnthropicModels() async {
        guard let apiKey = anthropicApiKey, !apiKey.isEmpty else {
            await MainActor.run {
                availableAnthropicModels = []
                lastAPIError = "No Anthropic API key configured"
            }
            return
        }
        
        await MainActor.run { isFetchingModels = true; lastAPIError = nil }
        defer { Task { @MainActor in isFetchingModels = false } }
        
        do {
            let models = try await callAnthropicModels(apiKey: apiKey)
            await MainActor.run {
                availableAnthropicModels = models
                if !models.isEmpty && !models.contains(where: { $0.id == anthropicModel }) {
                    anthropicModel = models.first!.id
                }
            }
        } catch {
            print("Anthropic models fetch error: \(error)")
            await MainActor.run { lastAPIError = error.localizedDescription }
        }
    }
    
    private func callAnthropicModels(apiKey: String) async throws -> [AnthropicModelInfo] {
        let url = URL(string: "https://api.anthropic.com/v1/models?limit=100")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 10
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AutocompleteAPIError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelsArray = json["data"] as? [[String: Any]] else {
            throw AutocompleteAPIError.invalidResponse
        }
        
        return modelsArray.compactMap { model -> AnthropicModelInfo? in
            guard let id = model["id"] as? String,
                  let displayName = model["display_name"] as? String else { return nil }
            return AnthropicModelInfo(id: id, displayName: displayName)
        }
    }
    
    // MARK: - Anthropic API Completions
    
    private func getAnthropicCompletions(text: String, cursorPosition: Int) async -> [SQLCompletion] {
        guard let apiKey = anthropicApiKey, !apiKey.isEmpty else {
            await MainActor.run { lastAPIError = "No Anthropic API key configured" }
            return smartEngine.getCompletions(text: text, cursorPosition: cursorPosition)
        }
        
        await MainActor.run { isLoading = true; lastAPIError = nil }
        defer { Task { @MainActor in isLoading = false } }
        
        let ctx = smartEngine.parseCursorContext(text: text, cursorPosition: cursorPosition)
        let schemaContext = smartEngine.buildRichSchemaContext()
        let prompt: String
        let systemPrompt: String
        
        if let comment = ctx.commentText, !comment.isEmpty {
            // Smart comment mode: natural language -> SQL
            systemPrompt = "You are a PostgreSQL expert. Convert natural language descriptions into SQL queries. You know the exact database schema. Return only valid JSON arrays. Use lowercase SQL keywords."
            prompt = """
            \(schemaContext)
            
            The user wrote this comment describing what they want:
            -- \(comment)
            
            Generate 3-5 complete SQL queries that match this description. Return a JSON array:
            [{"text": "complete SQL query", "description": "what this query does"}]
            
            Rules:
            - Return ONLY the JSON array, nothing else
            - Use lowercase SQL keywords
            - Use actual table and column names from the schema above
            - Each suggestion should be a complete, runnable query
            - Vary the suggestions (different approaches or interpretations)
            """
        } else {
            // Normal autocomplete mode
            let queryContext = smartEngine.buildQueryContext(text: text, cursorPosition: cursorPosition)
            systemPrompt = "You are a PostgreSQL SQL autocomplete assistant. You know the exact database schema including column types, primary keys, and constraints. Return only valid JSON arrays of completion suggestions. Use lowercase SQL keywords. Suggest contextually relevant completions."
            prompt = """
            \(schemaContext)
            
            \(queryContext)
            
            Provide 5 completion suggestions for the cursor position. Return a JSON array:
            [{"text": "completion text to insert", "description": "brief description"}]
            
            Rules:
            - Only return the JSON array, nothing else
            - Use lowercase SQL keywords
            - Suggest completions that continue from the cursor position
            - Be aware of table relationships and column types
            - For WHERE clauses, suggest relevant columns and operators
            - For JOINs, suggest the likely join condition
            """
        }
        
        do {
            let apiCompletions = try await callAnthropic(prompt: prompt, systemPrompt: systemPrompt, apiKey: apiKey)
            let smartResults = smartEngine.getCompletions(text: text, cursorPosition: cursorPosition)
            return mergeCompletions(primary: apiCompletions, secondary: smartResults)
        } catch {
            await MainActor.run { lastAPIError = error.localizedDescription }
            return smartEngine.getCompletions(text: text, cursorPosition: cursorPosition)
        }
    }
    
    private func callAnthropic(prompt: String, systemPrompt: String, apiKey: String) async throws -> [SQLCompletion] {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        
        let body: [String: Any] = [
            "model": anthropicModel,
            "max_tokens": 500,
            "system": "You are a PostgreSQL SQL autocomplete assistant. You know the exact database schema including column types, primary keys, and constraints. Return only valid JSON arrays of completion suggestions. Use lowercase SQL keywords. Suggest contextually relevant completions.",
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AutocompleteAPIError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            throw AutocompleteAPIError.invalidResponse
        }
        
        return parseAPICompletions(text)
    }
    
    // MARK: - Response Parsing
    
    private func parseAPICompletions(_ content: String) -> [SQLCompletion] {
        guard let jsonStart = content.firstIndex(of: "["),
              let jsonEnd = content.lastIndex(of: "]") else {
            return []
        }
        
        let jsonString = String(content[jsonStart...jsonEnd])
        guard let jsonData = jsonString.data(using: .utf8),
              let suggestions = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: String]] else {
            return []
        }
        
        return suggestions.compactMap { suggestion -> SQLCompletion? in
            guard let text = suggestion["text"] else { return nil }
            return SQLCompletion(
                text: text,
                displayText: text,
                type: .snippet,
                detail: suggestion["description"]
            )
        }
    }
    
    // MARK: - Merge & Dedup
    
    /// Merges API completions with smart engine completions, deduplicating by text.
    private func mergeCompletions(primary: [SQLCompletion], secondary: [SQLCompletion]) -> [SQLCompletion] {
        var seen = Set<String>()
        var merged: [SQLCompletion] = []
        
        for c in primary {
            let key = c.text.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                merged.append(c)
            }
        }
        
        for c in secondary.prefix(15) {
            let key = c.text.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                merged.append(c)
            }
        }
        
        return merged
    }
}

// MARK: - Supporting Types

struct SQLCompletion: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let displayText: String
    let type: SQLCompletionType
    var detail: String?
    
    var icon: String {
        switch type {
        case .keyword: return "k"
        case .function: return "f"
        case .table: return "t"
        case .column: return "c"
        case .schema: return "s"
        case .operator: return "o"
        case .symbol: return "*"
        case .snippet: return ">"
        case .value: return "v"
        }
    }
}

enum SQLCompletionType {
    case keyword
    case function
    case table
    case column
    case schema
    case `operator`
    case symbol
    case snippet
    case value
}

enum AutocompleteAPIError: LocalizedError {
    case httpError(statusCode: Int, body: String)
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .httpError(let statusCode, let body):
            if let data = body.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let errorObj = json["error"] as? [String: Any],
                   let message = errorObj["message"] as? String {
                    return "\(statusCode): \(message)"
                }
                if let message = json["message"] as? String {
                    return "\(statusCode): \(message)"
                }
            }
            return "HTTP \(statusCode): \(String(body.prefix(200)))"
        case .invalidResponse:
            return "Invalid API response format"
        }
    }
}
