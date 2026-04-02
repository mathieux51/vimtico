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
    
    init(enabled: Bool = true, relativeLineNumbers: Bool = false, cursorBlink: Bool = true) {
        self.enabled = enabled
        self.relativeLineNumbers = relativeLineNumbers
        self.cursorBlink = cursorBlink
    }
}

struct EditorConfig: Codable {
    var fontFamily: String
    var fontSize: Int?
    var tabSize: Int
    var insertSpaces: Bool
    var wordWrap: Bool
    var showLineNumbers: Bool
    var autocompleteMode: AutocompleteMode
    var openAIApiKey: String?
    var anthropicApiKey: String?
    
    static let minFontSize = 8
    static let maxFontSize = 72
    static let defaultFontSize = 18
    
    /// The effective font size, falling back to the default if not set.
    var effectiveFontSize: Int {
        fontSize ?? Self.defaultFontSize
    }
    
    init(
        fontFamily: String = "SF Mono",
        fontSize: Int? = nil,
        tabSize: Int = 4,
        insertSpaces: Bool = true,
        wordWrap: Bool = true,
        showLineNumbers: Bool = true,
        autocompleteMode: AutocompleteMode = .ruleBased,
        openAIApiKey: String? = nil,
        anthropicApiKey: String? = nil
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.tabSize = tabSize
        self.insertSpaces = insertSpaces
        self.wordWrap = wordWrap
        self.showLineNumbers = showLineNumbers
        self.autocompleteMode = autocompleteMode
        self.openAIApiKey = openAIApiKey
        self.anthropicApiKey = anthropicApiKey
    }
}

/// Autocomplete mode selection
enum AutocompleteMode: String, Codable, CaseIterable {
    case disabled = "disabled"
    case ruleBased = "rule_based"
    case localML = "local_ml"
    case openAI = "openai"
    case anthropic = "anthropic"
    
    var displayName: String {
        switch self {
        case .disabled: return "Disabled"
        case .ruleBased: return "Rule-based (Fast, Offline)"
        case .localML: return "Local ML (MLX, Offline)"
        case .openAI: return "OpenAI API (Online)"
        case .anthropic: return "Anthropic API (Online)"
        }
    }
    
    var description: String {
        switch self {
        case .disabled:
            return "No autocomplete suggestions"
        case .ruleBased:
            return "Fast, lightweight suggestions based on SQL grammar and your database schema. Works offline."
        case .localML:
            return "Uses Apple MLX framework with a small local model for smarter suggestions. Works offline but uses more resources."
        case .openAI:
            return "Uses OpenAI API for intelligent, context-aware suggestions. Requires API key and internet connection."
        case .anthropic:
            return "Uses Anthropic Claude API for intelligent suggestions. Requires API key and internet connection."
        }
    }
    
    var requiresAPIKey: Bool {
        switch self {
        case .openAI, .anthropic: return true
        default: return false
        }
    }
}

struct ConnectionConfig: Codable {
    var name: String
    var host: String
    var port: Int
    var database: String
    var username: String
    var useSSL: Bool
    // SSH Tunnel configuration
    var sshEnabled: Bool
    var sshHost: String
    var sshPort: Int
    var sshUsername: String
    var sshKeyPath: String
    
    init(
        name: String = "",
        host: String = "localhost",
        port: Int = 5432,
        database: String = "",
        username: String = "",
        useSSL: Bool = false,
        sshEnabled: Bool = false,
        sshHost: String = "",
        sshPort: Int = 22,
        sshUsername: String = "",
        sshKeyPath: String = "~/.ssh/id_rsa"
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.useSSL = useSSL
        self.sshEnabled = sshEnabled
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.sshUsername = sshUsername
        self.sshKeyPath = sshKeyPath
    }
}

enum ConfigError: LocalizedError {
    case invalidUTF8
    case decodingFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "Configuration text is not valid UTF-8"
        case .decodingFailed(let detail):
            return detail
        }
    }
}

/// Configuration manager that handles loading/saving JSON config
class ConfigurationManager: ObservableObject {
    @Published var configuration: AppConfiguration = AppConfiguration()
    @Published var loadError: String? = nil
    
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
                loadError = nil
            } catch let error as DecodingError {
                let json = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
                loadError = "Config error: \(Self.describeDecodingError(error, in: json))"
                print(loadError!)
                configuration = AppConfiguration()
            } catch {
                loadError = "Failed to load configuration: \(error.localizedDescription)"
                print(loadError!)
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
        guard let data = jsonString.data(using: .utf8) else {
            throw ConfigError.invalidUTF8
        }
        let decoder = JSONDecoder()
        do {
            configuration = try decoder.decode(AppConfiguration.self, from: data)
            saveConfiguration()
        } catch let error as DecodingError {
            throw ConfigError.decodingFailed(Self.describeDecodingError(error, in: jsonString))
        } catch {
            throw ConfigError.decodingFailed(error.localizedDescription)
        }
    }
    
    /// Produces a human-readable description of a DecodingError, including the
    /// JSON path and approximate line/column when possible.
    private static func describeDecodingError(_ error: DecodingError, in json: String) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            let path = codingPath(context.codingPath)
            let location = lineColumn(for: context, in: json)
            return "Type mismatch at \(path)\(location): expected \(type). \(context.debugDescription)"
            
        case .valueNotFound(let type, let context):
            let path = codingPath(context.codingPath)
            let location = lineColumn(for: context, in: json)
            return "Missing value at \(path)\(location): expected \(type). \(context.debugDescription)"
            
        case .keyNotFound(let key, let context):
            let path = codingPath(context.codingPath)
            let location = lineColumn(for: context, in: json)
            return "Missing key \"\(key.stringValue)\" at \(path)\(location). \(context.debugDescription)"
            
        case .dataCorrupted(let context):
            let path = codingPath(context.codingPath)
            let location = lineColumn(for: context, in: json)
            return "Invalid data at \(path)\(location). \(context.debugDescription)"
            
        @unknown default:
            return error.localizedDescription
        }
    }
    
    private static func codingPath(_ path: [CodingKey]) -> String {
        if path.isEmpty { return "root" }
        return path.map { key in
            if let index = key.intValue {
                return "[\(index)]"
            }
            return ".\(key.stringValue)"
        }.joined()
    }
    
    /// Attempt to find the line and column for the error context by looking for
    /// the last key in the coding path within the JSON string.
    private static func lineColumn(for context: DecodingError.Context, in json: String) -> String {
        // Try to find the last key in the JSON to give approximate position
        guard let lastKey = context.codingPath.last?.stringValue else { return "" }
        let searchTerm = "\"\(lastKey)\""
        guard let range = json.range(of: searchTerm, options: .backwards) else { return "" }
        
        let offset = json.distance(from: json.startIndex, to: range.lowerBound)
        let prefix = json[json.startIndex..<range.lowerBound]
        let line = prefix.filter { $0 == "\n" }.count + 1
        let lastNewline = prefix.lastIndex(of: "\n") ?? json.startIndex
        let col = json.distance(from: lastNewline, to: range.lowerBound) + (lastNewline == json.startIndex ? 1 : 0)
        
        return " (line \(line), col \(col))"
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
