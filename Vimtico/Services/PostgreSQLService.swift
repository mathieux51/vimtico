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
                    // Try typed decoding first, since the extended query protocol
                    // sends binary data. Raw bytes won't work for types like UUID,
                    // integers, booleans, dates, etc.
                    // Date must come before numeric types because PostgreSQL
                    // timestamps are stored as Int64 microseconds in binary,
                    // which could be incorrectly decoded as a number.
                    if let value = try? column.decode(String.self) {
                        rowValues.append(value)
                    } else if let value = try? column.decode(Date.self) {
                        let formatter = ISO8601DateFormatter()
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        rowValues.append(formatter.string(from: value))
                    } else if let value = try? column.decode(UUID.self) {
                        rowValues.append(value.uuidString.lowercased())
                    } else if let value = try? column.decode(Bool.self) {
                        rowValues.append(value ? "true" : "false")
                    } else if let value = try? column.decode(Int.self) {
                        rowValues.append(String(value))
                    } else if let value = try? column.decode(Int64.self) {
                        rowValues.append(String(value))
                    } else if let value = try? column.decode(Double.self) {
                        rowValues.append(String(value))
                    } else if let value = try? column.decode(Float.self) {
                        rowValues.append(String(value))
                    } else if let bytes = column.bytes {
                        rowValues.append(String(buffer: bytes))
                    } else {
                        rowValues.append("NULL")
                    }
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
    func fetchTableStats(for table: DatabaseTable) async -> (rowCount: Int?, tableSize: String?) {
        do {
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
        } catch {
            return (nil, nil)
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
private func cleanupErrorDescription(_ raw: String) -> String {
    var message = raw
    
    // Remove the "PSQLError(...)" wrapper if present
    if message.hasPrefix("PSQLError(") {
        message = String(message.dropFirst("PSQLError(".count))
        if message.hasSuffix(")") {
            message = String(message.dropLast())
        }
    }
    
    // Extract key fields if present in structured format
    var parts: [String] = []
    
    // Look for serverInfo fields: message, detail, hint, code
    if let msgRange = message.range(of: "message: \"") {
        let start = msgRange.upperBound
        if let endQuote = message[start...].firstIndex(of: "\"") {
            parts.append(String(message[start..<endQuote]))
        }
    }
    
    if let detailRange = message.range(of: "detail: \"") {
        let start = detailRange.upperBound
        if let endQuote = message[start...].firstIndex(of: "\"") {
            parts.append("Detail: \(message[start..<endQuote])")
        }
    }
    
    if let hintRange = message.range(of: "hint: \"") {
        let start = hintRange.upperBound
        if let endQuote = message[start...].firstIndex(of: "\"") {
            parts.append("Hint: \(message[start..<endQuote])")
        }
    }
    
    if !parts.isEmpty {
        return parts.joined(separator: ". ")
    }
    
    // If we couldn't parse structured fields, return the cleaned-up raw description.
    // Trim to a reasonable length for display.
    if message.count > 500 {
        return String(message.prefix(500)) + "..."
    }
    
    return message
}
