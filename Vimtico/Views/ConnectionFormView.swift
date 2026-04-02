import SwiftUI

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
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(themeManager.currentTheme.secondaryBackgroundColor)
            
            Divider()
            
            // Form
            ScrollView {
                Form {
                    Section("Connection Details") {
                        TextField("Name (optional)", text: $connection.name)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Host", text: $connection.host)
                            .textFieldStyle(.roundedBorder)
                        
                        HStack {
                            Text("Port")
                            TextField("", value: $connection.port, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                        
                        TextField("Database", text: $connection.database)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    Section("Authentication") {
                        TextField("Username", text: $connection.username)
                            .textFieldStyle(.roundedBorder)
                        
                        SecureField("Password", text: $connection.password)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    Section("Security") {
                        Toggle("Use SSL", isOn: $connection.useSSL)
                    }
                    
                    Section("SSH Tunnel") {
                        Toggle("Connect via SSH Tunnel", isOn: $connection.sshEnabled)
                            .onChange(of: connection.sshEnabled) { _, newValue in
                                showSSHSettings = newValue
                            }
                        
                        if showSSHSettings {
                            VStack(alignment: .leading, spacing: 12) {
                                TextField("SSH Host", text: $connection.sshHost)
                                    .textFieldStyle(.roundedBorder)
                                
                                HStack {
                                    Text("SSH Port")
                                    TextField("", value: $connection.sshPort, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                }
                                
                                TextField("SSH Username", text: $connection.sshUsername)
                                    .textFieldStyle(.roundedBorder)
                                
                                Toggle("Use SSH Key Authentication", isOn: $connection.sshUseKeyAuth)
                                
                                if connection.sshUseKeyAuth {
                                    HStack {
                                        TextField("SSH Key Path", text: $connection.sshKeyPath)
                                            .textFieldStyle(.roundedBorder)
                                        
                                        Button("Browse...") {
                                            selectSSHKeyFile()
                                        }
                                    }
                                } else {
                                    SecureField("SSH Password", text: $connection.sshPassword)
                                        .textFieldStyle(.roundedBorder)
                                    
                                    Text("Note: Password authentication requires key-based auth for security. Consider using SSH keys.")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                            .padding(.leading, 16)
                        }
                    }
                    
                    // Test result
                    if let result = testResult {
                        Section {
                            HStack {
                                Image(systemName: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(testSuccess ? .green : .red)
                                Text(result)
                                    .foregroundColor(testSuccess ? .green : .red)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            
            Divider()
            
            // Actions
            HStack {
                Button("Test Connection") {
                    testConnection()
                }
                .disabled(isTesting || !isFormValid)
                
                if isTesting {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                
                Spacer()
                
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Button(isEditing ? "Save" : "Connect") {
                    saveAndConnect()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isFormValid)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding()
        }
        .frame(width: 500, height: 650)
        .background(themeManager.currentTheme.backgroundColor)
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
