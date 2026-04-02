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
            CommandMenu("Vim") {
                Button("Toggle Vim Mode") {
                    NotificationCenter.default.post(name: .toggleVimMode, object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
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
            
            ConfigurationSettingsView()
                .tabItem {
                    Label("Configuration", systemImage: "gear")
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
            
            TextField("Font Size", value: Binding(
                get: { configManager.configuration.editor?.fontSize ?? 14 },
                set: { newValue in
                    if configManager.configuration.editor == nil {
                        configManager.configuration.editor = EditorConfig(fontSize: newValue)
                    } else {
                        configManager.configuration.editor?.fontSize = newValue
                    }
                    configManager.saveConfiguration()
                }
            ), format: .number)
        }
        .padding()
    }
}

struct ConfigurationSettingsView: View {
    @EnvironmentObject var configManager: ConfigurationManager
    @State private var configJSON: String = ""
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("Configuration JSON")
                .font(.headline)
            
            TextEditor(text: $configJSON)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
            
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            HStack {
                Button("Reset to Defaults") {
                    configManager.configuration = AppConfiguration()
                    configJSON = configManager.configurationAsJSON()
                    configManager.saveConfiguration()
                }
                
                Spacer()
                
                Button("Apply") {
                    do {
                        try configManager.loadFromJSON(configJSON)
                        errorMessage = nil
                    } catch {
                        errorMessage = "Invalid JSON: \(error.localizedDescription)"
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear {
            configJSON = configManager.configurationAsJSON()
        }
    }
}

extension Notification.Name {
    static let newConnection = Notification.Name("newConnection")
    static let executeQuery = Notification.Name("executeQuery")
    static let toggleVimMode = Notification.Name("toggleVimMode")
}
