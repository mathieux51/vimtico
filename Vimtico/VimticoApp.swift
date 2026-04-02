import SwiftUI

@main
struct VimticoApp: App {
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var configManager = ConfigurationManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeManager)
                .environmentObject(configManager)
                .onAppear {
                    configManager.loadConfiguration()
                    if let themeName = configManager.configuration.theme {
                        themeManager.setTheme(named: themeName)
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection") {
                    NotificationCenter.default.post(name: .newConnection, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandMenu("Query") {
                Button("Execute Query") {
                    NotificationCenter.default.post(name: .executeQuery, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }
            CommandMenu("View") {
                Button("Zoom In") {
                    NotificationCenter.default.post(name: .zoomIn, object: nil)
                }
                .keyboardShortcut("+", modifiers: [.command])
                
                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .zoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: [.command])
                
                Button("Reset Zoom") {
                    NotificationCenter.default.post(name: .zoomReset, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command])
                
                Divider()
            }
            CommandMenu("Database") {
                Button("Reconnect") {
                    NotificationCenter.default.post(name: .reconnect, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            CommandMenu("Vim") {
                Button("Toggle Vim Mode") {
                    NotificationCenter.default.post(name: .toggleVimMode, object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Keybindings") {
                    NotificationCenter.default.post(name: .showKeybindings, object: nil)
                }
                .keyboardShortcut("/", modifiers: [.command])
            }
        }
        
        Settings {
            SettingsView()
                .environmentObject(themeManager)
                .environmentObject(configManager)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var configManager: ConfigurationManager
    
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            ThemeSettingsView()
                .tabItem {
                    Label("Themes", systemImage: "paintpalette")
                }
            
            EditorSettingsView()
                .tabItem {
                    Label("Editor", systemImage: "text.cursor")
                }
        }
        .frame(width: 500, height: 450)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var configManager: ConfigurationManager
    @State private var showResetConfirmation = false
    
    private var configFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/vimtico/config.json"
    }
    
    var body: some View {
        Form {
            Section("Configuration File") {
                HStack {
                    Text(configFilePath)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer()
                    
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(configFilePath, forType: .string)
                    }
                    
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(configFilePath, inFileViewerRootedAtPath: "")
                    }
                }
                
                Text("All settings are persisted to this JSON file automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("Startup") {
                HStack {
                    Text("Auto-connect to the last used database on launch.")
                    Spacer()
                    if UserDefaults.standard.string(forKey: "lastConnectedConnectionId") != nil {
                        Button("Clear Last Connection") {
                            UserDefaults.standard.removeObject(forKey: "lastConnectedConnectionId")
                        }
                    } else {
                        Text("No saved connection")
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Section("Reset") {
                HStack {
                    Text("Reset all settings to their default values.")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Reset to Defaults") {
                        showResetConfirmation = true
                    }
                    .foregroundColor(.red)
                }
            }
        }
        .padding()
        .alert("Reset Configuration?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                configManager.configuration = AppConfiguration()
                configManager.saveConfiguration()
                NotificationCenter.default.post(name: .fontSizeChanged, object: EditorConfig.defaultFontSize)
                NotificationCenter.default.post(name: .vimModeChanged, object: true)
            }
        } message: {
            Text("This will reset all configuration to defaults. This cannot be undone.")
        }
    }
}

struct ThemeSettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var configManager: ConfigurationManager
    
    var body: some View {
        Form {
            Picker("Theme", selection: $themeManager.currentThemeName) {
                ForEach(themeManager.availableThemes, id: \.self) { theme in
                    Text(theme).tag(theme)
                }
            }
            .onChange(of: themeManager.currentThemeName) { _, newValue in
                themeManager.setTheme(named: newValue)
                configManager.configuration.theme = newValue
                configManager.saveConfiguration()
            }
        }
        .padding()
    }
}

struct EditorSettingsView: View {
    @EnvironmentObject var configManager: ConfigurationManager
    
    var body: some View {
        Form {
            Section("Font Size") {
                HStack {
                    Text("Size: \(configManager.configuration.editor?.effectiveFontSize ?? EditorConfig.defaultFontSize)")
                        .font(.system(.body, design: .monospaced))
                    
                    Stepper("",
                        value: Binding(
                            get: { configManager.configuration.editor?.effectiveFontSize ?? EditorConfig.defaultFontSize },
                            set: { newValue in
                                let clamped = min(max(newValue, EditorConfig.minFontSize), EditorConfig.maxFontSize)
                                if configManager.configuration.editor == nil {
                                    configManager.configuration.editor = EditorConfig(fontSize: clamped)
                                } else {
                                    configManager.configuration.editor?.fontSize = clamped
                                }
                                configManager.saveConfiguration()
                                // Update the running font size via notification
                                NotificationCenter.default.post(name: .fontSizeChanged, object: clamped)
                            }
                        ),
                        in: EditorConfig.minFontSize...EditorConfig.maxFontSize
                    )
                }
                
                Text("Controls font size for editor, sidebar, and results. Also adjustable with Cmd +/-/0.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("Vim Mode") {
                Toggle("Enable Vim Mode by Default", isOn: Binding(
                    get: { configManager.configuration.vimMode?.enabled ?? true },
                    set: { newValue in
                        if configManager.configuration.vimMode == nil {
                            configManager.configuration.vimMode = VimModeConfig(enabled: newValue)
                        } else {
                            configManager.configuration.vimMode?.enabled = newValue
                        }
                        configManager.saveConfiguration()
                        NotificationCenter.default.post(name: .vimModeChanged, object: newValue)
                    }
                ))
            }
            
            Section("SQL Autocomplete") {
                Picker("Autocomplete Mode", selection: Binding(
                    get: { configManager.configuration.editor?.autocompleteMode ?? .ruleBased },
                    set: { newValue in
                        if configManager.configuration.editor == nil {
                            configManager.configuration.editor = EditorConfig(autocompleteMode: newValue)
                        } else {
                            configManager.configuration.editor?.autocompleteMode = newValue
                        }
                        configManager.saveConfiguration()
                    }
                )) {
                    ForEach(AutocompleteMode.allCases, id: \.self) { mode in
                        VStack(alignment: .leading) {
                            Text(mode.displayName)
                        }
                        .tag(mode)
                    }
                }
                
                Text(configManager.configuration.editor?.autocompleteMode.description ?? AutocompleteMode.ruleBased.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if configManager.configuration.editor?.autocompleteMode == .openAI {
                    SecureField("OpenAI API Key", text: Binding(
                        get: { configManager.configuration.editor?.openAIApiKey ?? "" },
                        set: { newValue in
                            if configManager.configuration.editor == nil {
                                configManager.configuration.editor = EditorConfig(openAIApiKey: newValue)
                            } else {
                                configManager.configuration.editor?.openAIApiKey = newValue
                            }
                            configManager.saveConfiguration()
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                
                if configManager.configuration.editor?.autocompleteMode == .anthropic {
                    SecureField("Anthropic API Key", text: Binding(
                        get: { configManager.configuration.editor?.anthropicApiKey ?? "" },
                        set: { newValue in
                            if configManager.configuration.editor == nil {
                                configManager.configuration.editor = EditorConfig(anthropicApiKey: newValue)
                            } else {
                                configManager.configuration.editor?.anthropicApiKey = newValue
                            }
                            configManager.saveConfiguration()
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
        .padding()
    }
}

extension Notification.Name {
    static let newConnection = Notification.Name("newConnection")
    static let executeQuery = Notification.Name("executeQuery")
    static let executeSelectedQuery = Notification.Name("executeSelectedQuery")
    static let cancelQuery = Notification.Name("cancelQuery")
    static let openExternalEditor = Notification.Name("openExternalEditor")
    static let toggleVimMode = Notification.Name("toggleVimMode")
    static let zoomIn = Notification.Name("zoomIn")
    static let zoomOut = Notification.Name("zoomOut")
    static let zoomReset = Notification.Name("zoomReset")
    static let focusPane = Notification.Name("focusPane")
    static let showKeybindings = Notification.Name("showKeybindings")
    static let reconnect = Notification.Name("reconnect")
    static let fontSizeChanged = Notification.Name("fontSizeChanged")
    static let vimModeChanged = Notification.Name("vimModeChanged")
}
