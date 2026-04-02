import Foundation
import PostgresNIO
import NIOCore
import NIOPosix
import Logging

actor PostgreSQLService {
    private var connection: PostgresConnection?
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let logger = Logger(label: "com.mathieux51.vimtico.postgres")
    
    struct QueryResponse {
        let columns: [String]
        let rows: [[String]]
        let rowsAffected: Int
    }
    
    func connect(to dbConnection: DatabaseConnection) async throws {
        let config = PostgresConnection.Configuration(
            host: dbConnection.host,
            port: dbConnection.port,
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
    }
    
    func disconnect() async {
        if let conn = connection {
            try? await conn.close()
            connection = nil
        }
    }
    
    func executeQuery(_ sql: String) async throws -> QueryResponse {
        guard let conn = connection else {
            throw PostgresError.connectionClosed
        }
        
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
                if let bytes = column.bytes {
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
    
    deinit {
        try? eventLoopGroup.syncShutdownGracefully()
    }
}

enum PostgresError: LocalizedError {
    case connectionClosed
    case queryFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .connectionClosed:
            return "Database connection is closed"
        case .queryFailed(let message):
            return "Query failed: \(message)"
        }
    }
}
