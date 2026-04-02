import Foundation

/// Main application configuration structure
/// This is stored as JSON in ~/.config/vimtico/config.json
struct AppConfiguration: Codable {
    var theme: String?
    var vimMode: VimModeConfig?
    var editor: EditorConfig?
    var connections: [ConnectionConfig]?
    var customThemes: [[String: AnyCodable]]?
    
    init(
        theme: String? = "Nord",
        vimMode: VimModeConfig? = VimModeConfig(),
        editor: EditorConfig? = EditorConfig(),
        connections: [ConnectionConfig]? = nil,
        customThemes: [[String: AnyCodable]]? = nil
    ) {
        self.theme = theme
        self.vimMode = vimMode
        self.editor = editor
        self.connections = connections
        self.customThemes = customThemes
    }
}

struct VimModeConfig: Codable {
    var enabled: Bool
    var relativeLineNumbers: Bool
    var cursorBlink: Bool
    
    init(enabled: Bool = false, relativeLineNumbers: Bool = false, cursorBlink: Bool = true) {
        self.enabled = enabled
        self.relativeLineNumbers = relativeLineNumbers
        self.cursorBlink = cursorBlink
    }
}

struct EditorConfig: Codable {
    var fontSize: Int
    var fontFamily: String
    var tabSize: Int
    var insertSpaces: Bool
    var wordWrap: Bool
    var showLineNumbers: Bool
    
    init(
        fontSize: Int = 14,
        fontFamily: String = "SF Mono",
        tabSize: Int = 4,
        insertSpaces: Bool = true,
        wordWrap: Bool = true,
        showLineNumbers: Bool = true
    ) {
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.tabSize = tabSize
        self.insertSpaces = insertSpaces
        self.wordWrap = wordWrap
        self.showLineNumbers = showLineNumbers
    }
}

struct ConnectionConfig: Codable {
    var name: String
    var host: String
    var port: Int
    var database: String
    var username: String
    var useSSL: Bool
    
    init(
        name: String = "",
        host: String = "localhost",
        port: Int = 5432,
        database: String = "",
        username: String = "",
        useSSL: Bool = false
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.useSSL = useSSL
    }
}

/// Configuration manager that handles loading/saving JSON config
class ConfigurationManager: ObservableObject {
    @Published var configuration: AppConfiguration = AppConfiguration()
    
    private let configDirectory: URL
    private let configFile: URL
    
    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        configDirectory = homeDir.appendingPathComponent(".config/vimtico")
        configFile = configDirectory.appendingPathComponent("config.json")
    }
    
    func loadConfiguration() {
        // Create config directory if it doesn't exist
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        
        // Try to load existing config
        if FileManager.default.fileExists(atPath: configFile.path) {
            do {
                let data = try Data(contentsOf: configFile)
                let decoder = JSONDecoder()
                configuration = try decoder.decode(AppConfiguration.self, from: data)
            } catch {
                print("Failed to load configuration: \(error)")
                configuration = AppConfiguration()
                saveConfiguration()
            }
        } else {
            // Create default config
            configuration = AppConfiguration()
            saveConfiguration()
        }
    }
    
    func saveConfiguration() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try data.write(to: configFile)
        } catch {
            print("Failed to save configuration: \(error)")
        }
    }
    
    func loadFromJSON(_ jsonString: String) throws {
        let data = jsonString.data(using: .utf8)!
        let decoder = JSONDecoder()
        configuration = try decoder.decode(AppConfiguration.self, from: data)
        saveConfiguration()
    }
    
    func configurationAsJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(configuration),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

/// A type-erased Codable wrapper for handling arbitrary JSON
struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: container.codingPath, debugDescription: "Unsupported type"))
        }
    }
}
