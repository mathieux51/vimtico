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
            ThemeSettingsView()
                .tabItem {
                    Label("Themes", systemImage: "paintpalette")
                }
            
            EditorSettingsView()
                .tabItem {
                    Label("Editor", systemImage: "text.cursor")
                }
        }
        .frame(width: 500, height: 400)
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
            Section("Vim Mode") {
                Toggle("Enable Vim Mode by Default", isOn: Binding(
                    get: { configManager.configuration.vimMode?.enabled ?? false },
                    set: { newValue in
                        if configManager.configuration.vimMode == nil {
                            configManager.configuration.vimMode = VimModeConfig(enabled: newValue)
                        } else {
                            configManager.configuration.vimMode?.enabled = newValue
                        }
                        configManager.saveConfiguration()
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
}
