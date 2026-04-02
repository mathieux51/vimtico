import Foundation

struct DatabaseConnection: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int
    var database: String
    var username: String
    var password: String
    var useSSL: Bool
    
    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "localhost",
        port: Int = 5432,
        database: String = "",
        username: String = "",
        password: String = "",
        useSSL: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.password = password
        self.useSSL = useSSL
    }
    
    var displayName: String {
        name.isEmpty ? "\(username)@\(host):\(port)/\(database)" : name
    }
    
    var connectionString: String {
        var components = ["postgresql://"]
        components.append("\(username):\(password)@")
        components.append("\(host):\(port)")
        components.append("/\(database)")
        if useSSL {
            components.append("?sslmode=require")
        }
        return components.joined()
    }
}

struct DatabaseTable: Identifiable, Hashable {
    let id = UUID()
    let schema: String
    let name: String
    let type: TableType
    
    enum TableType: String {
        case table = "TABLE"
        case view = "VIEW"
        case materializedView = "MATERIALIZED VIEW"
    }
    
    var fullName: String {
        "\(schema).\(name)"
    }
}

struct DatabaseColumn: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let dataType: String
    let isNullable: Bool
    let defaultValue: String?
    let isPrimaryKey: Bool
}
