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
                
                Button("Go to Line...") {
                    NotificationCenter.default.post(name: .goToLine, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.control])
            }
            CommandMenu("View") {
                Button("Focus Sidebar") {
                    NotificationCenter.default.post(name: .focusPane, object: FocusPane.sidebar)
                }
                .keyboardShortcut("1", modifiers: [.command])
                
                Button("Focus Editor") {
                    NotificationCenter.default.post(name: .focusPane, object: FocusPane.editor)
                }
                .keyboardShortcut("2", modifiers: [.command])
                
                Button("Focus Results") {
                    NotificationCenter.default.post(name: .focusPane, object: FocusPane.results)
                }
                .keyboardShortcut("3", modifiers: [.command])
                
                Divider()
                
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
                .frame(width: 100, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )
                
                Text(themeName)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .accentColor : .primary)
                    .lineLimit(1)
                    .fixedSize()
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
            // Show config load/save errors
            if let loadErr = configManager.loadError {
                configErrorBanner(message: loadErr)
            }
            if let saveErr = configManager.saveError {
                configErrorBanner(message: saveErr)
            }
            
            SettingsSection("Appearance") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Theme")
                        .font(.system(size: 13))
                    
                    HStack(spacing: 16) {
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
            }
        } message: {
            Text("This will reset all configuration to defaults. This cannot be undone.")
        }
    }
    
    @ViewBuilder
    private func configErrorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.red)
                .lineLimit(3)
            Spacer()
        }
        .padding(10)
        .background(Color.red.opacity(0.1))
        .cornerRadius(6)
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
            
            SettingsSection("Results") {
                SettingRow("Copy format") {
                    Picker("", selection: Binding(
                        get: { configManager.configuration.editor?.copyFormat ?? .csv },
                        set: { newValue in
                            ensureEditorConfig()
                            configManager.configuration.editor?.copyFormat = newValue
                            configManager.saveConfiguration()
                        }
                    )) {
                        ForEach(CopyFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                SettingHint(text: "Format used when yanking rows or blocks from the results pane.")
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

// MARK: - Autocomplete Settings

struct AutocompleteSettingsView: View {
    @EnvironmentObject var configManager: ConfigurationManager
    @State private var availableModels: [AnthropicModelInfo] = []
    @State private var isFetchingModels: Bool = false
    @State private var fetchError: String?
    
    private var currentMode: AutocompleteMode {
        configManager.configuration.editor?.autocompleteMode ?? .ruleBased
    }
    
    private var currentAnthropicKey: String {
        configManager.configuration.editor?.anthropicApiKey ?? ""
    }
    
    private var currentModelId: String {
        configManager.configuration.editor?.anthropicModel?.rawValue ?? AnthropicModel.haiku.rawValue
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
                            notifyAutocompleteConfigChanged()
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
                                notifyAutocompleteConfigChanged()
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
                        HStack {
                            SecureField("sk-ant-...", text: Binding(
                                get: { configManager.configuration.editor?.anthropicApiKey ?? "" },
                                set: { newValue in
                                    ensureEditorConfig()
                                    configManager.configuration.editor?.anthropicApiKey = newValue
                                    configManager.saveConfiguration()
                                    notifyAutocompleteConfigChanged()
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            .onSubmit {
                                fetchModels()
                            }
                            
                            Button(action: { fetchModels() }) {
                                if isFetchingModels {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .disabled(currentAnthropicKey.isEmpty || isFetchingModels)
                            .help("Fetch available models")
                        }
                    }
                    SettingRow("Model") {
                        if availableModels.isEmpty && !isFetchingModels {
                            HStack(spacing: 8) {
                                // Fallback to hardcoded defaults
                                Picker("", selection: Binding(
                                    get: { currentModelId },
                                    set: { newValue in
                                        ensureEditorConfig()
                                        // Find matching enum case or store as-is
                                        configManager.configuration.editor?.anthropicModel = AnthropicModel(rawValue: newValue)
                                        configManager.saveConfiguration()
                                        notifyAutocompleteConfigChanged()
                                    }
                                )) {
                                    ForEach(AnthropicModel.allCases, id: \.self) { model in
                                        Text(model.displayName).tag(model.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 240)
                            }
                        } else {
                            Picker("", selection: Binding(
                                get: { currentModelId },
                                set: { newValue in
                                    ensureEditorConfig()
                                    configManager.configuration.editor?.anthropicModel = AnthropicModel(rawValue: newValue)
                                    configManager.saveConfiguration()
                                    notifyAutocompleteConfigChanged()
                                }
                            )) {
                                ForEach(availableModels) { model in
                                    Text(model.displayName).tag(model.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 240)
                        }
                    }
                    if let error = fetchError {
                        SettingHint(text: error)
                    }
                }
                .onAppear {
                    if availableModels.isEmpty && !currentAnthropicKey.isEmpty {
                        fetchModels()
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
    
    private func notifyAutocompleteConfigChanged() {
        NotificationCenter.default.post(name: .autocompleteConfigChanged, object: nil)
    }
    
    private func fetchModels() {
        guard !currentAnthropicKey.isEmpty else { return }
        isFetchingModels = true
        fetchError = nil
        Task {
            do {
                let models = try await fetchAnthropicModels(apiKey: currentAnthropicKey)
                await MainActor.run {
                    availableModels = models
                    isFetchingModels = false
                    // If current model not in list, auto-select first
                    if !models.isEmpty && !models.contains(where: { $0.id == currentModelId }) {
                        ensureEditorConfig()
                        configManager.configuration.editor?.anthropicModel = AnthropicModel(rawValue: models.first!.id)
                        configManager.saveConfiguration()
                    }
                }
            } catch {
                await MainActor.run {
                    fetchError = error.localizedDescription
                    isFetchingModels = false
                }
            }
        }
    }
    
    private func fetchAnthropicModels(apiKey: String) async throws -> [AnthropicModelInfo] {
        let url = URL(string: "https://api.anthropic.com/v1/models?limit=100")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 10
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AutocompleteAPIError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelsArray = json["data"] as? [[String: Any]] else {
            throw AutocompleteAPIError.invalidResponse
        }
        
        return modelsArray.compactMap { model -> AnthropicModelInfo? in
            guard let id = model["id"] as? String,
                  let displayName = model["display_name"] as? String else { return nil }
            return AnthropicModelInfo(id: id, displayName: displayName)
        }
    }
}

extension Notification.Name {
    static let newConnection = Notification.Name("newConnection")
    static let executeQuery = Notification.Name("executeQuery")
    static let executeSelectedQuery = Notification.Name("executeSelectedQuery")
    static let cancelQuery = Notification.Name("cancelQuery")
    static let zoomIn = Notification.Name("zoomIn")
    static let zoomOut = Notification.Name("zoomOut")
    static let zoomReset = Notification.Name("zoomReset")
    static let focusPane = Notification.Name("focusPane")
    static let showKeybindings = Notification.Name("showKeybindings")
    static let reconnect = Notification.Name("reconnect")
    static let fontSizeChanged = Notification.Name("fontSizeChanged")
    static let editorBecameFirstResponder = Notification.Name("editorBecameFirstResponder")
    static let goToLine = Notification.Name("goToLine")
    static let autocompleteConfigChanged = Notification.Name("autocompleteConfigChanged")
}
