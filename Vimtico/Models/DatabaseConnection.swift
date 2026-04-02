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
    
    // SSH Tunnel configuration
    var sshEnabled: Bool
    var sshHost: String
    var sshPort: Int
    var sshUsername: String
    var sshPassword: String
    var sshKeyPath: String
    var sshUseKeyAuth: Bool
    
    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "localhost",
        port: Int = 5432,
        database: String = "",
        username: String = "",
        password: String = "",
        useSSL: Bool = false,
        sshEnabled: Bool = false,
        sshHost: String = "",
        sshPort: Int = 22,
        sshUsername: String = "",
        sshPassword: String = "",
        sshKeyPath: String = "~/.ssh/id_rsa",
        sshUseKeyAuth: Bool = true
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.password = password
        self.useSSL = useSSL
        self.sshEnabled = sshEnabled
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.sshUsername = sshUsername
        self.sshPassword = sshPassword
        self.sshKeyPath = sshKeyPath
        self.sshUseKeyAuth = sshUseKeyAuth
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

struct TableSchemaInfo {
    let table: DatabaseTable
    let columns: [DatabaseColumn]
    let approximateRowCount: Int?
    let tableSize: String?
}
