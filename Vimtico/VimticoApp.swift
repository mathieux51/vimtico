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
        .frame(width: 520, height: 460)
    }
}

// MARK: - Reusable Setting Row Components

/// A labeled row: label on the left, control on the right.
struct SettingRow<Content: View>: View {
    let label: String
    let content: Content
    
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    
    var body: some View {
        HStack {
            Text(label)
                .frame(width: 140, alignment: .trailing)
            content
            Spacer()
        }
    }
}

/// A section with a title divider line.
struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content
    
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            
            Divider()
            
            content
        }
    }
}

/// A small hint text below a control.
struct SettingHint: View {
    let text: String
    
    var body: some View {
        HStack {
            Spacer()
                .frame(width: 144)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

// MARK: - Theme Swatch

struct ThemeSwatch: View {
    let themeName: String
    let theme: Theme
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // Color preview bar
                HStack(spacing: 0) {
                    theme.backgroundColor
                    theme.editorSelectionColor
                    theme.keywordColor
                    theme.stringColor
                    theme.accentColor
                }
                .frame(width: 80, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )
                
                Text(themeName)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .accentColor : .primary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var configManager: ConfigurationManager
    @State private var showResetConfirmation = false
    
    private var configFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/vimtico/config.json"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Appearance") {
                SettingRow("Theme") {
                    HStack(spacing: 12) {
                        ForEach(themeManager.availableThemes, id: \.self) { name in
                            ThemeSwatch(
                                themeName: name,
                                theme: themeManager.theme(named: name),
                                isSelected: themeManager.currentThemeName == name
                            ) {
                                themeManager.setTheme(named: name)
                                configManager.configuration.theme = name
                                configManager.saveConfiguration()
                            }
                        }
                    }
                }
            }
            
            SettingsSection("Startup") {
                SettingRow("Auto-connect") {
                    if UserDefaults.standard.string(forKey: "lastConnectedConnectionId") != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                            Text("Last connection saved")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Button("Clear") {
                                UserDefaults.standard.removeObject(forKey: "lastConnectedConnectionId")
                            }
                            .controlSize(.small)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "minus.circle")
                                .foregroundColor(.secondary)
                                .font(.system(size: 12))
                            Text("No saved connection")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                SettingHint(text: "Automatically reconnects to the last database on launch.")
            }
            
            SettingsSection("Data") {
                SettingRow("Config file") {
                    HStack(spacing: 8) {
                        Text(configFilePath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Button {
                            NSWorkspace.shared.selectFile(configFilePath, inFileViewerRootedAtPath: "")
                        } label: {
                            Image(systemName: "folder")
                        }
                        .controlSize(.small)
                        .help("Reveal in Finder")
                    }
                }
                
                SettingRow("") {
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Text("Reset to Defaults...")
                    }
                    .controlSize(.small)
                }
            }
            
            Spacer()
        }
        .padding(20)
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

// MARK: - Editor Settings

struct EditorSettingsView: View {
    @EnvironmentObject var configManager: ConfigurationManager
    
    private var fontSizeBinding: Binding<Int> {
        Binding(
            get: { configManager.configuration.editor?.effectiveFontSize ?? EditorConfig.defaultFontSize },
            set: { newValue in
                let clamped = min(max(newValue, EditorConfig.minFontSize), EditorConfig.maxFontSize)
                ensureEditorConfig()
                configManager.configuration.editor?.fontSize = clamped
                configManager.saveConfiguration()
                NotificationCenter.default.post(name: .fontSizeChanged, object: clamped)
            }
        )
    }
    
    private var tabSizeBinding: Binding<Int> {
        Binding(
            get: { configManager.configuration.editor?.tabSize ?? 4 },
            set: { newValue in
                let clamped = min(max(newValue, 1), 16)
                ensureEditorConfig()
                configManager.configuration.editor?.tabSize = clamped
                configManager.saveConfiguration()
            }
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Font") {
                SettingRow("Size") {
                    HStack(spacing: 8) {
                        Text("\(fontSizeBinding.wrappedValue) pt")
                            .font(.system(size: 13, design: .monospaced))
                            .frame(width: 44, alignment: .trailing)
                        Stepper("", value: fontSizeBinding, in: EditorConfig.minFontSize...EditorConfig.maxFontSize)
                            .labelsHidden()
                    }
                }
                SettingHint(text: "Also adjustable with Cmd +/-/0. Editor uses a +4 offset for monospace.")
                
                SettingRow("Preview") {
                    Text("select * from users;")
                        .font(.system(size: CGFloat(fontSizeBinding.wrappedValue), design: .monospaced))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(4)
                }
            }
            
            SettingsSection("Indentation") {
                SettingRow("Tab size") {
                    HStack(spacing: 8) {
                        Text("\(tabSizeBinding.wrappedValue)")
                            .font(.system(size: 13, design: .monospaced))
                            .frame(width: 20, alignment: .trailing)
                        Stepper("", value: tabSizeBinding, in: 1...16)
                            .labelsHidden()
                    }
                }
                
                SettingRow("") {
                    Toggle("Insert spaces instead of tabs", isOn: Binding(
                        get: { configManager.configuration.editor?.insertSpaces ?? true },
                        set: { newValue in
                            ensureEditorConfig()
                            configManager.configuration.editor?.insertSpaces = newValue
                            configManager.saveConfiguration()
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            
            SettingsSection("Display") {
                SettingRow("") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Word wrap", isOn: Binding(
                            get: { configManager.configuration.editor?.wordWrap ?? true },
                            set: { newValue in
                                ensureEditorConfig()
                                configManager.configuration.editor?.wordWrap = newValue
                                configManager.saveConfiguration()
                            }
                        ))
                        .toggleStyle(.checkbox)
                        
                        Toggle("Show line numbers", isOn: Binding(
                            get: { configManager.configuration.editor?.showLineNumbers ?? true },
                            set: { newValue in
                                ensureEditorConfig()
                                configManager.configuration.editor?.showLineNumbers = newValue
                                configManager.saveConfiguration()
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            
            Spacer()
        }
        .padding(20)
    }
    
    private func ensureEditorConfig() {
        if configManager.configuration.editor == nil {
            configManager.configuration.editor = EditorConfig()
        }
    }
}

// MARK: - Vim Settings

struct VimSettingsView: View {
    @EnvironmentObject var configManager: ConfigurationManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Vim Mode") {
                SettingRow("") {
                    Toggle("Enable Vim mode", isOn: Binding(
                        get: { configManager.configuration.vimMode?.enabled ?? true },
                        set: { newValue in
                            ensureVimConfig()
                            configManager.configuration.vimMode?.enabled = newValue
                            configManager.saveConfiguration()
                            NotificationCenter.default.post(name: .vimModeChanged, object: newValue)
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
                SettingHint(text: "Toggle at runtime with Cmd+Shift+V. Pane navigation (Ctrl-w) works regardless.")
            }
            
            SettingsSection("Cursor") {
                SettingRow("") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Cursor blink", isOn: Binding(
                            get: { configManager.configuration.vimMode?.cursorBlink ?? true },
                            set: { newValue in
                                ensureVimConfig()
                                configManager.configuration.vimMode?.cursorBlink = newValue
                                configManager.saveConfiguration()
                            }
                        ))
                        .toggleStyle(.checkbox)
                        
                        Toggle("Relative line numbers", isOn: Binding(
                            get: { configManager.configuration.vimMode?.relativeLineNumbers ?? false },
                            set: { newValue in
                                ensureVimConfig()
                                configManager.configuration.vimMode?.relativeLineNumbers = newValue
                                configManager.saveConfiguration()
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                SettingHint(text: "Normal mode uses a block cursor. Insert mode uses a line cursor.")
            }
            
            Spacer()
        }
        .padding(20)
    }
    
    private func ensureVimConfig() {
        if configManager.configuration.vimMode == nil {
            configManager.configuration.vimMode = VimModeConfig()
        }
    }
}

// MARK: - Autocomplete Settings

struct AutocompleteSettingsView: View {
    @EnvironmentObject var configManager: ConfigurationManager
    
    private var currentMode: AutocompleteMode {
        configManager.configuration.editor?.autocompleteMode ?? .ruleBased
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Mode") {
                SettingRow("Engine") {
                    Picker("", selection: Binding(
                        get: { currentMode },
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
                    .labelsHidden()
                    .frame(width: 240)
                }
                SettingHint(text: currentMode.description)
            }
            
            if currentMode == .openAI {
                SettingsSection("OpenAI") {
                    SettingRow("API Key") {
                        SecureField("sk-...", text: Binding(
                            get: { configManager.configuration.editor?.openAIApiKey ?? "" },
                            set: { newValue in
                                ensureEditorConfig()
                                configManager.configuration.editor?.openAIApiKey = newValue
                                configManager.saveConfiguration()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    }
                }
            }
            
            if currentMode == .anthropic {
                SettingsSection("Anthropic") {
                    SettingRow("API Key") {
                        SecureField("sk-ant-...", text: Binding(
                            get: { configManager.configuration.editor?.anthropicApiKey ?? "" },
                            set: { newValue in
                                ensureEditorConfig()
                                configManager.configuration.editor?.anthropicApiKey = newValue
                                configManager.saveConfiguration()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    }
                }
            }
            
            Spacer()
        }
        .padding(20)
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
