import SwiftUI

/// A themed text field style that uses the app's theme colors.
struct ThemedTextFieldStyle: ViewModifier {
    let theme: any Theme
    
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(6)
            .background(theme.editorBackgroundColor)
            .foregroundColor(theme.editorForegroundColor)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.borderColor, lineWidth: 1)
            )
    }
}

extension View {
    func themedTextField(_ theme: any Theme) -> some View {
        self.modifier(ThemedTextFieldStyle(theme: theme))
    }
}

struct ConnectionFormView: View {
    @ObservedObject var viewModel: DatabaseViewModel
    @Binding var isPresented: Bool
    @EnvironmentObject var themeManager: ThemeManager
    
    @State private var connection: DatabaseConnection
    @State private var isEditing: Bool
    @State private var isTesting: Bool = false
    @State private var testResult: String?
    @State private var testSuccess: Bool = false
    @State private var showSSHSettings: Bool = false
    
    private var theme: any Theme { themeManager.currentTheme }
    
    init(viewModel: DatabaseViewModel, isPresented: Binding<Bool>, editingConnection: DatabaseConnection? = nil) {
        self.viewModel = viewModel
        self._isPresented = isPresented
        
        if let existing = editingConnection {
            self._connection = State(initialValue: existing)
            self._isEditing = State(initialValue: true)
            self._showSSHSettings = State(initialValue: existing.sshEnabled)
        } else {
            self._connection = State(initialValue: DatabaseConnection())
            self._isEditing = State(initialValue: false)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "Edit Connection" : "New Connection")
                    .font(.headline)
                    .foregroundColor(theme.foregroundColor)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.foregroundColor.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(theme.secondaryBackgroundColor)
            
            Divider()
                .background(theme.borderColor)
            
            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Connection Details
                    sectionView("Connection Details") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Name (optional)", text: $connection.name)
                                .themedTextField(theme)
                            
                            TextField("Host", text: $connection.host)
                                .themedTextField(theme)
                            
                            HStack {
                                Text("Port")
                                    .foregroundColor(theme.foregroundColor)
                                    .frame(width: 40, alignment: .leading)
                                TextField("", value: $connection.port, format: .number)
                                    .themedTextField(theme)
                                    .frame(width: 100)
                            }
                            
                            TextField("Database", text: $connection.database)
                                .themedTextField(theme)
                        }
                    }
                    
                    // Authentication
                    sectionView("Authentication") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Username", text: $connection.username)
                                .themedTextField(theme)
                            
                            SecureField("Password", text: $connection.password)
                                .themedTextField(theme)
                        }
                    }
                    
                    // Security
                    sectionView("Security") {
                        Toggle("Use SSL", isOn: $connection.useSSL)
                            .toggleStyle(.switch)
                            .foregroundColor(theme.foregroundColor)
                            .tint(theme.accentColor)
                    }
                    
                    // SSH Tunnel
                    sectionView("SSH Tunnel") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Connect via SSH Tunnel", isOn: $connection.sshEnabled)
                                .toggleStyle(.switch)
                                .foregroundColor(theme.foregroundColor)
                                .tint(theme.accentColor)
                                .onChange(of: connection.sshEnabled) { _, newValue in
                                    showSSHSettings = newValue
                                }
                            
                            if showSSHSettings {
                                VStack(alignment: .leading, spacing: 8) {
                                    TextField("SSH Host", text: $connection.sshHost)
                                        .themedTextField(theme)
                                    
                                    HStack {
                                        Text("SSH Port")
                                            .foregroundColor(theme.foregroundColor)
                                            .frame(width: 60, alignment: .leading)
                                        TextField("", value: $connection.sshPort, format: .number)
                                            .themedTextField(theme)
                                            .frame(width: 100)
                                    }
                                    
                                    TextField("SSH Username", text: $connection.sshUsername)
                                        .themedTextField(theme)
                                    
                                    Toggle("Use SSH Key Authentication", isOn: $connection.sshUseKeyAuth)
                                        .toggleStyle(.switch)
                                        .foregroundColor(theme.foregroundColor)
                                        .tint(theme.accentColor)
                                    
                                    if connection.sshUseKeyAuth {
                                        HStack {
                                            TextField("SSH Key Path", text: $connection.sshKeyPath)
                                                .themedTextField(theme)
                                            
                                            Button("Browse...") {
                                                selectSSHKeyFile()
                                            }
                                            .foregroundColor(theme.accentColor)
                                        }
                                    } else {
                                        SecureField("SSH Password", text: $connection.sshPassword)
                                            .themedTextField(theme)
                                        
                                        Text("Note: Password authentication requires key-based auth for security. Consider using SSH keys.")
                                            .font(.caption)
                                            .foregroundColor(theme.warningColor)
                                    }
                                }
                                .padding(.leading, 16)
                            }
                        }
                    }
                    
                    // Test result
                    if let result = testResult {
                        HStack {
                            Image(systemName: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(testSuccess ? theme.successColor : theme.errorColor)
                            Text(result)
                                .foregroundColor(testSuccess ? theme.successColor : theme.errorColor)
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(16)
            }
            
            Divider()
                .background(theme.borderColor)
            
            // Actions
            HStack {
                Button("Test Connection") {
                    testConnection()
                }
                .foregroundColor(theme.accentColor)
                .disabled(isTesting || !isFormValid)
                
                if isTesting {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                
                Spacer()
                
                Button("Cancel") {
                    isPresented = false
                }
                .foregroundColor(theme.foregroundColor)
                .keyboardShortcut(.escape, modifiers: [])
                
                Button(isEditing ? "Save" : "Connect") {
                    saveAndConnect()
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
                .disabled(!isFormValid)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding()
        }
        .frame(minWidth: 550, idealWidth: 620, minHeight: 600, idealHeight: 750)
        .background(theme.backgroundColor)
    }
    
    @ViewBuilder
    private func sectionView<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.foregroundColor.opacity(0.7))
                .textCase(.uppercase)
            
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.secondaryBackgroundColor)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.borderColor.opacity(0.5), lineWidth: 1)
        )
    }
    
    private var isFormValid: Bool {
        let basicValid = !connection.host.isEmpty &&
            connection.port > 0 &&
            !connection.database.isEmpty &&
            !connection.username.isEmpty
        
        if connection.sshEnabled {
            return basicValid &&
                !connection.sshHost.isEmpty &&
                connection.sshPort > 0 &&
                !connection.sshUsername.isEmpty &&
                (connection.sshUseKeyAuth ? !connection.sshKeyPath.isEmpty : !connection.sshPassword.isEmpty)
        }
        
        return basicValid
    }
    
    private func selectSSHKeyFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = "Select your SSH private key file"
        panel.prompt = "Select"
        
        if panel.runModal() == .OK, let url = panel.url {
            connection.sshKeyPath = url.path
        }
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        
        Task {
            let testService = PostgreSQLService()
            do {
                try await testService.connect(to: connection)
                await testService.disconnect()
                
                await MainActor.run {
                    testResult = "Connection successful!"
                    testSuccess = true
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = error.localizedDescription
                    testSuccess = false
                    isTesting = false
                }
            }
        }
    }
    
    private func saveAndConnect() {
        viewModel.saveConnection(connection)
        isPresented = false
        
        Task {
            await viewModel.connect(to: connection)
        }
    }
}

#Preview {
    ConnectionFormView(viewModel: DatabaseViewModel(), isPresented: .constant(true))
        .environmentObject(ThemeManager())
}
