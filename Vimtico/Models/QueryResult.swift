import Foundation

struct QueryResult: Identifiable {
    let id = UUID()
    let columns: [String]
    let rows: [[String]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let error: String?
    
    init(
        columns: [String] = [],
        rows: [[String]] = [],
        rowsAffected: Int = 0,
        executionTime: TimeInterval = 0,
        error: String? = nil
    ) {
        self.columns = columns
        self.rows = rows
        self.rowsAffected = rowsAffected
        self.executionTime = executionTime
        self.error = error
    }
    
    var isSuccess: Bool {
        error == nil
    }
    
    var summary: String {
        if let error = error {
            return "Error: \(error)"
        }
        
        if !columns.isEmpty {
            return "\(rows.count) row(s) returned in \(String(format: "%.3f", executionTime))s"
        }
        
        return "\(rowsAffected) row(s) affected in \(String(format: "%.3f", executionTime))s"
    }
}

struct QueryHistoryItem: Identifiable, Codable {
    let id: UUID
    let query: String
    let timestamp: Date
    let connectionId: UUID
    let wasSuccessful: Bool
    
    init(query: String, connectionId: UUID, wasSuccessful: Bool) {
        self.id = UUID()
        self.query = query
        self.timestamp = Date()
        self.connectionId = connectionId
        self.wasSuccessful = wasSuccessful
    }
}
