import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DatabaseViewModel()
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var configManager: ConfigurationManager
    @State private var showingConnectionSheet = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: viewModel, showingConnectionSheet: $showingConnectionSheet)
        } detail: {
            HSplitView {
                VStack(spacing: 0) {
                    QueryEditorView(viewModel: viewModel)
                        .frame(minHeight: 150)
                    
                    Divider()
                    
                    ResultsTableView(viewModel: viewModel)
                        .frame(minHeight: 200)
                }
            }
        }
        .background(themeManager.currentTheme.backgroundColor)
        .sheet(isPresented: $showingConnectionSheet) {
            ConnectionFormView(viewModel: viewModel, isPresented: $showingConnectionSheet)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newConnection)) { _ in
            showingConnectionSheet = true
        }
        .onAppear {
            if configManager.configuration.vimMode?.enabled ?? false {
                viewModel.vimModeEnabled = true
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager())
        .environmentObject(ConfigurationManager())
}
