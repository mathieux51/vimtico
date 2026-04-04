import Foundation
import PostgresNIO
import NIOCore
import NIOPosix
import Logging

actor PostgreSQLService {
    private var connection: PostgresConnection?
    private var sshTunnel: SSHTunnelService?
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let logger = Logger(label: "com.mathieux51.vimtico.postgres")
    
    struct QueryResponse {
        let columns: [String]
        let rows: [[String]]
        let rowsAffected: Int
    }
    
    func connect(to dbConnection: DatabaseConnection) async throws {
        // If SSH tunnel is enabled, establish it first
        var effectiveHost = dbConnection.host
        var effectivePort = dbConnection.port
        
        if dbConnection.sshEnabled {
            let tunnel = SSHTunnelService()
            
            do {
                let localPort = try await tunnel.connect(
                    sshHost: dbConnection.sshHost,
                    sshPort: dbConnection.sshPort,
                    sshUsername: dbConnection.sshUsername,
                    sshPassword: dbConnection.sshUseKeyAuth ? nil : dbConnection.sshPassword,
                    sshKeyPath: dbConnection.sshUseKeyAuth ? dbConnection.sshKeyPath : nil,
                    useKeyAuth: dbConnection.sshUseKeyAuth,
                    remoteHost: dbConnection.host,
                    remotePort: dbConnection.port
                )
                
                sshTunnel = tunnel
                effectiveHost = "127.0.0.1"
                effectivePort = localPort
            } catch {
                throw PostgresError.sshTunnelFailed(extractPostgresErrorMessage(error))
            }
        }
        
        do {
            let config = PostgresConnection.Configuration(
                host: effectiveHost,
                port: effectivePort,
                username: dbConnection.username,
                password: dbConnection.password,
                database: dbConnection.database,
                tls: dbConnection.useSSL ? .require(try .init(configuration: .clientDefault)) : .disable
            )
            
            connection = try await PostgresConnection.connect(
                on: eventLoopGroup.next(),
                configuration: config,
                id: 1,
                logger: logger
            )
        } catch let error as PostgresError {
            // Re-throw our own errors as-is
            throw error
        } catch {
            let message = extractPostgresErrorMessage(error)
            
            // Provide contextual hints for common connection issues
            if message.lowercased().contains("connection refused") || message.lowercased().contains("could not connect") {
                throw PostgresError.connectionFailed(
                    "\(message). Verify that PostgreSQL is running on \(effectiveHost):\(effectivePort) and accepting connections."
                )
            } else if message.lowercased().contains("password") || message.lowercased().contains("authentication") {
                throw PostgresError.connectionFailed(
                    "\(message). Check your username and password for database '\(dbConnection.database)'."
                )
            } else if message.lowercased().contains("ssl") || message.lowercased().contains("tls") {
                throw PostgresError.tlsError(
                    "\(message). Try toggling the SSL/TLS setting for this connection."
                )
            } else if message.lowercased().contains("does not exist") {
                throw PostgresError.connectionFailed(
                    "\(message). Verify the database name '\(dbConnection.database)' is correct."
                )
            } else {
                throw PostgresError.connectionFailed(message)
            }
        }
    }
    
    func disconnect() async {
        if let conn = connection {
            try? await conn.close()
            connection = nil
        }
        
        // Also close SSH tunnel if active
        if let tunnel = sshTunnel {
            await tunnel.disconnect()
            sshTunnel = nil
        }
    }
    
    func executeQuery(_ sql: String) async throws -> QueryResponse {
        guard let conn = connection else {
            throw PostgresError.connectionClosed
        }
        
        do {
            let rows = try await conn.query(PostgresQuery(stringLiteral: sql), logger: logger)
            
            var columns: [String] = []
            var resultRows: [[String]] = []
            var isFirstRow = true
            
            for try await row in rows {
                if isFirstRow {
                    columns = row.map { $0.columnName }
                    isFirstRow = false
                }
                
                var rowValues: [String] = []
                for column in row {
                    // Route by PostgreSQL data type first for types where the
                    // binary representation is NOT valid UTF-8 and would
                    // produce garbage if decoded as String.
                    let value = decodeCell(column)
                    rowValues.append(value)
                }
                resultRows.append(rowValues)
            }
            
            return QueryResponse(
                columns: columns,
                rows: resultRows,
                rowsAffected: resultRows.count
            )
        } catch let error as PostgresError {
            throw error
        } catch {
            throw PostgresError.queryFailed(extractPostgresErrorMessage(error))
        }
    }
    
    // MARK: - Cell Decoding
    
    /// Decodes a PostgresCell into a display string, handling binary-encoded types
    /// that would produce garbage if naively decoded as String.
    private func decodeCell(_ column: PostgresCell) -> String {
        guard column.bytes != nil else { return "NULL" }
        
        // For types whose binary format is NOT UTF-8 text, decode specially
        // BEFORE trying String.self (which has a greedy default case that
        // interprets any bytes as UTF-8, producing garbage for binary data).
        switch column.dataType {
        case .timestamp, .timestamptz, .date:
            if let value = try? column.decode(Date.self) {
                if column.dataType == .date {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd"
                    f.timeZone = TimeZone(identifier: "UTC")
                    return f.string(from: value)
                } else {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
                    f.timeZone = TimeZone(identifier: "UTC")
                    return f.string(from: value)
                }
            }
            
        case .time, .timetz:
            // time: Int64 microseconds since midnight
            // timetz: Int64 microseconds + Int32 tz offset (seconds west of UTC)
            if var buf = column.bytes {
                if buf.readableBytes >= 8, let microseconds = buf.readInteger(as: Int64.self) {
                    let totalSeconds = microseconds / 1_000_000
                    let hours = totalSeconds / 3600
                    let minutes = (totalSeconds % 3600) / 60
                    let seconds = totalSeconds % 60
                    let frac = microseconds % 1_000_000
                    var result = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
                    if frac > 0 {
                        result += String(format: ".%06d", frac)
                        // Trim trailing zeros
                        while result.hasSuffix("0") { result.removeLast() }
                    }
                    // timetz has a 4-byte timezone offset
                    if column.dataType == .timetz, buf.readableBytes >= 4,
                       let tzOffset = buf.readInteger(as: Int32.self) {
                        // tzOffset is seconds west of UTC (negative = east)
                        let tzHours = abs(Int(tzOffset)) / 3600
                        let tzMinutes = (abs(Int(tzOffset)) % 3600) / 60
                        let sign = tzOffset <= 0 ? "+" : "-"
                        result += String(format: "%@%02d", sign, tzHours)
                        if tzMinutes > 0 {
                            result += String(format: ":%02d", tzMinutes)
                        }
                    }
                    return result
                }
            }
            
        case .interval:
            // interval: Int64 microseconds + Int32 days + Int32 months
            if var buf = column.bytes, buf.readableBytes >= 16 {
                if let microseconds = buf.readInteger(as: Int64.self),
                   let days = buf.readInteger(as: Int32.self),
                   let months = buf.readInteger(as: Int32.self) {
                    var parts: [String] = []
                    let years = months / 12
                    let remainingMonths = months % 12
                    if years != 0 { parts.append("\(years) year\(years == 1 ? "" : "s")") }
                    if remainingMonths != 0 { parts.append("\(remainingMonths) mon\(remainingMonths == 1 ? "" : "s")") }
                    if days != 0 { parts.append("\(days) day\(days == 1 ? "" : "s")") }
                    if microseconds != 0 {
                        let totalSec = abs(microseconds) / 1_000_000
                        let h = totalSec / 3600
                        let m = (totalSec % 3600) / 60
                        let s = totalSec % 60
                        let sign = microseconds < 0 ? "-" : ""
                        parts.append(String(format: "%@%02d:%02d:%02d", sign, h, m, s))
                    }
                    return parts.isEmpty ? "00:00:00" : parts.joined(separator: " ")
                }
            }
            
        case .numeric:
            // numeric/decimal: try Double first, fall back to string
            if let value = try? column.decode(Double.self) {
                // Format without trailing zeros
                let str = String(value)
                return str.hasSuffix(".0") ? String(str.dropLast(2)) : str
            }
            
        case .bool:
            if let value = try? column.decode(Bool.self) {
                return value ? "true" : "false"
            }
            
        case .uuid:
            if let value = try? column.decode(UUID.self) {
                return value.uuidString.lowercased()
            }
            
        case .int2:
            if let value = try? column.decode(Int16.self) { return String(value) }
        case .int4, .oid:
            if let value = try? column.decode(Int32.self) { return String(value) }
        case .int8:
            if let value = try? column.decode(Int64.self) { return String(value) }
        case .float4:
            if let value = try? column.decode(Float.self) { return String(value) }
        case .float8:
            if let value = try? column.decode(Double.self) { return String(value) }
            
        case .bytea:
            // Show hex representation for binary data
            if let buf = column.bytes {
                let hex = buf.readableBytesView.map { String(format: "%02x", $0) }.joined()
                return "\\x" + hex
            }
            
        default:
            break
        }
        
        // For text-like types and anything not handled above, try String
        if let value = try? column.decode(String.self) {
            return value
        }
        
        // Final fallback: show hex if there are bytes
        if let buf = column.bytes {
            let hex = buf.readableBytesView.map { String(format: "%02x", $0) }.joined()
            return "\\x" + hex
        }
        
        return "NULL"
    }
    
    func fetchTables() async throws -> [DatabaseTable] {
        let sql = """
        SELECT 
            table_schema,
            table_name,
            table_type
        FROM information_schema.tables
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
        ORDER BY table_schema, table_name
        """
        
        let response = try await executeQuery(sql)
        
        return response.rows.compactMap { row -> DatabaseTable? in
            guard row.count >= 3 else { return nil }
            
            let tableType: DatabaseTable.TableType
            switch row[2] {
            case "BASE TABLE":
                tableType = .table
            case "VIEW":
                tableType = .view
            default:
                tableType = .table
            }
            
            return DatabaseTable(
                schema: row[0],
                name: row[1],
                type: tableType
            )
        }
    }
    
    func fetchColumns(for table: DatabaseTable) async throws -> [DatabaseColumn] {
        let sql = """
        SELECT 
            c.column_name,
            c.data_type,
            c.is_nullable,
            c.column_default,
            CASE WHEN pk.column_name IS NOT NULL THEN true ELSE false END as is_primary_key
        FROM information_schema.columns c
        LEFT JOIN (
            SELECT ku.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage ku
                ON tc.constraint_name = ku.constraint_name
            WHERE tc.constraint_type = 'PRIMARY KEY'
                AND ku.table_schema = '\(table.schema)'
                AND ku.table_name = '\(table.name)'
        ) pk ON c.column_name = pk.column_name
        WHERE c.table_schema = '\(table.schema)'
            AND c.table_name = '\(table.name)'
        ORDER BY c.ordinal_position
        """
        
        let response = try await executeQuery(sql)
        
        return response.rows.compactMap { row -> DatabaseColumn? in
            guard row.count >= 5 else { return nil }
            
            return DatabaseColumn(
                name: row[0],
                dataType: row[1],
                isNullable: row[2] == "YES",
                defaultValue: row[3] == "NULL" ? nil : row[3],
                isPrimaryKey: row[4] == "true"
            )
        }
    }
    
    /// Validates a SQL query using EXPLAIN without executing it.
    /// Returns nil if valid, or an error message string if invalid.
    func validateQuery(_ sql: String) async -> String? {
        guard connection != nil else { return nil }
        
        var trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        // Strip trailing semicolons
        while trimmed.hasSuffix(";") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return nil }
        
        // EXPLAIN only supports DML statements
        let upper = trimmed.uppercased()
        let dmlPrefixes = ["SELECT", "INSERT", "UPDATE", "DELETE", "WITH", "VALUES", "TABLE"]
        guard dmlPrefixes.contains(where: { upper.hasPrefix($0) }) else { return nil }
        
        do {
            let rows = try await connection!.query(
                PostgresQuery(stringLiteral: "EXPLAIN \(trimmed)"),
                logger: logger
            )
            for try await _ in rows {}
            return nil
        } catch {
            return extractPostgresErrorMessage(error)
        }
    }
    
    /// Fetches approximate row count and table size using pg_stat and pg_class.
    /// Uses statistics rather than count(*) to avoid full table scans.
    func fetchTableStats(for table: DatabaseTable) async throws -> (rowCount: Int?, tableSize: String?) {
        let sql = """
        select
            coalesce(s.n_live_tup, 0)::text as approx_row_count,
            pg_size_pretty(pg_total_relation_size(c.oid)) as table_size
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        left join pg_stat_user_tables s on s.relid = c.oid
        where n.nspname = '\(table.schema)'
            and c.relname = '\(table.name)'
        """
        let response = try await executeQuery(sql)
        guard let row = response.rows.first, row.count >= 2 else {
            return (nil, nil)
        }
        return (Int(row[0]), row[1])
    }
    
    /// Fetch distinct values for a column in a table (used for autocomplete value suggestions)
    /// When filter is non-empty, applies server-side ILIKE filtering for high-cardinality columns.
    func fetchDistinctValues(table: String, column: String, filter: String = "", limit: Int = 50) async -> [String] {
        do {
            var sql = "select distinct \"\(column)\" from \"\(table)\" where \"\(column)\" is not null"
            if !filter.isEmpty {
                // Escape % and _ in filter to prevent LIKE pattern injection
                let escaped = filter
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                    .replacingOccurrences(of: "'", with: "''")
                sql += " and \"\(column)\"::text ilike '\(escaped)%'"
            }
            sql += " order by \"\(column)\" limit \(limit)"
            let response = try await executeQuery(sql)
            return response.rows.compactMap { $0.first }
        } catch {
            return []
        }
    }
    
    deinit {
        try? eventLoopGroup.syncShutdownGracefully()
    }
}

enum PostgresError: LocalizedError {
    case connectionClosed
    case connectionFailed(String)
    case queryFailed(String)
    case sshTunnelFailed(String)
    case tlsError(String)
    
    var errorDescription: String? {
        switch self {
        case .connectionClosed:
            return "Database connection is closed. Please reconnect and try again."
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .queryFailed(let message):
            return "Query failed: \(message)"
        case .sshTunnelFailed(let message):
            return "SSH tunnel error: \(message)"
        case .tlsError(let message):
            return "TLS/SSL error: \(message)"
        }
    }
}

/// Extracts a descriptive error message from PostgresNIO and other errors.
/// PostgresNIO's PSQLError.localizedDescription is often generic (e.g. "PSQLError error 1").
/// String(describing:) also gives a generic message to prevent data leakage.
/// This helper uses String(reflecting:) which includes server-provided error details such as
/// the SQLSTATE code, error message, detail, and hint fields.
func extractPostgresErrorMessage(_ error: Error) -> String {
    // String(reflecting:) on PSQLError includes the full server error info,
    // while localizedDescription and String(describing:) only give generic labels.
    let fullDescription = String(reflecting: error)
    
    // If the full description is more informative than localizedDescription, prefer it.
    let localizedDesc = error.localizedDescription
    
    // Check if localizedDescription is the generic/unhelpful one
    let isGeneric = localizedDesc.contains("PSQLError") && localizedDesc.contains("error ")
        && localizedDesc.count < 30
    
    if isGeneric && fullDescription.count > localizedDesc.count {
        // Clean up the description for display
        return cleanupErrorDescription(fullDescription)
    }
    
    // For non-PSQLError types, localizedDescription is usually fine
    if fullDescription.count > localizedDesc.count + 20 {
        return cleanupErrorDescription(fullDescription)
    }
    
    return localizedDesc
}

/// Cleans up raw PSQLError descriptions into user-friendly messages.
///
/// String(reflecting:) on PSQLError produces output in the format:
///   `code: server, serverInfo: [sqlState: 42601, file: scan.l, line: 1184,
///    message: syntax error at end of input, position: 34, routine: scanner_yyerror,
///    localizedSeverity: ERROR, severity: ERROR], triggeredFromRequestInFile: ...,
///    query: PostgresQuery(sql: ..., binds: [])`
///
/// The values are NOT quoted. They are comma-separated key-value pairs inside
/// a Swift dictionary description (square brackets). We extract the useful fields:
/// message, detail, hint, sqlState.
private func cleanupErrorDescription(_ raw: String) -> String {
    // Try to extract the serverInfo block: `serverInfo: [...]`
    if let serverInfoRange = raw.range(of: "serverInfo: [") {
        let afterOpen = serverInfoRange.upperBound
        // Find the matching closing bracket
        if let closingBracket = findMatchingBracket(in: raw, from: afterOpen) {
            let serverInfoContent = String(raw[afterOpen..<closingBracket])
            let fields = parseServerInfoFields(serverInfoContent)
            
            var parts: [String] = []
            
            if let msg = fields["message"], !msg.isEmpty {
                parts.append(msg)
            }
            
            if let detail = fields["detail"], !detail.isEmpty {
                parts.append("Detail: \(detail)")
            }
            
            if let hint = fields["hint"], !hint.isEmpty {
                parts.append("Hint: \(hint)")
            }
            
            if let sqlState = fields["sqlState"], !sqlState.isEmpty, !parts.isEmpty {
                parts[parts.count - 1] += " (SQLSTATE \(sqlState))"
            }
            
            if !parts.isEmpty {
                return parts.joined(separator: ". ")
            }
        }
    }
    
    // Fallback: return trimmed raw description
    if raw.count > 500 {
        return String(raw.prefix(500)) + "..."
    }
    return raw
}

/// Finds the closing `]` that matches the opening bracket position.
private func findMatchingBracket(in str: String, from start: String.Index) -> String.Index? {
    var depth = 1
    var index = start
    while index < str.endIndex {
        let ch = str[index]
        if ch == "[" {
            depth += 1
        } else if ch == "]" {
            depth -= 1
            if depth == 0 {
                return index
            }
        }
        index = str.index(after: index)
    }
    return nil
}

/// Parses the content inside `serverInfo: [...]` into a dictionary of key-value pairs.
///
/// The format is: `key1: value1, key2: value2, ...`
/// Values are NOT quoted and may contain colons (e.g. file paths), so we split
/// on `, ` followed by a known key name to avoid splitting inside values.
private func parseServerInfoFields(_ content: String) -> [String: String] {
    let knownKeys = ["sqlState", "file", "line", "message", "detail", "hint",
                     "position", "routine", "localizedSeverity", "severity",
                     "internalPosition", "internalQuery", "where", "schema",
                     "table", "column", "dataType", "constraint"]
    
    var fields: [String: String] = [:]
    
    // Build a regex-like split: find all occurrences of ", knownKey: "
    // and use them as delimiters to extract key-value pairs.
    var remaining = content.trimmingCharacters(in: .whitespaces)
    
    while !remaining.isEmpty {
        // Find the current key
        guard let colonRange = remaining.range(of: ": ") else {
            break
        }
        let key = remaining[remaining.startIndex..<colonRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        remaining = String(remaining[colonRange.upperBound...])
        
        // Find the next known key delimiter: ", knownKey: "
        var nextKeyStart: String.Index? = nil
        var nextKeyPrefixLength = 0
        
        for knownKey in knownKeys {
            let delimiter = ", \(knownKey): "
            if let range = remaining.range(of: delimiter) {
                if nextKeyStart == nil || range.lowerBound < nextKeyStart! {
                    nextKeyStart = range.lowerBound
                    nextKeyPrefixLength = delimiter.count
                }
            }
        }
        
        let value: String
        if let cutoff = nextKeyStart {
            value = String(remaining[remaining.startIndex..<cutoff])
                .trimmingCharacters(in: .whitespaces)
            let advanceBy = remaining.distance(from: remaining.startIndex, to: cutoff) + nextKeyPrefixLength
            // Move past the ", " but keep the "key: " part for the next iteration
            let nextStart = remaining.index(cutoff, offsetBy: 2) // skip ", "
            remaining = String(remaining[nextStart...])
        } else {
            // Last field
            value = remaining.trimmingCharacters(in: .whitespaces)
            remaining = ""
        }
        
        fields[key] = value
    }
    
    return fields
}
