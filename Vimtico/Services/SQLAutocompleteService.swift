import Foundation

/// SQL Autocomplete service that provides context-aware suggestions
/// Supports multiple modes: Rule-based, and API-based (OpenAI, Anthropic)
class SQLAutocompleteService: ObservableObject {
    
    @Published var isLoading: Bool = false
    @Published var currentMode: AutocompleteMode = .ruleBased
    @Published var lastAPIError: String?
    
    // API Keys
    var openAIApiKey: String?
    var anthropicApiKey: String?
    var anthropicModel: AnthropicModel = .haiku
    
    // MARK: - SQL Keywords
    
    static let sqlKeywords: [String] = [
        // DQL (Data Query Language)
        "select", "from", "where", "and", "or", "not", "in", "like", "ilike", "between",
        "is", "null", "true", "false", "as", "distinct", "all",
        "order", "by", "asc", "desc", "nulls", "first", "last",
        "group", "having", "limit", "offset", "fetch", "next", "rows", "only",
        "union", "intersect", "except",
        
        // Joins
        "join", "inner", "left", "right", "full", "outer", "cross", "natural", "on", "using",
        
        // Subqueries
        "exists", "any", "some", "all",
        
        // CTE
        "with", "recursive",
        
        // DML (Data Manipulation Language)
        "insert", "into", "values", "default",
        "update", "set",
        "delete",
        "returning",
        "on", "conflict", "do", "nothing",
        
        // DDL (Data Definition Language)
        "create", "alter", "drop", "truncate",
        "table", "index", "view", "materialized", "schema", "database", "sequence",
        "primary", "key", "foreign", "references", "unique", "check", "constraint",
        "cascade", "restrict", "no", "action",
        "if", "exists",
        
        // Data types
        "integer", "int", "bigint", "smallint", "serial", "bigserial",
        "real", "double", "precision", "numeric", "decimal",
        "varchar", "char", "text", "character", "varying",
        "boolean", "bool",
        "date", "time", "timestamp", "timestamptz", "interval",
        "uuid", "json", "jsonb", "array", "bytea",
        
        // Control flow
        "case", "when", "then", "else", "end",
        "coalesce", "nullif", "greatest", "least",
        
        // Transactions
        "begin", "commit", "rollback", "savepoint", "transaction",
        
        // Permissions
        "grant", "revoke", "to", "public",
        
        // Other
        "explain", "analyze", "verbose", "costs", "buffers", "format"
    ]
    
    static let sqlFunctions: [String] = [
        // Aggregate functions
        "count", "sum", "avg", "min", "max",
        "array_agg", "string_agg", "json_agg", "jsonb_agg",
        "bool_and", "bool_or", "bit_and", "bit_or",
        
        // String functions
        "concat", "concat_ws", "length", "char_length", "octet_length",
        "lower", "upper", "initcap",
        "trim", "ltrim", "rtrim", "btrim",
        "left", "right", "substring", "substr",
        "position", "strpos", "replace", "translate",
        "split_part", "regexp_replace", "regexp_match", "regexp_matches",
        "format", "quote_ident", "quote_literal", "quote_nullable",
        "repeat", "reverse", "lpad", "rpad",
        
        // Numeric functions
        "abs", "ceil", "ceiling", "floor", "round", "trunc",
        "mod", "power", "sqrt", "cbrt", "exp", "ln", "log",
        "sign", "random", "setseed",
        "greatest", "least",
        
        // Date/Time functions
        "now", "current_date", "current_time", "current_timestamp",
        "localtime", "localtimestamp",
        "date_part", "date_trunc", "extract",
        "age", "make_date", "make_time", "make_timestamp",
        "to_char", "to_date", "to_timestamp", "to_number",
        
        // JSON functions
        "json_build_object", "json_build_array", "json_object", "json_array",
        "jsonb_build_object", "jsonb_build_array",
        "json_extract_path", "json_extract_path_text",
        "jsonb_extract_path", "jsonb_extract_path_text",
        "json_array_length", "jsonb_array_length",
        "json_typeof", "jsonb_typeof",
        "json_strip_nulls", "jsonb_strip_nulls",
        "jsonb_set", "jsonb_insert", "jsonb_pretty",
        
        // Array functions
        "array_length", "array_dims", "array_lower", "array_upper",
        "array_position", "array_positions", "array_remove", "array_replace",
        "array_cat", "array_append", "array_prepend",
        "unnest", "array_to_string", "string_to_array",
        
        // Conditional functions
        "coalesce", "nullif", "greatest", "least",
        
        // Type casting
        "cast", "convert",
        
        // Window functions
        "row_number", "rank", "dense_rank", "ntile",
        "lag", "lead", "first_value", "last_value", "nth_value",
        "percent_rank", "cume_dist",
        
        // System functions
        "current_user", "session_user", "current_schema", "current_catalog",
        "version", "pg_typeof"
    ]
    
    // MARK: - Completion Context
    
    enum CompletionContext {
        case initial
        case afterSelect
        case afterFrom
        case afterJoin
        case afterWhere
        case afterOrderBy
        case afterGroupBy
        case afterInsertInto
        case afterUpdate
        case afterSet
        case afterOn
        case afterUsing
        case afterValues
        case afterCreate
        case generic
    }
    
    // MARK: - Schema Cache
    
    private var cachedTables: [String] = []
    private var cachedColumns: [String: [String]] = [:]
    private var cachedSchemas: [String] = []
    
    // MARK: - Public Methods
    
    /// Update the schema cache with table names
    func updateTables(_ tables: [String]) {
        cachedTables = tables.sorted()
    }
    
    /// Update the schema cache with schema names
    func updateSchemas(_ schemas: [String]) {
        cachedSchemas = schemas.sorted()
    }
    
    /// Add columns for a table to cache
    func updateColumns(for tableName: String, columns: [String]) {
        cachedColumns[tableName] = columns
    }
    
    /// Get completions based on current mode
    func getCompletions(text: String, cursorPosition: Int) async -> [SQLCompletion] {
        switch currentMode {
        case .disabled:
            return []
        case .ruleBased:
            return getRuleBasedCompletions(text: text, cursorPosition: cursorPosition)
        case .openAI:
            return await getOpenAICompletions(text: text, cursorPosition: cursorPosition)
        case .anthropic:
            return await getAnthropicCompletions(text: text, cursorPosition: cursorPosition)
        }
    }
    
    // MARK: - Rule-Based Completions
    
    func getRuleBasedCompletions(text: String, cursorPosition: Int) -> [SQLCompletion] {
        let prefix = String(text.prefix(cursorPosition))
        let context = determineContext(prefix)
        let currentWord = getCurrentWord(prefix)
        
        var completions: [SQLCompletion] = []
        
        switch context {
        case .initial:
            completions = getInitialCompletions(filter: currentWord)
        case .afterSelect:
            completions = getSelectCompletions(filter: currentWord)
        case .afterFrom, .afterJoin, .afterUpdate, .afterInsertInto:
            completions = getTableCompletions(filter: currentWord)
        case .afterWhere, .afterOn, .afterSet:
            completions = getColumnAndOperatorCompletions(filter: currentWord, text: prefix)
        case .afterOrderBy, .afterGroupBy:
            completions = getColumnCompletions(filter: currentWord, text: prefix)
        case .afterCreate:
            completions = getCreateCompletions(filter: currentWord)
        case .afterValues:
            completions = getValuesCompletions(filter: currentWord)
        case .afterUsing:
            completions = getColumnCompletions(filter: currentWord, text: prefix)
        case .generic:
            completions = getGenericCompletions(filter: currentWord, text: prefix)
        }
        
        return completions
    }
    
    // MARK: - OpenAI API Completions
    
    func getOpenAICompletions(text: String, cursorPosition: Int) async -> [SQLCompletion] {
        guard let apiKey = openAIApiKey, !apiKey.isEmpty else {
            await MainActor.run { lastAPIError = "No OpenAI API key configured" }
            return getRuleBasedCompletions(text: text, cursorPosition: cursorPosition)
        }
        
        await MainActor.run { isLoading = true; lastAPIError = nil }
        defer { Task { @MainActor in isLoading = false } }
        
        let prefix = String(text.prefix(cursorPosition))
        let schemaContext = buildSchemaContext()
        
        let prompt = """
        Database Schema:
        \(schemaContext)
        
        Current SQL (cursor at end):
        \(prefix)
        
        Provide 5 completion suggestions in JSON format:
        [{"text": "completion text", "description": "brief description"}]
        
        Only return the JSON array, nothing else. Use lowercase SQL.
        """
        
        do {
            let completions = try await callOpenAI(prompt: prompt, apiKey: apiKey)
            let ruleBased = getRuleBasedCompletions(text: text, cursorPosition: cursorPosition)
            return completions + ruleBased.prefix(10)
        } catch {
            print("OpenAI API error: \(error)")
            await MainActor.run { lastAPIError = error.localizedDescription }
            return getRuleBasedCompletions(text: text, cursorPosition: cursorPosition)
        }
    }
    
    private func callOpenAI(prompt: String, apiKey: String) async throws -> [SQLCompletion] {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        
        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": "You are a PostgreSQL SQL autocomplete assistant. Return only valid JSON arrays. Use lowercase SQL keywords."],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 500,
            "temperature": 0.3
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Check HTTP status
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
    
    // MARK: - Anthropic API Completions
    
    func getAnthropicCompletions(text: String, cursorPosition: Int) async -> [SQLCompletion] {
        guard let apiKey = anthropicApiKey, !apiKey.isEmpty else {
            await MainActor.run { lastAPIError = "No Anthropic API key configured" }
            return getRuleBasedCompletions(text: text, cursorPosition: cursorPosition)
        }
        
        await MainActor.run { isLoading = true; lastAPIError = nil }
        defer { Task { @MainActor in isLoading = false } }
        
        let prefix = String(text.prefix(cursorPosition))
        let schemaContext = buildSchemaContext()
        
        let prompt = """
        Database Schema:
        \(schemaContext)
        
        Current SQL (cursor at end):
        \(prefix)
        
        Provide 5 completion suggestions in JSON format:
        [{"text": "completion text", "description": "brief description"}]
        
        Only return the JSON array, nothing else. Use lowercase SQL.
        """
        
        do {
            let completions = try await callAnthropic(prompt: prompt, apiKey: apiKey)
            let ruleBased = getRuleBasedCompletions(text: text, cursorPosition: cursorPosition)
            return completions + ruleBased.prefix(10)
        } catch {
            print("Anthropic API error: \(error)")
            await MainActor.run { lastAPIError = error.localizedDescription }
            return getRuleBasedCompletions(text: text, cursorPosition: cursorPosition)
        }
    }
    
    private func callAnthropic(prompt: String, apiKey: String) async throws -> [SQLCompletion] {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        
        let body: [String: Any] = [
            "model": anthropicModel.rawValue,
            "max_tokens": 500,
            "system": "You are a PostgreSQL SQL autocomplete assistant. Return only valid JSON arrays of completion suggestions. Use lowercase SQL keywords.",
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Check HTTP status
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
    
    private func parseAPICompletions(_ content: String) -> [SQLCompletion] {
        // Try to extract JSON from the response
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
                displayText: text.prefix(50) + (text.count > 50 ? "..." : ""),
                type: .snippet,
                detail: suggestion["description"]
            )
        }
    }
    
    private func buildSchemaContext() -> String {
        var context = "Tables: \(cachedTables.joined(separator: ", "))\n"
        
        for (table, columns) in cachedColumns.prefix(10) {
            context += "\(table): \(columns.joined(separator: ", "))\n"
        }
        
        return context
    }
    
    // MARK: - Context Detection
    
    private func determineContext(_ text: String) -> CompletionContext {
        let normalized = text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = normalized.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard let lastKeyword = findLastKeyword(in: words) else {
            return .initial
        }
        
        switch lastKeyword {
        case "SELECT", "SELECT DISTINCT":
            return .afterSelect
        case "FROM":
            return .afterFrom
        case "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN":
            return .afterJoin
        case "WHERE", "AND", "OR":
            return .afterWhere
        case "ORDER BY":
            return .afterOrderBy
        case "GROUP BY":
            return .afterGroupBy
        case "INSERT INTO":
            return .afterInsertInto
        case "UPDATE":
            return .afterUpdate
        case "SET":
            return .afterSet
        case "ON":
            return .afterOn
        case "USING":
            return .afterUsing
        case "VALUES":
            return .afterValues
        case "CREATE":
            return .afterCreate
        default:
            return .generic
        }
    }
    
    private func findLastKeyword(in words: [String]) -> String? {
        let multiWordKeywords = [
            "SELECT DISTINCT", "INSERT INTO", "ORDER BY", "GROUP BY",
            "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN"
        ]
        
        for i in (0..<words.count).reversed() {
            if i > 0 {
                let twoWord = "\(words[i-1]) \(words[i])"
                if multiWordKeywords.contains(twoWord) {
                    return twoWord
                }
            }
        }
        
        let singleKeywords = Set(["SELECT", "FROM", "WHERE", "AND", "OR", "JOIN", "ON", "SET", "UPDATE", "VALUES", "CREATE", "USING"])
        for word in words.reversed() {
            if singleKeywords.contains(word) {
                return word
            }
        }
        
        return nil
    }
    
    private func getCurrentWord(_ text: String) -> String {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "(),;"))
        let components = text.components(separatedBy: separators)
        return components.last ?? ""
    }
    
    // MARK: - Completion Generators
    
    private func getInitialCompletions(filter: String) -> [SQLCompletion] {
        let statements = ["select", "insert", "update", "delete", "create", "alter", "drop", "with", "explain"]
        return filterAndMap(statements, filter: filter, type: .keyword)
    }
    
    private func getSelectCompletions(filter: String) -> [SQLCompletion] {
        var completions: [SQLCompletion] = []
        
        if "*".lowercased().hasPrefix(filter.lowercased()) || filter.isEmpty {
            completions.append(SQLCompletion(text: "*", displayText: "*", type: .symbol, detail: "Select all columns"))
        }
        
        for (_, columns) in cachedColumns {
            completions += filterAndMap(columns, filter: filter, type: .column)
        }
        
        let aggregates = ["count", "sum", "avg", "min", "max", "array_agg", "string_agg"]
        completions += filterAndMap(aggregates, filter: filter, type: .function)
        completions += filterAndMap(["distinct"], filter: filter, type: .keyword)
        
        return completions
    }
    
    private func getTableCompletions(filter: String) -> [SQLCompletion] {
        var completions = filterAndMap(cachedTables, filter: filter, type: .table)
        completions += filterAndMap(cachedSchemas.map { "\($0)." }, filter: filter, type: .schema)
        return completions
    }
    
    private func getColumnCompletions(filter: String, text: String) -> [SQLCompletion] {
        var completions: [SQLCompletion] = []
        let mentionedTables = extractTablesFromQuery(text)
        
        if !mentionedTables.isEmpty {
            for table in mentionedTables {
                if let columns = cachedColumns[table] {
                    completions += filterAndMap(columns, filter: filter, type: .column)
                    completions += filterAndMap(columns.map { "\(table).\($0)" }, filter: filter, type: .column)
                }
            }
        } else {
            for (table, columns) in cachedColumns {
                completions += filterAndMap(columns.map { "\(table).\($0)" }, filter: filter, type: .column)
            }
        }
        
        return completions
    }
    
    private func getColumnAndOperatorCompletions(filter: String, text: String) -> [SQLCompletion] {
        var completions = getColumnCompletions(filter: filter, text: text)
        
        let operators = ["=", "<>", "!=", "<", ">", "<=", ">=", "like", "ilike", "in", "not in", "is null", "is not null", "between", "and", "or"]
        completions += filterAndMap(operators, filter: filter, type: .operator)
        
        let functions = ["coalesce", "nullif", "lower", "upper", "trim", "length"]
        completions += filterAndMap(functions, filter: filter, type: .function)
        
        return completions
    }
    
    private func getCreateCompletions(filter: String) -> [SQLCompletion] {
        let objects = ["table", "index", "view", "materialized view", "schema", "database", "sequence", "function", "trigger"]
        return filterAndMap(objects, filter: filter, type: .keyword)
    }
    
    private func getValuesCompletions(filter: String) -> [SQLCompletion] {
        let placeholders = ["default", "null", "true", "false", "now()"]
        return filterAndMap(placeholders, filter: filter, type: .keyword)
    }
    
    private func getGenericCompletions(filter: String, text: String) -> [SQLCompletion] {
        var completions: [SQLCompletion] = []
        
        completions += filterAndMap(Self.sqlKeywords, filter: filter, type: .keyword)
        completions += filterAndMap(Self.sqlFunctions, filter: filter, type: .function)
        completions += filterAndMap(cachedTables, filter: filter, type: .table)
        completions += getColumnCompletions(filter: filter, text: text)
        
        return Array(completions.prefix(50))
    }
    
    // MARK: - Helpers
    
    private func filterAndMap(_ items: [String], filter: String, type: SQLCompletionType) -> [SQLCompletion] {
        let lowercaseFilter = filter.lowercased()
        return items
            .filter { lowercaseFilter.isEmpty || $0.lowercased().hasPrefix(lowercaseFilter) }
            .map { SQLCompletion(text: $0, displayText: $0, type: type) }
    }
    
    private func extractTablesFromQuery(_ text: String) -> [String] {
        var tables: [String] = []
        let normalized = text.uppercased()
        
        let patterns = [
            "FROM\\s+([A-Z_][A-Z0-9_]*)",
            "JOIN\\s+([A-Z_][A-Z0-9_]*)",
            "UPDATE\\s+([A-Z_][A-Z0-9_]*)",
            "INTO\\s+([A-Z_][A-Z0-9_]*)"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let matches = regex.matches(in: normalized, options: [], range: NSRange(location: 0, length: normalized.count))
                for match in matches {
                    if match.numberOfRanges > 1,
                       let range = Range(match.range(at: 1), in: normalized) {
                        let tableName = String(normalized[range]).lowercased()
                        if cachedTables.contains(where: { $0.lowercased() == tableName }) {
                            tables.append(cachedTables.first(where: { $0.lowercased() == tableName }) ?? tableName)
                        }
                    }
                }
            }
        }
        
        return Array(Set(tables))
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
}

enum AutocompleteAPIError: LocalizedError {
    case httpError(statusCode: Int, body: String)
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .httpError(let statusCode, let body):
            // Try to parse a human-readable message from the JSON error body
            if let data = body.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Anthropic format: {"type":"error","error":{"type":"...","message":"..."}}
                if let errorObj = json["error"] as? [String: Any],
                   let message = errorObj["message"] as? String {
                    return "\(statusCode): \(message)"
                }
                // OpenAI format: {"error":{"message":"...","type":"...","code":"..."}}
                if let errorObj = json["error"] as? [String: Any],
                   let message = errorObj["message"] as? String {
                    return "\(statusCode): \(message)"
                }
                // Generic: {"message":"..."}
                if let message = json["message"] as? String {
                    return "\(statusCode): \(message)"
                }
            }
            return "HTTP \(statusCode): \(body.prefix(200))"
        case .invalidResponse:
            return "Invalid API response format"
        }
    }
}
