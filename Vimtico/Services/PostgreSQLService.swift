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
        
        // Bind to let constants so they can be safely captured in concurrent code
        let host = effectiveHost
        let port = effectivePort
        
        do {
            let config = PostgresConnection.Configuration(
                host: host,
                port: port,
                username: dbConnection.username,
                password: dbConnection.password,
                database: dbConnection.database,
                tls: dbConnection.useSSL ? .require(try .init(configuration: .clientDefault)) : .disable
            )
            
            // Connect with a 5-second timeout to avoid hanging on unreachable servers
            connection = try await withThrowingTaskGroup(of: PostgresConnection.self) { group in
                group.addTask {
                    try await PostgresConnection.connect(
                        on: self.eventLoopGroup.next(),
                        configuration: config,
                        id: 1,
                        logger: self.logger
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    throw PostgresError.connectionFailed(
                        "Connection timed out after 5 seconds. Verify that PostgreSQL is running on \(host):\(port) and is reachable."
                    )
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch let error as PostgresError {
            // Re-throw our own errors as-is
            throw error
        } catch {
            let message = extractPostgresErrorMessage(error)
            
            // Provide contextual hints for common connection issues
            if message.lowercased().contains("connection refused") || message.lowercased().contains("could not connect") {
                throw PostgresError.connectionFailed(
                    "\(message). Verify that PostgreSQL is running on \(host):\(port) and accepting connections."
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
    
    /// Lightweight health check. Runs `select 1` with a 5-second timeout.
    /// Returns `true` if the connection is alive, `false` otherwise.
    func ping() async -> Bool {
        guard let conn = connection else { return false }
        do {
            let alive = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    let rows = try await conn.query("select 1", logger: self.logger)
                    // Drain the result stream
                    for try await _ in rows {}
                    return true
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    throw PostgresError.connectionFailed("Ping timed out after 5 seconds")
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            return alive
        } catch {
            return false
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
            // numeric/decimal: parse binary format to preserve exact precision and scale.
            // PostgresNIO's String.self decode interprets binary numeric as UTF-8, producing garbage.
            if var buf = column.bytes {
                if let value = decodeNumericFromBuffer(&buf) {
                    return value
                }
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
            
        case .textArray, .varcharArray:
            if let value = try? column.decode([String].self) {
                return formatPgArray(value)
            }
        case .int2Array:
            if let value = try? column.decode([Int16].self) {
                return formatPgArray(value.map { String($0) })
            }
        case .int4Array:
            if let value = try? column.decode([Int32].self) {
                return formatPgArray(value.map { String($0) })
            }
        case .int8Array:
            if let value = try? column.decode([Int64].self) {
                return formatPgArray(value.map { String($0) })
            }
        case .float4Array:
            if let value = try? column.decode([Float].self) {
                return formatPgArray(value.map { String($0) })
            }
        case .float8Array:
            if let value = try? column.decode([Double].self) {
                return formatPgArray(value.map { String($0) })
            }
        case .boolArray:
            if let value = try? column.decode([Bool].self) {
                return formatPgArray(value.map { $0 ? "t" : "f" })
            }
        case .uuidArray:
            if let value = try? column.decode([UUID].self) {
                return formatPgArray(value.map { $0.uuidString.lowercased() })
            }
        case .jsonbArray:
            if let value = try? column.decode([String].self) {
                return formatPgArray(value)
            }
        case .numericArray:
            // Can't use [String].self or [Decimal].self for numeric arrays.
            // Parse the binary array format manually and decode each element.
            if var buf = column.bytes {
                if let elements = decodeNumericArray(&buf) {
                    return formatPgArray(elements)
                }
            }
        case .timestamptzArray:
            if let value = try? column.decode([Date].self) {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"
                f.timeZone = TimeZone(identifier: "UTC")
                return formatPgArray(value.map { f.string(from: $0) })
            }
            
        // MARK: - Network address types
            
        case .inet, .cidr:
            // Binary format: 1 byte family (2=IPv4, 3=IPv6), 1 byte prefix bits,
            // 1 byte is_cidr, 1 byte address length, then address bytes
            if var buf = column.bytes, buf.readableBytes >= 4 {
                if let family = buf.readInteger(as: UInt8.self),
                   let prefixBits = buf.readInteger(as: UInt8.self),
                   let isCidr = buf.readInteger(as: UInt8.self),
                   let addrLen = buf.readInteger(as: UInt8.self),
                   buf.readableBytes >= Int(addrLen) {
                    if family == 2 && addrLen == 4 {
                        // IPv4
                        let bytes = (0..<4).compactMap { _ in buf.readInteger(as: UInt8.self) }
                        if bytes.count == 4 {
                            let addr = bytes.map { String($0) }.joined(separator: ".")
                            if isCidr == 1 || column.dataType == .cidr {
                                return "\(addr)/\(prefixBits)"
                            }
                            return prefixBits < 32 ? "\(addr)/\(prefixBits)" : addr
                        }
                    } else if family == 3 && addrLen == 16 {
                        // IPv6
                        var groups: [String] = []
                        for _ in 0..<8 {
                            if let hi = buf.readInteger(as: UInt8.self),
                               let lo = buf.readInteger(as: UInt8.self) {
                                groups.append(String(format: "%x", (UInt16(hi) << 8) | UInt16(lo)))
                            }
                        }
                        if groups.count == 8 {
                            let addr = groups.joined(separator: ":")
                            if isCidr == 1 || column.dataType == .cidr {
                                return "\(addr)/\(prefixBits)"
                            }
                            return prefixBits < 128 ? "\(addr)/\(prefixBits)" : addr
                        }
                    }
                }
            }
            
        case .macaddr:
            // Binary format: 6 bytes
            if let buf = column.bytes, buf.readableBytesView.count == 6 {
                return buf.readableBytesView.map { String(format: "%02x", $0) }.joined(separator: ":")
            }
            
        case .macaddr8:
            // Binary format: 8 bytes
            if let buf = column.bytes, buf.readableBytesView.count == 8 {
                return buf.readableBytesView.map { String(format: "%02x", $0) }.joined(separator: ":")
            }
            
        // MARK: - Money
            
        case .money:
            // Binary format: Int64, value in cents
            if var buf = column.bytes, buf.readableBytes == 8,
               let cents = buf.readInteger(as: Int64.self) {
                let dollars = cents / 100
                let remainder = abs(cents % 100)
                let sign = cents < 0 ? "-" : ""
                return String(format: "%@$%lld.%02lld", sign, abs(dollars), remainder)
            }
            
        // MARK: - Geometric types
            
        case .point:
            // Binary format: two Float64 (x, y)
            if var buf = column.bytes, buf.readableBytes == 16,
               let x = buf.readInteger(as: UInt64.self),
               let y = buf.readInteger(as: UInt64.self) {
                let xVal = Double(bitPattern: x)
                let yVal = Double(bitPattern: y)
                return "(\(formatGeoDouble(xVal)),\(formatGeoDouble(yVal)))"
            }
            
        case .lseg:
            // Binary format: two points (4 Float64)
            if var buf = column.bytes, buf.readableBytes == 32 {
                if let x1 = buf.readInteger(as: UInt64.self),
                   let y1 = buf.readInteger(as: UInt64.self),
                   let x2 = buf.readInteger(as: UInt64.self),
                   let y2 = buf.readInteger(as: UInt64.self) {
                    let p1 = "(\(formatGeoDouble(Double(bitPattern: x1))),\(formatGeoDouble(Double(bitPattern: y1))))"
                    let p2 = "(\(formatGeoDouble(Double(bitPattern: x2))),\(formatGeoDouble(Double(bitPattern: y2))))"
                    return "[\(p1),\(p2)]"
                }
            }
            
        case .box:
            // Binary format: two points (4 Float64), high point first
            if var buf = column.bytes, buf.readableBytes == 32 {
                if let x1 = buf.readInteger(as: UInt64.self),
                   let y1 = buf.readInteger(as: UInt64.self),
                   let x2 = buf.readInteger(as: UInt64.self),
                   let y2 = buf.readInteger(as: UInt64.self) {
                    let p1 = "(\(formatGeoDouble(Double(bitPattern: x1))),\(formatGeoDouble(Double(bitPattern: y1))))"
                    let p2 = "(\(formatGeoDouble(Double(bitPattern: x2))),\(formatGeoDouble(Double(bitPattern: y2))))"
                    return "\(p1),\(p2)"
                }
            }
            
        case .line:
            // Binary format: three Float64 (A, B, C) for Ax + By + C = 0
            if var buf = column.bytes, buf.readableBytes == 24,
               let a = buf.readInteger(as: UInt64.self),
               let b = buf.readInteger(as: UInt64.self),
               let c = buf.readInteger(as: UInt64.self) {
                return "{\(formatGeoDouble(Double(bitPattern: a))),\(formatGeoDouble(Double(bitPattern: b))),\(formatGeoDouble(Double(bitPattern: c)))}"
            }
            
        case .circle:
            // Binary format: point (2 Float64) + radius (Float64)
            if var buf = column.bytes, buf.readableBytes == 24,
               let x = buf.readInteger(as: UInt64.self),
               let y = buf.readInteger(as: UInt64.self),
               let r = buf.readInteger(as: UInt64.self) {
                return "<(\(formatGeoDouble(Double(bitPattern: x))),\(formatGeoDouble(Double(bitPattern: y)))),\(formatGeoDouble(Double(bitPattern: r)))>"
            }
            
        case .path:
            // Binary format: 1 byte closed flag, Int32 point count, then N points (each 2 Float64)
            if var buf = column.bytes, buf.readableBytes >= 5 {
                if let closed = buf.readInteger(as: UInt8.self),
                   let count = buf.readInteger(as: Int32.self),
                   buf.readableBytes == Int(count) * 16 {
                    var points: [String] = []
                    for _ in 0..<count {
                        if let x = buf.readInteger(as: UInt64.self),
                           let y = buf.readInteger(as: UInt64.self) {
                            points.append("(\(formatGeoDouble(Double(bitPattern: x))),\(formatGeoDouble(Double(bitPattern: y))))")
                        }
                    }
                    if points.count == Int(count) {
                        let joined = points.joined(separator: ",")
                        return closed == 1 ? "(\(joined))" : "[\(joined)]"
                    }
                }
            }
            
        case .polygon:
            // Binary format: Int32 point count, then N points (each 2 Float64)
            if var buf = column.bytes, buf.readableBytes >= 4 {
                if let count = buf.readInteger(as: Int32.self),
                   buf.readableBytes == Int(count) * 16 {
                    var points: [String] = []
                    for _ in 0..<count {
                        if let x = buf.readInteger(as: UInt64.self),
                           let y = buf.readInteger(as: UInt64.self) {
                            points.append("(\(formatGeoDouble(Double(bitPattern: x))),\(formatGeoDouble(Double(bitPattern: y))))")
                        }
                    }
                    if points.count == Int(count) {
                        return "(\(points.joined(separator: ",")))"
                    }
                }
            }
            
        // MARK: - Full-text search
            
        case .tsvector:
            // Binary format: Int32 lexeme count, then for each:
            //   null-terminated string, Int16 position count, then positions (each UInt16)
            if var buf = column.bytes, buf.readableBytes >= 4 {
                if let lexemeCount = buf.readInteger(as: Int32.self) {
                    var lexemes: [String] = []
                    for _ in 0..<lexemeCount {
                        // Read null-terminated string
                        if let nullIndex = buf.readableBytesView.firstIndex(of: 0) {
                            let len = nullIndex - buf.readableBytesView.startIndex
                            if let word = buf.readString(length: len) {
                                buf.moveReaderIndex(forwardBy: 1) // skip null byte
                                var entry = "'\(word)'"
                                // Read position count
                                if let posCount = buf.readInteger(as: Int16.self), posCount > 0 {
                                    var positions: [String] = []
                                    for _ in 0..<posCount {
                                        if let pos = buf.readInteger(as: UInt16.self) {
                                            let position = pos & 0x3FFF // lower 14 bits
                                            let weight = (pos >> 14) & 0x03
                                            let weightChar: String
                                            switch weight {
                                            case 3: weightChar = "A"
                                            case 2: weightChar = "B"
                                            case 1: weightChar = "C"
                                            default: weightChar = ""
                                            }
                                            positions.append("\(position)\(weightChar)")
                                        }
                                    }
                                    entry += ":\(positions.joined(separator: ","))"
                                }
                                lexemes.append(entry)
                            } else { break }
                        } else { break }
                    }
                    if !lexemes.isEmpty {
                        return lexemes.joined(separator: " ")
                    }
                }
            }
            
        case .tsquery:
            // tsquery binary format is complex (tree of operators and operands).
            // Fall through to String.self which may work for text-format results.
            // For binary format, show raw hex as fallback.
            break
            
        // MARK: - Bit string types
            
        case .bit, .varbit:
            // Binary format: Int32 bit count, then ceil(bitCount/8) bytes
            if var buf = column.bytes, buf.readableBytes >= 4 {
                if let bitCount = buf.readInteger(as: Int32.self), bitCount >= 0 {
                    let byteCount = (Int(bitCount) + 7) / 8
                    if buf.readableBytes == byteCount {
                        var bits = ""
                        var remaining = Int(bitCount)
                        for _ in 0..<byteCount {
                            if let byte = buf.readInteger(as: UInt8.self) {
                                let bitsInThisByte = min(remaining, 8)
                                for j in (8 - bitsInThisByte)..<8 {
                                    bits += (byte & (1 << (7 - j))) != 0 ? "1" : "0"
                                }
                                remaining -= bitsInThisByte
                            }
                        }
                        return bits
                    }
                }
            }
            
        // MARK: - Range types
            
        case .int4Range:
            return decodeRange(column, boundDecoder: { buf in
                buf.readInteger(as: Int32.self).map { String($0) }
            })
        case .int8Range:
            return decodeRange(column, boundDecoder: { buf in
                buf.readInteger(as: Int64.self).map { String($0) }
            })
        case .numrange:
            return decodeRange(column, boundDecoder: { buf in
                decodeNumericFromBuffer(&buf)
            })
        case .daterange:
            return decodeRange(column, boundDecoder: { buf in
                // date: Int32 days since 2000-01-01
                guard let days = buf.readInteger(as: Int32.self) else { return nil }
                let epoch = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 2000, month: 1, day: 1).date!
                let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: Int(days), to: epoch)!
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.timeZone = TimeZone(identifier: "UTC")
                return f.string(from: date)
            })
        case .tsrange:
            return decodeRange(column, boundDecoder: { buf in
                // timestamp: Int64 microseconds since 2000-01-01
                guard let micros = buf.readInteger(as: Int64.self) else { return nil }
                let epoch = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 2000, month: 1, day: 1).date!
                let date = epoch.addingTimeInterval(Double(micros) / 1_000_000.0)
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                f.timeZone = TimeZone(identifier: "UTC")
                return f.string(from: date)
            })
        case .tstzrange:
            return decodeRange(column, boundDecoder: { buf in
                guard let micros = buf.readInteger(as: Int64.self) else { return nil }
                let epoch = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 2000, month: 1, day: 1).date!
                let date = epoch.addingTimeInterval(Double(micros) / 1_000_000.0)
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
                f.timeZone = TimeZone(identifier: "UTC")
                return f.string(from: date)
            })
            
        // MARK: - XML (text-based, but explicitly handled to be safe)
        case .xml:
            if let value = try? column.decode(String.self) {
                return value
            }
            
        default:
            // Try to detect pgvector binary format: 2-byte dimension count + N * 4-byte float32
            // This handles USER-DEFINED types like vector where the OID is installation-specific
            if var buf = column.bytes, buf.readableBytes >= 4 {
                let savedReaderIndex = buf.readerIndex
                if let dim = buf.readInteger(as: UInt16.self),
                   buf.readableBytes == Int(dim) * 4 + 2, // +2 for unused flags
                   let _ = buf.readInteger(as: UInt16.self) { // unused flags
                    var floats: [String] = []
                    floats.reserveCapacity(Int(dim))
                    for _ in 0..<dim {
                        if let bits = buf.readInteger(as: UInt32.self) {
                            let value = Float(bitPattern: bits)
                            floats.append(String(value))
                        }
                    }
                    if floats.count == Int(dim) {
                        return "[" + floats.joined(separator: ",") + "]"
                    }
                }
                buf.moveReaderIndex(to: savedReaderIndex)
            }
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
    
    /// Formats an array of strings as a PostgreSQL array literal: {el1,el2,...}
    /// Elements containing commas, quotes, braces, backslashes, or whitespace are quoted.
    private func formatPgArray(_ elements: [String]) -> String {
        let formatted = elements.map { el in
            if el.isEmpty || el.rangeOfCharacter(from: CharacterSet(charactersIn: ",\"{}\\  \t\n")) != nil {
                return "\"" + el.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
            return el
        }
        return "{" + formatted.joined(separator: ",") + "}"
    }
    
    /// Formats a Double for geometric type display, stripping unnecessary trailing zeros.
    private func formatGeoDouble(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        let str = String(value)
        return str
    }
    
    /// Decodes a PostgreSQL range from binary format.
    /// Range binary format: 1 byte flags, then optional lower/upper bounds.
    /// Flags: 0x01=empty, 0x02=lower inclusive, 0x04=upper inclusive, 0x08=lower infinite, 0x10=upper infinite
    private func decodeRange(_ column: PostgresCell, boundDecoder: (inout ByteBuffer) -> String?) -> String {
        guard var buf = column.bytes, buf.readableBytes >= 1,
              let flags = buf.readInteger(as: UInt8.self) else {
            return "NULL"
        }
        
        let isEmpty = (flags & 0x01) != 0
        if isEmpty { return "empty" }
        
        let lowerInclusive = (flags & 0x02) != 0
        let upperInclusive = (flags & 0x04) != 0
        let lowerInfinite = (flags & 0x08) != 0
        let upperInfinite = (flags & 0x10) != 0
        
        var lowerStr = ""
        if lowerInfinite {
            lowerStr = ""
        } else if let len = buf.readInteger(as: Int32.self), len > 0,
                  var boundBuf = buf.readSlice(length: Int(len)) {
            lowerStr = boundDecoder(&boundBuf) ?? ""
        }
        
        var upperStr = ""
        if upperInfinite {
            upperStr = ""
        } else if let len = buf.readInteger(as: Int32.self), len > 0,
                  var boundBuf = buf.readSlice(length: Int(len)) {
            upperStr = boundDecoder(&boundBuf) ?? ""
        }
        
        let leftBracket = lowerInclusive ? "[" : "("
        let rightBracket = upperInclusive ? "]" : ")"
        return "\(leftBracket)\(lowerStr),\(upperStr)\(rightBracket)"
    }
    
    /// Decodes a PostgreSQL numeric value from a ByteBuffer (binary format).
    /// Numeric binary format: Int16 ndigits, Int16 weight, Int16 sign (0=pos, 0x4000=neg, 0xC000=NaN),
    /// Int16 dscale, then ndigits * Int16 base-10000 digits.
    private func decodeNumericFromBuffer(_ buf: inout ByteBuffer) -> String? {
        guard buf.readableBytes >= 8,
              let ndigits = buf.readInteger(as: Int16.self),
              let weight = buf.readInteger(as: Int16.self),
              let sign = buf.readInteger(as: UInt16.self),
              let dscale = buf.readInteger(as: Int16.self) else { return nil }
        
        if sign == 0xC000 { return "NaN" }
        
        var digits: [Int16] = []
        for _ in 0..<ndigits {
            guard let d = buf.readInteger(as: Int16.self) else { return nil }
            digits.append(d)
        }
        
        if ndigits == 0 {
            if dscale > 0 {
                return (sign == 0x4000 ? "-0." : "0.") + String(repeating: "0", count: Int(dscale))
            }
            return sign == 0x4000 ? "-0" : "0"
        }
        
        // Build integer part
        var intPart = ""
        let intDigitCount = Int(weight) + 1
        for i in 0..<intDigitCount {
            let d = i < digits.count ? digits[i] : 0
            if i == 0 {
                intPart += String(d) // no leading zeros on first group
            } else {
                intPart += String(format: "%04d", d)
            }
        }
        if intPart.isEmpty { intPart = "0" }
        
        // Build fractional part
        var fracPart = ""
        if dscale > 0 {
            for i in intDigitCount..<digits.count {
                fracPart += String(format: "%04d", digits[i])
            }
            // Pad to dscale if needed
            while fracPart.count < Int(dscale) { fracPart += "0" }
            // Trim to dscale
            fracPart = String(fracPart.prefix(Int(dscale)))
        }
        
        let prefix = sign == 0x4000 ? "-" : ""
        if fracPart.isEmpty {
            return prefix + intPart
        }
        return prefix + intPart + "." + fracPart
    }
    
    /// Decodes a PostgreSQL numeric[] from binary array format.
    /// Binary array format: Int32 ndim (0 or 1), Int32 flags, UInt32 element OID,
    /// Int32 array length, Int32 lower bound (1), then for each element: Int32 len + bytes (-1 for null).
    private func decodeNumericArray(_ buf: inout ByteBuffer) -> [String]? {
        guard let ndim = buf.readInteger(as: Int32.self),
              let _ = buf.readInteger(as: Int32.self), // flags
              let _ = buf.readInteger(as: UInt32.self) // element OID
        else { return nil }
        
        if ndim == 0 { return [] }
        guard ndim == 1 else { return nil }
        
        guard let count = buf.readInteger(as: Int32.self),
              let _ = buf.readInteger(as: Int32.self) // lower bound
        else { return nil }
        
        var elements: [String] = []
        for _ in 0..<count {
            guard let len = buf.readInteger(as: Int32.self) else { return nil }
            if len == -1 {
                elements.append("NULL")
            } else if var elementBuf = buf.readSlice(length: Int(len)) {
                elements.append(decodeNumericFromBuffer(&elementBuf) ?? "NULL")
            } else {
                return nil
            }
        }
        return elements
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
            logger.warning("fetchDistinctValues failed for \(table).\(column): \(error.localizedDescription)")
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
    case queryTimeout(seconds: Int)
    
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
        case .queryTimeout(let seconds):
            return "Query timed out after \(seconds) seconds. The query may still be running on the server. Consider using EXPLAIN ANALYZE to check query performance, or cancel it manually."
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
