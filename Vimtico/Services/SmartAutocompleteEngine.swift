import Foundation

// MARK: - Smart Autocomplete Engine
//
// A layered autocomplete engine that combines:
//   Layer 1: Schema-aware completions (tables, columns with types, scoped to context)
//   Layer 2: Value lookups (DISTINCT values from DB) + query history predictions
//   Layer 3: AI enrichment (schema-aware prompts to OpenAI/Anthropic)
//
// This engine is separate from SQLAutocompleteService. The service delegates to
// this engine for the smart completions, then merges/ranks results.

/// Rich column metadata for autocomplete (preserves type info, PK, nullable, defaults)
struct ColumnInfo: Hashable {
    let name: String
    let dataType: String
    let isNullable: Bool
    let defaultValue: String?
    let isPrimaryKey: Bool
    
    /// Short type label for display in autocomplete detail
    var typeLabel: String {
        var label = dataType
        if isPrimaryKey { label += " PK" }
        if !isNullable { label += " NOT NULL" }
        if let def = defaultValue { label += " = \(def)" }
        return label
    }
}

/// A table reference found in the query, optionally with an alias
struct TableRef: Hashable {
    let name: String       // actual table name (lowercase)
    let alias: String?     // alias if present (e.g. "u" in "FROM users u")
    let schema: String?    // schema prefix if present (e.g. "public")
    
    /// The identifier the user would type to reference this table (alias if present, otherwise name)
    var identifier: String { alias ?? name }
}

/// Represents what the user is typing right now, parsed from cursor context
struct CursorContext {
    let textBeforeCursor: String
    let currentWord: String          // the partial word being typed
    let wordBeforeDot: String?       // if typing "u.na", this is "u", currentWord is "na"
    let sqlContext: SQLContext        // structural position in the query
    let referencedTables: [TableRef] // tables mentioned in the query so far
    let isAfterOperator: Bool        // cursor follows =, <>, etc. (value position)
    let precedingColumnName: String? // column name before the operator (for value lookups)
    let precedingTableForColumn: String? // resolved table for precedingColumnName
    let commentText: String?         // if cursor is on a -- comment line, the text after --
}

/// Structural SQL context (where in the query the cursor sits)
enum SQLContext {
    case empty                // nothing typed yet
    case statement            // start of a statement (SELECT, INSERT, etc.)
    case selectColumns        // after SELECT, expecting column names
    case fromTable            // after FROM/JOIN/UPDATE/INTO, expecting table name
    case whereCondition       // after WHERE/AND/OR, expecting column or expression
    case setValue             // after SET col =, expecting value
    case onCondition          // after ON, expecting join condition
    case orderByColumn        // after ORDER BY
    case groupByColumn        // after GROUP BY
    case insertColumns        // after INSERT INTO table (, expecting column names
    case values               // after VALUES (, expecting values
    case havingCondition      // after HAVING
    case createObject         // after CREATE
    case comment              // cursor is on a -- comment line (smart comment mode)
    case generic              // fallback
}

/// A single query history entry for pattern matching
struct QueryHistoryEntry {
    let sql: String
    let timestamp: Date
    let connectionId: UUID?
}

// MARK: - Smart Autocomplete Engine

class SmartAutocompleteEngine {
    
    // MARK: - Schema Cache (Layer 1)
    
    /// table name (lowercase) -> [ColumnInfo]
    private var tableColumns: [String: [ColumnInfo]] = [:]
    /// All table names (lowercase)
    private var tableNames: [String] = []
    /// All schema names
    private var schemaNames: [String] = []
    /// table name -> table type (table, view, materialized view)
    private var tableTypes: [String: String] = [:]
    
    // MARK: - Value Cache (Layer 2)
    
    /// Cache of distinct values per table.column, with expiry
    private var valueCache: [String: ValueCacheEntry] = [:]
    /// How long cached values are valid (5 minutes)
    private let valueCacheTTL: TimeInterval = 300
    /// Max distinct values to cache per column
    private let maxCachedValues = 50
    
    struct ValueCacheEntry {
        let values: [String]
        let fetchedAt: Date
        var isExpired: Bool { Date().timeIntervalSince(fetchedAt) > 300 }
    }
    
    // MARK: - Query History (Layer 2)
    
    private var queryHistory: [QueryHistoryEntry] = []
    private let maxHistory = 200
    
    /// Callback to fetch distinct values from the database. Set by the view model.
    /// Parameters: tableName, columnName, limit. Returns distinct values as strings.
    var fetchValues: ((String, String, Int) async -> [String])?
    
    // MARK: - Schema Updates
    
    func updateSchema(tables: [(name: String, schema: String, type: String)],
                      columns: [String: [ColumnInfo]]) {
        tableNames = tables.map { $0.name.lowercased() }.sorted()
        schemaNames = Array(Set(tables.map { $0.schema.lowercased() })).sorted()
        for t in tables {
            tableTypes[t.name.lowercased()] = t.type
        }
        tableColumns = [:]
        for (table, cols) in columns {
            tableColumns[table.lowercased()] = cols
        }
    }
    
    func updateColumns(for tableName: String, columns: [ColumnInfo]) {
        tableColumns[tableName.lowercased()] = columns
    }
    
    func addTable(_ name: String, schema: String, type: String) {
        let lower = name.lowercased()
        if !tableNames.contains(lower) {
            tableNames.append(lower)
            tableNames.sort()
        }
        tableTypes[lower] = type
        if !schemaNames.contains(schema.lowercased()) {
            schemaNames.append(schema.lowercased())
            schemaNames.sort()
        }
    }
    
    // MARK: - History Updates
    
    func recordQuery(_ sql: String, connectionId: UUID?) {
        let entry = QueryHistoryEntry(sql: sql, timestamp: Date(), connectionId: connectionId)
        queryHistory.insert(entry, at: 0)
        if queryHistory.count > maxHistory {
            queryHistory = Array(queryHistory.prefix(maxHistory))
        }
    }
    
    // MARK: - Main Entry Point
    
    /// Produces smart completions for the given text and cursor position.
    /// This is synchronous for Layer 1 (schema) and can optionally fetch values (Layer 2).
    func getCompletions(text: String, cursorPosition: Int) -> [SQLCompletion] {
        let ctx = parseCursorContext(text: text, cursorPosition: cursorPosition)
        
        var completions: [SQLCompletion] = []
        
        // Layer 1: Schema-aware completions
        completions += getSchemaCompletions(context: ctx)
        
        // Layer 2: History-based completions (synchronous, pattern match)
        completions += getHistoryCompletions(context: ctx)
        
        // Deduplicate by text (keep first occurrence, which is higher priority)
        var seen = Set<String>()
        completions = completions.filter { c in
            let key = c.text.lowercased()
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
        
        return completions
    }
    
    /// Async version that also includes value lookups (Layer 2)
    func getCompletionsWithValues(text: String, cursorPosition: Int) async -> [SQLCompletion] {
        let ctx = parseCursorContext(text: text, cursorPosition: cursorPosition)
        
        var completions: [SQLCompletion] = []
        
        // Layer 1: Schema-aware
        completions += getSchemaCompletions(context: ctx)
        
        // Layer 2: Values from database (async)
        if ctx.isAfterOperator, let colName = ctx.precedingColumnName {
            completions += await getValueCompletions(
                column: colName,
                table: ctx.precedingTableForColumn,
                filter: ctx.currentWord,
                context: ctx
            )
        }
        
        // Layer 2: History
        completions += getHistoryCompletions(context: ctx)
        
        // Deduplicate
        var seen = Set<String>()
        completions = completions.filter { c in
            let key = c.text.lowercased()
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
        
        return completions
    }
    
    // MARK: - Context for AI (Layer 3)
    
    /// Builds a rich schema context string for AI prompts. Includes column types,
    /// primary keys, and nullable info. Much richer than the old buildSchemaContext().
    func buildRichSchemaContext(maxTables: Int = 30) -> String {
        var lines: [String] = []
        lines.append("PostgreSQL Database Schema:")
        lines.append("")
        
        for tableName in tableNames.prefix(maxTables) {
            let typeLabel = tableTypes[tableName] ?? "TABLE"
            var header = "\(tableName)"
            if typeLabel != "TABLE" { header += " (\(typeLabel))" }
            
            if let cols = tableColumns[tableName] {
                let colDescriptions = cols.map { col -> String in
                    var desc = "  \(col.name) \(col.dataType)"
                    if col.isPrimaryKey { desc += " PRIMARY KEY" }
                    if !col.isNullable { desc += " NOT NULL" }
                    if let def = col.defaultValue { desc += " DEFAULT \(def)" }
                    return desc
                }
                lines.append(header + ":")
                lines += colDescriptions
            } else {
                lines.append(header + ": (columns not loaded)")
            }
            lines.append("")
        }
        
        if tableNames.count > maxTables {
            lines.append("... and \(tableNames.count - maxTables) more tables")
        }
        
        return lines.joined(separator: "\n")
    }
    
    /// Builds context about the current query for AI: what tables are referenced,
    /// what the user seems to be doing, and what kind of completion would help.
    func buildQueryContext(text: String, cursorPosition: Int) -> String {
        let ctx = parseCursorContext(text: text, cursorPosition: cursorPosition)
        var lines: [String] = []
        
        lines.append("Current SQL (cursor marked with |):")
        let before = String(text.prefix(cursorPosition))
        let after = String(text.suffix(text.count - cursorPosition))
        lines.append(before + "|" + after)
        lines.append("")
        
        if !ctx.referencedTables.isEmpty {
            lines.append("Tables in query:")
            for ref in ctx.referencedTables {
                var desc = "  \(ref.name)"
                if let alias = ref.alias { desc += " AS \(alias)" }
                if let cols = tableColumns[ref.name] {
                    let colNames = cols.map { $0.name }.joined(separator: ", ")
                    desc += " (\(colNames))"
                }
                lines.append(desc)
            }
        }
        
        lines.append("")
        lines.append("Context: \(ctx.sqlContext)")
        if let col = ctx.precedingColumnName {
            lines.append("Preceding column: \(col)")
        }
        
        return lines.joined(separator: "\n")
    }
    
    // MARK: - Layer 1: Schema-Aware Completions
    
    private func getSchemaCompletions(context ctx: CursorContext) -> [SQLCompletion] {
        // If user typed "alias." or "table.", complete columns for that table
        if let prefix = ctx.wordBeforeDot {
            return getDotCompletions(prefix: prefix, filter: ctx.currentWord, context: ctx)
        }
        
        switch ctx.sqlContext {
        case .empty:
            return getStatementCompletions(filter: ctx.currentWord)
            
        case .statement:
            return getStatementCompletions(filter: ctx.currentWord)
            
        case .selectColumns:
            return getSelectColumnCompletions(filter: ctx.currentWord, context: ctx)
            
        case .fromTable:
            return getTableNameCompletions(filter: ctx.currentWord)
            
        case .whereCondition, .havingCondition:
            return getWhereCompletions(filter: ctx.currentWord, context: ctx)
            
        case .setValue:
            return getValuePositionCompletions(filter: ctx.currentWord, context: ctx)
            
        case .onCondition:
            return getJoinConditionCompletions(filter: ctx.currentWord, context: ctx)
            
        case .orderByColumn, .groupByColumn:
            return getScopedColumnCompletions(filter: ctx.currentWord, context: ctx)
            
        case .insertColumns:
            return getInsertColumnCompletions(filter: ctx.currentWord, context: ctx)
            
        case .values:
            return getValuePlaceholderCompletions(filter: ctx.currentWord)
            
        case .createObject:
            return getCreateCompletions(filter: ctx.currentWord)
            
        case .comment:
            return getCommentCompletions(context: ctx)
            
        case .generic:
            return getGenericCompletions(filter: ctx.currentWord, context: ctx)
        }
    }
    
    // MARK: Dot completions (table.col or alias.col)
    
    private func getDotCompletions(prefix: String, filter: String, context: CursorContext) -> [SQLCompletion] {
        // Resolve prefix to a table name (could be alias or table name)
        let resolved = resolveTableName(prefix, in: context.referencedTables)
        
        guard let tableName = resolved, let cols = tableColumns[tableName] else {
            return []
        }
        
        return cols
            .filter { filter.isEmpty || $0.name.lowercased().hasPrefix(filter.lowercased()) }
            .map { col in
                SQLCompletion(
                    text: col.name,
                    displayText: col.name,
                    type: .column,
                    detail: col.typeLabel
                )
            }
    }
    
    // MARK: Statement starters
    
    private func getStatementCompletions(filter: String) -> [SQLCompletion] {
        let starters = [
            ("select", "Query data"),
            ("insert into", "Insert rows"),
            ("update", "Update rows"),
            ("delete from", "Delete rows"),
            ("with", "Common table expression"),
            ("create", "Create object"),
            ("alter", "Alter object"),
            ("drop", "Drop object"),
            ("explain analyze", "Analyze query plan"),
            ("begin", "Start transaction"),
            ("truncate", "Truncate table"),
        ]
        return filterCompletions(starters, filter: filter, type: .keyword)
    }
    
    // MARK: SELECT columns
    
    private func getSelectColumnCompletions(filter: String, context: CursorContext) -> [SQLCompletion] {
        var completions: [SQLCompletion] = []
        
        // Star
        if filter.isEmpty || "*".hasPrefix(filter) {
            completions.append(SQLCompletion(text: "*", displayText: "*", type: .symbol, detail: "All columns"))
        }
        
        // If tables are referenced, scope columns to those tables
        let tables = context.referencedTables
        if !tables.isEmpty {
            for ref in tables {
                if let cols = tableColumns[ref.name] {
                    // Offer table-qualified columns
                    let qualifier = ref.identifier
                    for col in cols {
                        let qualified = "\(qualifier).\(col.name)"
                        if filter.isEmpty || col.name.lowercased().hasPrefix(filter.lowercased()) ||
                           qualified.lowercased().hasPrefix(filter.lowercased()) {
                            completions.append(SQLCompletion(
                                text: col.name,
                                displayText: col.name,
                                type: .column,
                                detail: "\(ref.name).\(col.dataType)"
                            ))
                        }
                    }
                    // Also offer "table.*"
                    let starText = "\(qualifier).*"
                    if filter.isEmpty || starText.lowercased().hasPrefix(filter.lowercased()) {
                        completions.append(SQLCompletion(
                            text: starText,
                            displayText: starText,
                            type: .symbol,
                            detail: "All columns from \(ref.name)"
                        ))
                    }
                }
            }
        } else {
            // No tables referenced yet. Show all known columns with table prefix.
            for (table, cols) in tableColumns {
                for col in cols {
                    if filter.isEmpty || col.name.lowercased().hasPrefix(filter.lowercased()) {
                        completions.append(SQLCompletion(
                            text: col.name,
                            displayText: col.name,
                            type: .column,
                            detail: "\(table).\(col.dataType)"
                        ))
                    }
                }
            }
        }
        
        // Aggregate functions
        let aggregates: [(String, String)] = [
            ("count(", "Count rows"),
            ("sum(", "Sum values"),
            ("avg(", "Average"),
            ("min(", "Minimum"),
            ("max(", "Maximum"),
            ("array_agg(", "Collect into array"),
            ("string_agg(", "Concatenate strings"),
            ("json_agg(", "Collect into JSON array"),
            ("distinct", "Distinct values"),
            ("coalesce(", "First non-null"),
            ("case", "Conditional expression"),
        ]
        completions += filterCompletions(aggregates, filter: filter, type: .function)
        
        return completions
    }
    
    // MARK: Table name completions
    
    private func getTableNameCompletions(filter: String) -> [SQLCompletion] {
        var completions: [SQLCompletion] = []
        
        for name in tableNames {
            if filter.isEmpty || name.hasPrefix(filter.lowercased()) {
                let typeLabel = tableTypes[name] ?? "table"
                completions.append(SQLCompletion(
                    text: name,
                    displayText: name,
                    type: .table,
                    detail: typeLabel.lowercased()
                ))
            }
        }
        
        // Schema prefixes
        for schema in schemaNames {
            let prefixed = "\(schema)."
            if filter.isEmpty || prefixed.hasPrefix(filter.lowercased()) {
                completions.append(SQLCompletion(
                    text: prefixed,
                    displayText: prefixed,
                    type: .schema,
                    detail: "Schema"
                ))
            }
        }
        
        return completions
    }
    
    // MARK: WHERE/HAVING conditions
    
    private func getWhereCompletions(filter: String, context: CursorContext) -> [SQLCompletion] {
        var completions: [SQLCompletion] = []
        
        // If after an operator, suggest values
        if context.isAfterOperator {
            completions += getValuePositionCompletions(filter: filter, context: context)
            return completions
        }
        
        // Columns from referenced tables
        completions += getScopedColumnCompletions(filter: filter, context: context)
        
        // Logical operators
        let operators: [(String, String)] = [
            ("and", "Logical AND"),
            ("or", "Logical OR"),
            ("not", "Logical NOT"),
            ("in (", "In set"),
            ("not in (", "Not in set"),
            ("between", "Between range"),
            ("like", "Pattern match"),
            ("ilike", "Case-insensitive pattern"),
            ("is null", "Is NULL"),
            ("is not null", "Is not NULL"),
            ("exists (select", "Exists subquery"),
        ]
        completions += filterCompletions(operators, filter: filter, type: .operator)
        
        // Functions useful in WHERE
        let functions: [(String, String)] = [
            ("lower(", "Lowercase"),
            ("upper(", "Uppercase"),
            ("trim(", "Trim whitespace"),
            ("length(", "String length"),
            ("coalesce(", "First non-null"),
            ("now()", "Current timestamp"),
            ("current_date", "Current date"),
        ]
        completions += filterCompletions(functions, filter: filter, type: .function)
        
        return completions
    }
    
    // MARK: Value position (after = or other operator)
    
    private func getValuePositionCompletions(filter: String, context: CursorContext) -> [SQLCompletion] {
        var completions: [SQLCompletion] = []
        
        // Type-aware suggestions based on the column's data type
        if let colName = context.precedingColumnName,
           let tableName = context.precedingTableForColumn,
           let cols = tableColumns[tableName],
           let col = cols.first(where: { $0.name.lowercased() == colName.lowercased() }) {
            
            completions += getTypeAwareValueSuggestions(column: col, filter: filter)
        }
        
        // Common value expressions
        let common: [(String, String)] = [
            ("null", "NULL value"),
            ("true", "Boolean true"),
            ("false", "Boolean false"),
            ("now()", "Current timestamp"),
            ("current_date", "Today's date"),
            ("default", "Default value"),
        ]
        completions += filterCompletions(common, filter: filter, type: .keyword)
        
        // Subquery
        if filter.isEmpty || "select".hasPrefix(filter.lowercased()) {
            completions.append(SQLCompletion(
                text: "(select ", displayText: "(select ...)", type: .keyword, detail: "Subquery"))
        }
        
        return completions
    }
    
    /// Suggests values that make sense for the column's data type
    private func getTypeAwareValueSuggestions(column: ColumnInfo, filter: String) -> [SQLCompletion] {
        var completions: [SQLCompletion] = []
        let dt = column.dataType.lowercased()
        
        if dt.contains("uuid") {
            // Suggest UUID format hint
            if filter.isEmpty || "'".hasPrefix(filter) {
                completions.append(SQLCompletion(
                    text: "''", displayText: "'<uuid>'", type: .symbol,
                    detail: "UUID value"))
                completions.append(SQLCompletion(
                    text: "gen_random_uuid()", displayText: "gen_random_uuid()", type: .function,
                    detail: "Generate random UUID"))
            }
        } else if dt.contains("bool") {
            completions += filterCompletions([
                ("true", "Boolean true"), ("false", "Boolean false")
            ], filter: filter, type: .keyword)
        } else if dt.contains("int") || dt.contains("serial") || dt.contains("numeric") || dt.contains("decimal") || dt.contains("real") || dt.contains("double") {
            // Numeric. Not much to suggest except subquery or reference
            if filter.isEmpty {
                completions.append(SQLCompletion(
                    text: "0", displayText: "0", type: .symbol, detail: "Numeric literal"))
            }
        } else if dt.contains("timestamp") || dt.contains("date") {
            completions += filterCompletions([
                ("now()", "Current timestamp"),
                ("current_date", "Today"),
                ("current_timestamp", "Current timestamp with TZ"),
                ("interval '1 day'", "1 day interval"),
                ("now() - interval '1 hour'", "1 hour ago"),
                ("now() - interval '7 days'", "7 days ago"),
                ("now() - interval '30 days'", "30 days ago"),
            ], filter: filter, type: .function)
        } else if dt.contains("json") {
            completions += filterCompletions([
                ("'{}'", "Empty JSON object"),
                ("'[]'", "Empty JSON array"),
                ("jsonb_build_object(", "Build JSON object"),
            ], filter: filter, type: .function)
        } else if dt.contains("text") || dt.contains("varchar") || dt.contains("char") {
            if filter.isEmpty || "'".hasPrefix(filter) {
                completions.append(SQLCompletion(
                    text: "''", displayText: "'...'", type: .symbol,
                    detail: "Text value"))
            }
        } else if dt.contains("array") {
            completions += filterCompletions([
                ("array[", "Array literal"),
                ("'{}'", "Empty array"),
            ], filter: filter, type: .function)
        }
        
        // If column has a default, offer it
        if let def = column.defaultValue, !def.isEmpty {
            if filter.isEmpty || def.lowercased().hasPrefix(filter.lowercased()) {
                completions.append(SQLCompletion(
                    text: def, displayText: def, type: .keyword,
                    detail: "Column default"))
            }
        }
        
        return completions
    }
    
    // MARK: JOIN ON conditions
    
    private func getJoinConditionCompletions(filter: String, context: CursorContext) -> [SQLCompletion] {
        var completions: [SQLCompletion] = []
        
        // Suggest columns from all referenced tables, qualified with table/alias
        for ref in context.referencedTables {
            if let cols = tableColumns[ref.name] {
                let qualifier = ref.identifier
                for col in cols {
                    let qualified = "\(qualifier).\(col.name)"
                    if filter.isEmpty || qualified.lowercased().hasPrefix(filter.lowercased()) ||
                       col.name.lowercased().hasPrefix(filter.lowercased()) {
                        completions.append(SQLCompletion(
                            text: qualified,
                            displayText: qualified,
                            type: .column,
                            detail: col.typeLabel
                        ))
                    }
                }
            }
        }
        
        // Smart: suggest likely join columns (matching PKs/FKs between tables)
        completions += suggestJoinPairs(context: context, filter: filter)
        
        return completions
    }
    
    /// Suggests complete JOIN ON expressions based on matching column names between tables.
    /// e.g., if table "orders" has "user_id" and table "users" has "id", suggest "orders.user_id = users.id"
    private func suggestJoinPairs(context: CursorContext, filter: String) -> [SQLCompletion] {
        var completions: [SQLCompletion] = []
        let refs = context.referencedTables
        guard refs.count >= 2 else { return [] }
        
        // Check last two tables (typically the join target and the existing table)
        let lastTable = refs.last!
        let otherTables = refs.dropLast()
        
        guard let lastCols = tableColumns[lastTable.name] else { return [] }
        
        for other in otherTables {
            guard let otherCols = tableColumns[other.name] else { continue }
            
            // Pattern 1: lastTable has "othertable_id" and other has "id"
            for col in lastCols {
                let colLower = col.name.lowercased()
                if colLower == "\(other.name)_id" || colLower == "\(other.name.dropLast(col.name.hasSuffix("s") ? 0 : 1))_id" {
                    if let pk = otherCols.first(where: { $0.isPrimaryKey }) {
                        let expr = "\(lastTable.identifier).\(col.name) = \(other.identifier).\(pk.name)"
                        if filter.isEmpty || expr.lowercased().hasPrefix(filter.lowercased()) {
                            completions.append(SQLCompletion(
                                text: expr, displayText: expr, type: .snippet,
                                detail: "Join condition"))
                        }
                    }
                }
            }
            
            // Pattern 2: other has "lasttable_id" and lastTable has "id"
            for col in otherCols {
                let colLower = col.name.lowercased()
                if colLower == "\(lastTable.name)_id" {
                    if let pk = lastCols.first(where: { $0.isPrimaryKey }) {
                        let expr = "\(other.identifier).\(col.name) = \(lastTable.identifier).\(pk.name)"
                        if filter.isEmpty || expr.lowercased().hasPrefix(filter.lowercased()) {
                            completions.append(SQLCompletion(
                                text: expr, displayText: expr, type: .snippet,
                                detail: "Join condition"))
                        }
                    }
                }
            }
            
            // Pattern 3: matching column names (e.g. both have "id" or "user_id")
            let lastColNames = Set(lastCols.map { $0.name.lowercased() })
            let otherColNames = Set(otherCols.map { $0.name.lowercased() })
            let shared = lastColNames.intersection(otherColNames)
            for colName in shared where colName != "id" && colName != "created_at" && colName != "updated_at" {
                let expr = "\(lastTable.identifier).\(colName) = \(other.identifier).\(colName)"
                if filter.isEmpty || expr.lowercased().hasPrefix(filter.lowercased()) {
                    completions.append(SQLCompletion(
                        text: expr, displayText: expr, type: .snippet,
                        detail: "Matching column"))
                }
            }
        }
        
        return completions
    }
    
    // MARK: Scoped column completions (for ORDER BY, GROUP BY, generic column contexts)
    
    private func getScopedColumnCompletions(filter: String, context: CursorContext) -> [SQLCompletion] {
        var completions: [SQLCompletion] = []
        let refs = context.referencedTables
        
        if !refs.isEmpty {
            for ref in refs {
                if let cols = tableColumns[ref.name] {
                    for col in cols {
                        if filter.isEmpty || col.name.lowercased().hasPrefix(filter.lowercased()) {
                            completions.append(SQLCompletion(
                                text: col.name,
                                displayText: col.name,
                                type: .column,
                                detail: "\(ref.name).\(col.dataType)"
                            ))
                        }
                        // Also offer qualified
                        let qualified = "\(ref.identifier).\(col.name)"
                        if filter.isEmpty || qualified.lowercased().hasPrefix(filter.lowercased()) {
                            completions.append(SQLCompletion(
                                text: qualified,
                                displayText: qualified,
                                type: .column,
                                detail: col.typeLabel
                            ))
                        }
                    }
                }
            }
        } else {
            // No tables. Show all columns with table qualifier.
            for (table, cols) in tableColumns {
                for col in cols {
                    if filter.isEmpty || col.name.lowercased().hasPrefix(filter.lowercased()) {
                        completions.append(SQLCompletion(
                            text: col.name,
                            displayText: col.name,
                            type: .column,
                            detail: "\(table).\(col.dataType)"
                        ))
                    }
                }
            }
        }
        
        return completions
    }
    
    // MARK: INSERT INTO table (...) columns
    
    private func getInsertColumnCompletions(filter: String, context: CursorContext) -> [SQLCompletion] {
        // Find the table being inserted into
        guard let targetTable = context.referencedTables.first,
              let cols = tableColumns[targetTable.name] else {
            return []
        }
        
        return cols
            .filter { filter.isEmpty || $0.name.lowercased().hasPrefix(filter.lowercased()) }
            .map { col in
                SQLCompletion(
                    text: col.name,
                    displayText: col.name,
                    type: .column,
                    detail: col.typeLabel
                )
            }
    }
    
    // MARK: VALUES placeholders
    
    private func getValuePlaceholderCompletions(filter: String) -> [SQLCompletion] {
        let placeholders: [(String, String)] = [
            ("default", "Default value"),
            ("null", "NULL"),
            ("true", "Boolean true"),
            ("false", "Boolean false"),
            ("now()", "Current timestamp"),
            ("gen_random_uuid()", "Random UUID"),
        ]
        return filterCompletions(placeholders, filter: filter, type: .keyword)
    }
    
    // MARK: CREATE
    
    private func getCreateCompletions(filter: String) -> [SQLCompletion] {
        let objects: [(String, String)] = [
            ("table", "Create table"),
            ("index", "Create index"),
            ("view", "Create view"),
            ("materialized view", "Create materialized view"),
            ("schema", "Create schema"),
            ("function", "Create function"),
            ("trigger", "Create trigger"),
            ("sequence", "Create sequence"),
            ("type", "Create type"),
            ("extension", "Create extension"),
        ]
        return filterCompletions(objects, filter: filter, type: .keyword)
    }
    
    // MARK: Generic fallback
    
    private func getGenericCompletions(filter: String, context: CursorContext) -> [SQLCompletion] {
        var completions: [SQLCompletion] = []
        
        // Keywords likely to continue the current query
        let continuationKeywords: [(String, String)] = [
            ("where", "Filter rows"),
            ("and", "Additional condition"),
            ("or", "Alternative condition"),
            ("order by", "Sort results"),
            ("group by", "Group results"),
            ("having", "Filter groups"),
            ("limit", "Limit rows"),
            ("offset", "Skip rows"),
            ("join", "Join table"),
            ("left join", "Left outer join"),
            ("inner join", "Inner join"),
            ("on", "Join condition"),
            ("as", "Alias"),
            ("set", "Set values"),
            ("values", "Row values"),
            ("returning", "Return modified rows"),
            ("from", "From table"),
            ("into", "Into target"),
            ("union", "Combine results"),
            ("except", "Subtract results"),
            ("intersect", "Intersect results"),
        ]
        completions += filterCompletions(continuationKeywords, filter: filter, type: .keyword)
        
        // Table names
        completions += getTableNameCompletions(filter: filter)
        
        // Columns from referenced tables
        completions += getScopedColumnCompletions(filter: filter, context: context)
        
        return Array(completions.prefix(40))
    }
    
    // MARK: Smart comment completions (-- natural language -> SQL)
    
    /// Generates SQL query suggestions from a natural language comment.
    /// When the user types "-- latest 10 users", this suggests:
    ///   select * from users order by created_at desc limit 10
    private func getCommentCompletions(context: CursorContext) -> [SQLCompletion] {
        guard let comment = context.commentText, !comment.isEmpty else {
            // Just "--" with nothing after it. Suggest common patterns.
            return getCommentTemplates()
        }
        
        let lower = comment.lowercased()
        var completions: [SQLCompletion] = []
        
        // Try to match tables mentioned in the comment
        let mentionedTables = tableNames.filter { tableName in
            // Match table name or singular/plural form
            lower.contains(tableName) ||
            lower.contains(String(tableName.dropLast())) || // singular of plural
            lower.contains(tableName + "s")                 // plural of singular
        }
        
        // Extract numbers from the comment (for LIMIT)
        let numbers = extractNumbers(from: comment)
        let limit = numbers.first
        
        // Detect ordering intent
        let wantsDesc = lower.contains("latest") || lower.contains("newest") ||
                        lower.contains("recent") || lower.contains("last") ||
                        lower.contains("top") || lower.contains("most recent")
        let wantsAsc = lower.contains("oldest") || lower.contains("earliest") ||
                       lower.contains("first") || lower.contains("ascending")
        
        // Detect count/aggregate intent
        let wantsCount = lower.contains("count") || lower.contains("how many") ||
                         lower.contains("number of") || lower.contains("total")
        
        // Detect distinct intent
        let wantsDistinct = lower.contains("distinct") || lower.contains("unique") ||
                            lower.contains("different")
        
        // Detect column filter patterns: "where X is Y", "with X = Y", "by X"
        let wantsFilter = lower.contains("where") || lower.contains("with") ||
                          lower.contains("filter") || lower.contains("having")
        
        // Detect grouping
        let wantsGroup = lower.contains("group") || lower.contains("per") ||
                         lower.contains("by each") || lower.contains("breakdown")
        
        // Find likely ordering column from mentioned tables
        let orderColumn = findOrderColumn(tables: mentionedTables)
        
        // Find likely filter columns mentioned in the comment
        let filterColumn = findMentionedColumn(in: lower, tables: mentionedTables)
        
        for tableName in mentionedTables {
            if wantsCount {
                // Count query
                var sql = "select count(*) from \(tableName)"
                if let (col, _) = filterColumn {
                    sql += " where \(col) = "
                }
                completions.append(SQLCompletion(
                    text: sql,
                    displayText: sql,
                    type: .snippet,
                    detail: "Count \(tableName)"
                ))
                
                if wantsGroup, let cols = tableColumns[tableName] {
                    // Group by each column that seems relevant
                    for col in cols where isGroupableColumn(col) {
                        let groupSql = "select \(col.name), count(*) from \(tableName) group by \(col.name) order by count(*) desc"
                        completions.append(SQLCompletion(
                            text: groupSql,
                            displayText: groupSql,
                            type: .snippet,
                            detail: "Count by \(col.name)"
                        ))
                    }
                }
            } else if wantsDistinct {
                // Distinct values
                if let (col, _) = filterColumn {
                    let sql = "select distinct \(col) from \(tableName) order by \(col)"
                    completions.append(SQLCompletion(
                        text: sql,
                        displayText: sql,
                        type: .snippet,
                        detail: "Distinct \(col) values"
                    ))
                } else {
                    let sql = "select distinct * from \(tableName)"
                    completions.append(SQLCompletion(
                        text: sql,
                        displayText: sql,
                        type: .snippet,
                        detail: "Distinct rows"
                    ))
                }
            } else {
                // Select query with ordering
                var sql = "select * from \(tableName)"
                
                if let (col, _) = filterColumn, wantsFilter {
                    sql += " where \(col) = "
                }
                
                if wantsDesc || wantsAsc {
                    let col = orderColumn ?? "created_at"
                    let dir = wantsAsc ? "asc" : "desc"
                    sql += " order by \(col) \(dir)"
                }
                
                if let n = limit {
                    sql += " limit \(n)"
                }
                
                completions.append(SQLCompletion(
                    text: sql,
                    displayText: sql,
                    type: .snippet,
                    detail: "Query \(tableName)"
                ))
            }
        }
        
        // If no tables were matched, suggest based on all tables
        if mentionedTables.isEmpty && !tableNames.isEmpty {
            for tableName in tableNames.prefix(5) {
                var sql = "select * from \(tableName)"
                if wantsDesc {
                    let col = findOrderColumn(tables: [tableName]) ?? "created_at"
                    sql += " order by \(col) desc"
                }
                if let n = limit {
                    sql += " limit \(n)"
                }
                completions.append(SQLCompletion(
                    text: sql,
                    displayText: sql,
                    type: .snippet,
                    detail: tableName
                ))
            }
        }
        
        // Also check history for matching patterns
        for entry in queryHistory.prefix(20) {
            let sqlLower = entry.sql.lowercased()
            // Fuzzy match: check if comment words appear in historical queries
            let words = lower.split(separator: " ").filter { $0.count >= 3 }
            let matchCount = words.filter { sqlLower.contains($0) }.count
            if matchCount >= 2 || (words.count == 1 && matchCount == 1) {
                completions.append(SQLCompletion(
                    text: entry.sql.trimmingCharacters(in: .whitespacesAndNewlines),
                    displayText: entry.sql.trimmingCharacters(in: .whitespacesAndNewlines),
                    type: .snippet,
                    detail: "from history"
                ))
            }
        }
        
        return completions
    }
    
    /// Suggests common comment templates when user just typed "--"
    private func getCommentTemplates() -> [SQLCompletion] {
        var templates: [(String, String)] = [
            ("-- latest 10 ", "Recent records"),
            ("-- count ", "Count records"),
            ("-- all ", "All records from table"),
            ("-- distinct ", "Unique values"),
        ]
        
        // Add table-specific templates
        for table in tableNames.prefix(5) {
            templates.append(("-- all \(table)", "All \(table)"))
            templates.append(("-- latest 10 \(table)", "Recent \(table)"))
        }
        
        return templates.prefix(10).map { (text, detail) in
            SQLCompletion(text: text, displayText: text, type: .snippet, detail: detail)
        }
    }
    
    /// Extracts integer numbers from text
    private func extractNumbers(from text: String) -> [Int] {
        let pattern = "\\b(\\d+)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
        return matches.compactMap { match -> Int? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[range])
        }
    }
    
    /// Finds the best column to ORDER BY for the given tables (prefers created_at, updated_at, id)
    private func findOrderColumn(tables: [String]) -> String? {
        let preferredOrder = ["created_at", "updated_at", "inserted_at", "timestamp", "date", "id"]
        for table in tables {
            if let cols = tableColumns[table] {
                for preferred in preferredOrder {
                    if cols.contains(where: { $0.name.lowercased() == preferred }) {
                        return preferred
                    }
                }
            }
        }
        return nil
    }
    
    /// Finds a column name mentioned in the comment text
    private func findMentionedColumn(in text: String, tables: [String]) -> (String, String)? {
        for table in tables {
            if let cols = tableColumns[table] {
                for col in cols {
                    // Check if column name appears in the comment
                    if text.contains(col.name.lowercased()) {
                        return (col.name, table)
                    }
                    // Also check without underscores (e.g. "created at" -> "created_at")
                    let noUnderscore = col.name.replacingOccurrences(of: "_", with: " ")
                    if text.contains(noUnderscore.lowercased()) {
                        return (col.name, table)
                    }
                }
            }
        }
        return nil
    }
    
    /// Determines if a column is suitable for GROUP BY
    private func isGroupableColumn(_ col: ColumnInfo) -> Bool {
        let dt = col.dataType.lowercased()
        // Skip timestamp and serial columns (not good for grouping)
        if dt.contains("timestamp") || dt.contains("serial") { return false }
        // Skip primary keys (usually unique, bad for grouping)
        if col.isPrimaryKey { return false }
        // Text, varchar, enum, boolean, integer are groupable
        return true
    }
    
    // MARK: - Layer 2: Value Lookups
    
    private func getValueCompletions(column: String, table: String?, filter: String,
                                     context: CursorContext) async -> [SQLCompletion] {
        // Resolve which table the column belongs to
        let tableName: String?
        if let t = table {
            tableName = t
        } else if context.referencedTables.count == 1 {
            tableName = context.referencedTables.first?.name
        } else {
            // Ambiguous. Try to find which table has this column.
            tableName = tableColumns.first(where: { _, cols in
                cols.contains { $0.name.lowercased() == column.lowercased() }
            })?.key
        }
        
        guard let resolvedTable = tableName else { return [] }
        
        let cacheKey = "\(resolvedTable).\(column)"
        
        // Check cache
        if let cached = valueCache[cacheKey], !cached.isExpired {
            return cached.values
                .filter { filter.isEmpty || $0.lowercased().hasPrefix(filter.lowercased()) }
                .prefix(20)
                .map { val in
                    SQLCompletion(
                        text: quoteValueIfNeeded(val, column: column, table: resolvedTable),
                        displayText: val,
                        type: .symbol,
                        detail: "from \(resolvedTable)"
                    )
                }
        }
        
        // Fetch from database
        guard let fetch = fetchValues else { return [] }
        
        let values = await fetch(resolvedTable, column, maxCachedValues)
        valueCache[cacheKey] = ValueCacheEntry(values: values, fetchedAt: Date())
        
        return values
            .filter { filter.isEmpty || $0.lowercased().hasPrefix(filter.lowercased()) }
            .prefix(20)
            .map { val in
                SQLCompletion(
                    text: quoteValueIfNeeded(val, column: column, table: resolvedTable),
                    displayText: val,
                    type: .symbol,
                    detail: "from \(resolvedTable)"
                )
            }
    }
    
    /// Wraps value in quotes if the column type is text/varchar/uuid/etc.
    private func quoteValueIfNeeded(_ value: String, column: String, table: String) -> String {
        guard let cols = tableColumns[table],
              let col = cols.first(where: { $0.name.lowercased() == column.lowercased() }) else {
            return "'\(value)'"
        }
        
        let dt = col.dataType.lowercased()
        let numericTypes = ["integer", "int", "bigint", "smallint", "serial", "bigserial",
                            "real", "double", "numeric", "decimal", "float"]
        let boolTypes = ["boolean", "bool"]
        
        if numericTypes.contains(where: { dt.contains($0) }) {
            return value
        } else if boolTypes.contains(where: { dt.contains($0) }) {
            return value
        } else {
            // Escape single quotes in value
            let escaped = value.replacingOccurrences(of: "'", with: "''")
            return "'\(escaped)'"
        }
    }
    
    // MARK: - Layer 2: History-Based Completions
    
    private func getHistoryCompletions(context: CursorContext) -> [SQLCompletion] {
        guard !context.textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        
        let prefix = context.textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard prefix.count >= 3 else { return [] } // need at least 3 chars to match
        
        var seen = Set<String>()
        var completions: [SQLCompletion] = []
        
        for entry in queryHistory {
            let sql = entry.sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            
            // Check if any past query starts with what the user has typed so far
            if sql.hasPrefix(prefix) && sql != prefix {
                let remainder = String(entry.sql.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !remainder.isEmpty && !seen.contains(remainder.lowercased()) {
                    seen.insert(remainder.lowercased())
                    
                    let displayRemainder = String(remainder.prefix(60))
                    completions.append(SQLCompletion(
                        text: remainder,
                        displayText: "... \(displayRemainder)",
                        type: .snippet,
                        detail: "from history"
                    ))
                }
            }
            
            if completions.count >= 5 { break }
        }
        
        return completions
    }
    
    // MARK: - Query Parsing
    
    /// Parses the full cursor context from the query text and cursor position.
    func parseCursorContext(text: String, cursorPosition: Int) -> CursorContext {
        let pos = min(cursorPosition, text.count)
        let textBefore = String(text.prefix(pos))
        
        // Check if cursor is on a comment line (-- ...)
        let commentText = detectCommentLine(textBefore)
        
        // Extract current word and dot prefix
        let (currentWord, dotPrefix) = extractCurrentWord(textBefore)
        
        // Determine SQL context (comment overrides everything)
        let sqlContext: SQLContext
        if commentText != nil {
            sqlContext = .comment
        } else {
            sqlContext = determineSQLContext(textBefore)
        }
        
        // Extract referenced tables with aliases (from non-comment parts)
        let referencedTables = extractTableRefs(textBefore)
        
        // Detect if we're in a value position (after operator)
        let (isAfterOp, precedingCol, precedingTable) = detectValuePosition(textBefore, tables: referencedTables)
        
        return CursorContext(
            textBeforeCursor: textBefore,
            currentWord: currentWord,
            wordBeforeDot: dotPrefix,
            sqlContext: sqlContext,
            referencedTables: referencedTables,
            isAfterOperator: isAfterOp,
            precedingColumnName: precedingCol,
            precedingTableForColumn: precedingTable,
            commentText: commentText
        )
    }
    
    /// Detects if the cursor is on a comment line. Returns the text after "--" if so.
    private func detectCommentLine(_ textBefore: String) -> String? {
        // Get the current line (from last newline to end)
        let lines = textBefore.components(separatedBy: "\n")
        guard let currentLine = lines.last else { return nil }
        
        let trimmed = currentLine.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("--") {
            let afterDashes = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return afterDashes
        }
        return nil
    }
    
    // MARK: Current word extraction
    
    private func extractCurrentWord(_ text: String) -> (word: String, dotPrefix: String?) {
        // Walk backwards from end to find the current token
        var word = ""
        var dotPrefix: String? = nil
        
        let chars = Array(text)
        var i = chars.count - 1
        
        // Skip trailing whitespace? No, if there is trailing whitespace the word is empty
        if i >= 0 && chars[i].isWhitespace {
            return ("", nil)
        }
        
        // Collect word characters (alphanumeric, underscore, dot)
        while i >= 0 {
            let c = chars[i]
            if c == "." {
                // Found a dot. Everything after it is the current word,
                // and we need to extract the prefix before the dot.
                let afterDot = word
                i -= 1
                var prefix = ""
                while i >= 0 && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    prefix = String(chars[i]) + prefix
                    i -= 1
                }
                if !prefix.isEmpty {
                    return (afterDot, prefix)
                } else {
                    return (afterDot, nil)
                }
            } else if c.isLetter || c.isNumber || c == "_" {
                word = String(c) + word
                i -= 1
            } else {
                break
            }
        }
        
        return (word, dotPrefix)
    }
    
    // MARK: SQL context determination
    
    private func determineSQLContext(_ text: String) -> SQLContext {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        
        // Tokenize, keeping multi-word keywords together
        let upper = trimmed.uppercased()
        let tokens = tokenize(upper)
        guard !tokens.isEmpty else { return .empty }
        
        // Scan backwards for the most recent structural keyword
        // But be aware of parentheses (subqueries, INSERT INTO ... (...))
        var parenDepth = 0
        for i in stride(from: tokens.count - 1, through: 0, by: -1) {
            let token = tokens[i]
            
            if token == ")" { parenDepth += 1; continue }
            if token == "(" {
                parenDepth -= 1
                // If we just closed an INSERT INTO table ( parens, context is insertColumns
                if parenDepth < 0 {
                    // Look back for INSERT INTO <table>
                    if i >= 2 && tokens[i-2].uppercased() == "INSERT" && tokens[i-1].uppercased() == "INTO" {
                        return .insertColumns
                    }
                    if i >= 3 && tokens[i-3].uppercased() == "INSERT" && tokens[i-2].uppercased() == "INTO" {
                        return .insertColumns
                    }
                    parenDepth = 0
                }
                continue
            }
            if parenDepth > 0 { continue }
            
            switch token {
            case "SELECT", "SELECT DISTINCT":
                return .selectColumns
            case "FROM", "DELETE FROM":
                return .fromTable
            case "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN",
                 "CROSS JOIN", "LEFT OUTER JOIN", "RIGHT OUTER JOIN", "FULL OUTER JOIN":
                return .fromTable
            case "INSERT INTO":
                return .fromTable
            case "UPDATE":
                return .fromTable
            case "WHERE", "AND", "OR":
                return .whereCondition
            case "HAVING":
                return .havingCondition
            case "ON":
                return .onCondition
            case "SET":
                return .setValue
            case "ORDER BY":
                return .orderByColumn
            case "GROUP BY":
                return .groupByColumn
            case "VALUES":
                return .values
            case "CREATE":
                return .createObject
            case "LIMIT", "OFFSET", "FETCH", "RETURNING", "AS",
                 "UNION", "EXCEPT", "INTERSECT":
                return .generic
            default:
                continue
            }
        }
        
        // If we get here and the first token is a statement starter
        let first = tokens.first?.uppercased() ?? ""
        if ["SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "WITH",
            "EXPLAIN", "BEGIN", "COMMIT", "ROLLBACK", "TRUNCATE", "GRANT", "REVOKE"].contains(first) {
            return .generic
        }
        
        return .statement
    }
    
    /// Tokenizes SQL, collapsing multi-word keywords into single tokens.
    private func tokenize(_ sql: String) -> [String] {
        // Split on whitespace and common delimiters, but keep parens as tokens
        var tokens: [String] = []
        var current = ""
        
        for ch in sql {
            if ch == "(" || ch == ")" || ch == "," || ch == ";" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                tokens.append(String(ch))
            } else if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        
        // Collapse multi-word keywords
        var collapsed: [String] = []
        let multiKeywords: Set<String> = [
            "INSERT INTO", "ORDER BY", "GROUP BY", "SELECT DISTINCT",
            "DELETE FROM", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN",
            "CROSS JOIN", "LEFT OUTER JOIN", "RIGHT OUTER JOIN", "FULL OUTER JOIN",
            "EXPLAIN ANALYZE", "NOT IN", "IS NOT", "IS NULL", "IS NOT NULL"
        ]
        
        var i = 0
        while i < tokens.count {
            var matched = false
            // Try 3-word keywords first
            if i + 2 < tokens.count {
                let three = "\(tokens[i]) \(tokens[i+1]) \(tokens[i+2])"
                if multiKeywords.contains(three) {
                    collapsed.append(three)
                    i += 3
                    matched = true
                }
            }
            if !matched && i + 1 < tokens.count {
                let two = "\(tokens[i]) \(tokens[i+1])"
                if multiKeywords.contains(two) {
                    collapsed.append(two)
                    i += 2
                    matched = true
                }
            }
            if !matched {
                collapsed.append(tokens[i])
                i += 1
            }
        }
        
        return collapsed
    }
    
    // MARK: Table reference extraction (with alias support)
    
    /// Extracts table references from the query, including aliases.
    /// Handles: FROM users u, JOIN orders o ON ..., UPDATE accounts a SET ..., INSERT INTO logs ...
    func extractTableRefs(_ text: String) -> [TableRef] {
        var refs: [TableRef] = []
        let tokens = tokenize(text.uppercased())
        
        // Track which indices are table-name positions
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            
            let isTableKeyword: Bool
            switch token {
            case "FROM", "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN",
                 "CROSS JOIN", "LEFT OUTER JOIN", "RIGHT OUTER JOIN", "FULL OUTER JOIN",
                 "UPDATE":
                isTableKeyword = true
            case "INSERT INTO":
                isTableKeyword = true
            case "DELETE FROM":
                isTableKeyword = true
            default:
                isTableKeyword = false
            }
            
            if isTableKeyword {
                i += 1
                // Next token(s) should be table name(s), possibly comma-separated (FROM a, b, c)
                while i < tokens.count {
                    let name = tokens[i]
                    // Skip if it's a keyword or paren
                    if name == "(" || name == ")" || name == "," || name == ";" {
                        if name == "," { i += 1; continue }
                        break
                    }
                    if isKeyword(name) { break }
                    
                    let lowered = name.lowercased()
                    // Check if this is actually a known table or looks like an identifier
                    let isTable = tableNames.contains(lowered) || isIdentifier(name)
                    
                    if isTable {
                        var alias: String? = nil
                        // Check for alias: next token is AS or an identifier that's not a keyword
                        if i + 1 < tokens.count {
                            let next = tokens[i + 1]
                            if next.uppercased() == "AS" && i + 2 < tokens.count {
                                alias = tokens[i + 2].lowercased()
                                i += 2
                            } else if !isKeyword(next) && isIdentifier(next) && next != "(" && next != ")" && next != "," && next != ";" {
                                alias = next.lowercased()
                                i += 1
                            }
                        }
                        
                        // Handle schema.table
                        var schema: String? = nil
                        var tableName = lowered
                        if lowered.contains(".") {
                            let parts = lowered.split(separator: ".")
                            if parts.count == 2 {
                                schema = String(parts[0])
                                tableName = String(parts[1])
                            }
                        }
                        
                        refs.append(TableRef(name: tableName, alias: alias, schema: schema))
                    }
                    
                    i += 1
                    // Check for comma (more tables)
                    if i < tokens.count && tokens[i] == "," {
                        i += 1
                        continue
                    }
                    break
                }
            } else {
                i += 1
            }
        }
        
        return refs
    }
    
    // MARK: Value position detection
    
    /// Detects if cursor is after an operator (=, <>, !=, >=, <=, >, <, LIKE, ILIKE, IN)
    /// and extracts the preceding column name and its resolved table.
    private func detectValuePosition(_ text: String, tables: [TableRef]) -> (Bool, String?, String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (false, nil, nil) }
        
        // Tokenize and look at last few tokens
        let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard tokens.count >= 2 else { return (false, nil, nil) }
        
        let lastToken = tokens.last!.uppercased()
        let operators = Set(["=", "<>", "!=", ">=", "<=", ">", "<", "LIKE", "ILIKE", "BETWEEN"])
        
        // Check if the last complete token is an operator
        // (but the user might have started typing a value, so check second-to-last too)
        var opIndex: Int? = nil
        if operators.contains(lastToken) {
            opIndex = tokens.count - 1
        } else if tokens.count >= 3 {
            let secondLast = tokens[tokens.count - 2].uppercased()
            if operators.contains(secondLast) {
                opIndex = tokens.count - 2
            }
        }
        
        guard let oi = opIndex, oi > 0 else { return (false, nil, nil) }
        
        // The token before the operator should be a column reference
        let colToken = tokens[oi - 1].lowercased()
        
        // Resolve column: could be "table.column" or just "column"
        var colName: String
        var tableName: String?
        
        if colToken.contains(".") {
            let parts = colToken.split(separator: ".")
            if parts.count == 2 {
                let prefix = String(parts[0])
                colName = String(parts[1])
                tableName = resolveTableName(prefix, in: tables)
            } else {
                colName = colToken
                tableName = nil
            }
        } else {
            colName = colToken
            // Try to find which table owns this column
            tableName = tables.first(where: { ref in
                tableColumns[ref.name]?.contains(where: { $0.name.lowercased() == colName }) ?? false
            })?.name
        }
        
        return (true, colName, tableName)
    }
    
    // MARK: - Helpers
    
    /// Resolves a prefix (table name or alias) to the actual table name.
    private func resolveTableName(_ prefix: String, in refs: [TableRef]) -> String? {
        let lower = prefix.lowercased()
        
        // Check aliases first
        if let ref = refs.first(where: { $0.alias == lower }) {
            return ref.name
        }
        // Check table names
        if let ref = refs.first(where: { $0.name == lower }) {
            return ref.name
        }
        // Check if it's a known table not in refs
        if tableNames.contains(lower) {
            return lower
        }
        return nil
    }
    
    private func isKeyword(_ token: String) -> Bool {
        let keywords: Set<String> = [
            "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "JOIN",
            "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "OUTER", "NATURAL",
            "ON", "USING", "SET", "VALUES", "INTO", "INSERT", "UPDATE",
            "DELETE", "CREATE", "ALTER", "DROP", "ORDER", "BY", "GROUP",
            "HAVING", "LIMIT", "OFFSET", "UNION", "EXCEPT", "INTERSECT",
            "AS", "DISTINCT", "ALL", "EXISTS", "CASE", "WHEN", "THEN",
            "ELSE", "END", "RETURNING", "WITH", "RECURSIVE", "LIKE", "ILIKE",
            "BETWEEN", "IS", "NULL", "TRUE", "FALSE", "ASC", "DESC",
            "EXPLAIN", "ANALYZE", "BEGIN", "COMMIT", "ROLLBACK",
            "TRUNCATE", "GRANT", "REVOKE", "FETCH", "NEXT", "ROWS", "ONLY",
            "DO", "NOTHING", "CONFLICT", "DEFAULT",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CHECK", "CONSTRAINT",
            "CASCADE", "RESTRICT", "INDEX", "VIEW", "MATERIALIZED", "SCHEMA",
            "TABLE", "DATABASE", "SEQUENCE", "FUNCTION", "TRIGGER", "TYPE", "EXTENSION"
        ]
        return keywords.contains(token.uppercased())
    }
    
    private func isIdentifier(_ token: String) -> Bool {
        guard let first = token.first else { return false }
        if !(first.isLetter || first == "_") { return false }
        return token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
    }
    
    private func filterCompletions(_ items: [(String, String)], filter: String, type: SQLCompletionType) -> [SQLCompletion] {
        return items
            .filter { filter.isEmpty || $0.0.lowercased().hasPrefix(filter.lowercased()) }
            .map { SQLCompletion(text: $0.0, displayText: $0.0, type: type, detail: $0.1) }
    }
    
    /// Invalidates the value cache for a specific table or all tables.
    func invalidateValueCache(table: String? = nil) {
        if let t = table {
            let prefix = t.lowercased() + "."
            valueCache = valueCache.filter { !$0.key.hasPrefix(prefix) }
        } else {
            valueCache.removeAll()
        }
    }
}
