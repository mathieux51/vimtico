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
            
            EditorSettingsView()
                .tabItem {
                    Label("Editor", systemImage: "text.cursor")
                }
            
            VimSettingsView()
                .tabItem {
                    Label("Vim", systemImage: "keyboard")
                }
            
            AutocompleteSettingsView()
                .tabItem {
                    Label("Autocomplete", systemImage: "sparkles")
                }
        }
        .frame(width: 620, height: 520)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var configManager: ConfigurationManager
    @State private var showResetConfirmation = false
    
    private var configFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/vimtico/config.json"
    }
    
    var body: some View {
        Form {
            Section("Appearance") {
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
            
            Section("Data") {
                HStack {
                    Text("Settings file")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(configFilePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Button("Reveal") {
                        NSWorkspace.shared.selectFile(configFilePath, inFileViewerRootedAtPath: "")
                    }
                    .controlSize(.small)
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

struct EditorSettingsView: View {
    @EnvironmentObject var configManager: ConfigurationManager
    
    var body: some View {
        Form {
            Section("Font") {
                HStack {
                    Text("Size: \(configManager.configuration.editor?.effectiveFontSize ?? EditorConfig.defaultFontSize)")
                        .font(.system(.body, design: .monospaced))
                    
                    Stepper("",
                        value: Binding(
                            get: { configManager.configuration.editor?.effectiveFontSize ?? EditorConfig.defaultFontSize },
                            set: { newValue in
                                let clamped = min(max(newValue, EditorConfig.minFontSize), EditorConfig.maxFontSize)
                                ensureEditorConfig()
                                configManager.configuration.editor?.fontSize = clamped
                                configManager.saveConfiguration()
                                NotificationCenter.default.post(name: .fontSizeChanged, object: clamped)
                            }
                        ),
                        in: EditorConfig.minFontSize...EditorConfig.maxFontSize
                    )
                }
                
                Text("Also adjustable with Cmd +/-/0.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("Indentation") {
                HStack {
                    Text("Tab Size")
                    Spacer()
                    Stepper("\(configManager.configuration.editor?.tabSize ?? 4)",
                        value: Binding(
                            get: { configManager.configuration.editor?.tabSize ?? 4 },
                            set: { newValue in
                                let clamped = min(max(newValue, 1), 16)
                                ensureEditorConfig()
                                configManager.configuration.editor?.tabSize = clamped
                                configManager.saveConfiguration()
                            }
                        ),
                        in: 1...16
                    )
                }
                
                Toggle("Insert Spaces Instead of Tabs", isOn: Binding(
                    get: { configManager.configuration.editor?.insertSpaces ?? true },
                    set: { newValue in
                        ensureEditorConfig()
                        configManager.configuration.editor?.insertSpaces = newValue
                        configManager.saveConfiguration()
                    }
                ))
            }
            
            Section("Display") {
                Toggle("Word Wrap", isOn: Binding(
                    get: { configManager.configuration.editor?.wordWrap ?? true },
                    set: { newValue in
                        ensureEditorConfig()
                        configManager.configuration.editor?.wordWrap = newValue
                        configManager.saveConfiguration()
                    }
                ))
                
                Toggle("Show Line Numbers", isOn: Binding(
                    get: { configManager.configuration.editor?.showLineNumbers ?? true },
                    set: { newValue in
                        ensureEditorConfig()
                        configManager.configuration.editor?.showLineNumbers = newValue
                        configManager.saveConfiguration()
                    }
                ))
            }
        }
        .padding()
    }
    
    private func ensureEditorConfig() {
        if configManager.configuration.editor == nil {
            configManager.configuration.editor = EditorConfig()
        }
    }
}

struct VimSettingsView: View {
    @EnvironmentObject var configManager: ConfigurationManager
    
    var body: some View {
        Form {
            Section("Vim Mode") {
                Toggle("Enable Vim Mode by Default", isOn: Binding(
                    get: { configManager.configuration.vimMode?.enabled ?? true },
                    set: { newValue in
                        ensureVimConfig()
                        configManager.configuration.vimMode?.enabled = newValue
                        configManager.saveConfiguration()
                        NotificationCenter.default.post(name: .vimModeChanged, object: newValue)
                    }
                ))
                
                Text("When enabled, the editor uses Vim keybindings. Toggle at any time with Cmd+Shift+V.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("Cursor") {
                Toggle("Cursor Blink", isOn: Binding(
                    get: { configManager.configuration.vimMode?.cursorBlink ?? true },
                    set: { newValue in
                        ensureVimConfig()
                        configManager.configuration.vimMode?.cursorBlink = newValue
                        configManager.saveConfiguration()
                    }
                ))
                
                Toggle("Relative Line Numbers", isOn: Binding(
                    get: { configManager.configuration.vimMode?.relativeLineNumbers ?? false },
                    set: { newValue in
                        ensureVimConfig()
                        configManager.configuration.vimMode?.relativeLineNumbers = newValue
                        configManager.saveConfiguration()
                    }
                ))
            }
        }
        .padding()
    }
    
    private func ensureVimConfig() {
        if configManager.configuration.vimMode == nil {
            configManager.configuration.vimMode = VimModeConfig()
        }
    }
}

struct AutocompleteSettingsView: View {
    @EnvironmentObject var configManager: ConfigurationManager
    
    var body: some View {
        Form {
            Section("Autocomplete Mode") {
                Picker("Mode", selection: Binding(
                    get: { configManager.configuration.editor?.autocompleteMode ?? .ruleBased },
                    set: { newValue in
                        ensureEditorConfig()
                        configManager.configuration.editor?.autocompleteMode = newValue
                        configManager.saveConfiguration()
                    }
                )) {
                    ForEach(AutocompleteMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                
                Text(configManager.configuration.editor?.autocompleteMode.description ?? AutocompleteMode.ruleBased.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            if configManager.configuration.editor?.autocompleteMode == .openAI {
                Section("OpenAI") {
                    SecureField("API Key", text: Binding(
                        get: { configManager.configuration.editor?.openAIApiKey ?? "" },
                        set: { newValue in
                            ensureEditorConfig()
                            configManager.configuration.editor?.openAIApiKey = newValue
                            configManager.saveConfiguration()
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
            
            if configManager.configuration.editor?.autocompleteMode == .anthropic {
                Section("Anthropic") {
                    SecureField("API Key", text: Binding(
                        get: { configManager.configuration.editor?.anthropicApiKey ?? "" },
                        set: { newValue in
                            ensureEditorConfig()
                            configManager.configuration.editor?.anthropicApiKey = newValue
                            configManager.saveConfiguration()
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
        .padding()
    }
    
    private func ensureEditorConfig() {
        if configManager.configuration.editor == nil {
            configManager.configuration.editor = EditorConfig()
        }
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
    static let editorBecameFirstResponder = Notification.Name("editorBecameFirstResponder")
}
