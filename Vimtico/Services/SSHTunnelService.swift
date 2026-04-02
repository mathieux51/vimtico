import Foundation

/// SSH Tunnel service that creates a local port forward to a remote PostgreSQL database
/// Uses the system's ssh command for tunneling
actor SSHTunnelService {
    private var sshProcess: Process?
    private var localPort: Int = 0
    
    /// Establishes an SSH tunnel to the remote host
    /// Returns the local port to connect to
    func connect(
        sshHost: String,
        sshPort: Int,
        sshUsername: String,
        sshPassword: String?,
        sshKeyPath: String?,
        useKeyAuth: Bool,
        remoteHost: String,
        remotePort: Int
    ) async throws -> Int {
        // Find an available local port
        localPort = try await findAvailablePort()
        
        // Build ssh command
        var arguments: [String] = [
            "-N",  // Don't execute remote command
            "-L", "\(localPort):\(remoteHost):\(remotePort)",  // Local port forward
            "-p", String(sshPort),
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=60",
            "-o", "ServerAliveCountMax=3"
        ]
        
        // Add key authentication if enabled
        if useKeyAuth, let keyPath = sshKeyPath, !keyPath.isEmpty {
            let expandedPath = NSString(string: keyPath).expandingTildeInPath
            arguments.append(contentsOf: ["-i", expandedPath])
        }
        
        // Add the SSH destination
        arguments.append("\(sshUsername)@\(sshHost)")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        
        // For password auth, we would need to use sshpass or expect
        // For now, we primarily support key-based auth
        if !useKeyAuth && sshPassword != nil && !sshPassword!.isEmpty {
            // Note: Password auth requires additional tools like sshpass
            // For security, we recommend key-based authentication
            throw SSHTunnelError.passwordAuthNotSupported
        }
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        
        sshProcess = process
        
        do {
            try process.run()
            
            // Wait a bit for the tunnel to establish
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
            // Check if process is still running (tunnel established)
            if !process.isRunning {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                throw SSHTunnelError.tunnelFailed(errorMessage)
            }
            
            return localPort
        } catch let error as SSHTunnelError {
            throw error
        } catch {
            throw SSHTunnelError.tunnelFailed(error.localizedDescription)
        }
    }
    
    /// Disconnects the SSH tunnel
    func disconnect() {
        sshProcess?.terminate()
        sshProcess = nil
        localPort = 0
    }
    
    /// Check if tunnel is active
    var isConnected: Bool {
        sshProcess?.isRunning ?? false
    }
    
    /// Get the local port for the tunnel
    var tunnelPort: Int {
        localPort
    }
    
    /// Find an available local port
    private func findAvailablePort() async throws -> Int {
        // Try to find a free port starting from 15432
        for port in 15432..<16000 {
            if await isPortAvailable(port) {
                return port
            }
        }
        throw SSHTunnelError.noAvailablePort
    }
    
    /// Check if a port is available
    private func isPortAvailable(_ port: Int) async -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        return bindResult == 0
    }
    
    deinit {
        sshProcess?.terminate()
    }
}

enum SSHTunnelError: LocalizedError {
    case tunnelFailed(String)
    case noAvailablePort
    case passwordAuthNotSupported
    
    var errorDescription: String? {
        switch self {
        case .tunnelFailed(let message):
            return "SSH tunnel failed: \(message)"
        case .noAvailablePort:
            return "No available local port for SSH tunnel"
        case .passwordAuthNotSupported:
            return "SSH password authentication is not supported. Please use SSH key authentication."
        }
    }
}
