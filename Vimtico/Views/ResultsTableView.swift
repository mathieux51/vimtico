import SwiftUI

struct ResultsTableView: View {
    @ObservedObject var viewModel: DatabaseViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @State private var selectedRows: Set<Int> = []
    
    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                ProgressView("Executing query...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = viewModel.queryResult {
                if let error = result.error {
                    ErrorView(message: error, theme: themeManager.currentTheme)
                } else if result.columns.isEmpty {
                    SuccessView(message: result.summary, theme: themeManager.currentTheme)
                } else {
                    ResultsTable(result: result, theme: themeManager.currentTheme)
                }
                
                // Status bar
                StatusBar(result: result, theme: themeManager.currentTheme)
            } else {
                EmptyStateView(theme: themeManager.currentTheme)
            }
        }
        .background(themeManager.currentTheme.backgroundColor)
    }
}

struct ResultsTable: View {
    let result: QueryResult
    let theme: Theme
    @State private var columnWidths: [String: CGFloat] = [:]
    
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(result.rows.enumerated()), id: \.offset) { index, row in
                        ResultRow(
                            columns: result.columns,
                            values: row,
                            isAlternate: index % 2 == 1,
                            theme: theme
                        )
                    }
                } header: {
                    HeaderRow(columns: result.columns, theme: theme)
                }
            }
        }
    }
}

struct HeaderRow: View {
    let columns: [String]
    let theme: Theme
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { column in
                Text(column)
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundColor(theme.foregroundColor)
                    .frame(minWidth: 100, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                
                Divider()
                    .background(theme.borderColor)
            }
        }
        .background(theme.tableHeaderColor)
    }
}

struct ResultRow: View {
    let columns: [String]
    let values: [String]
    let isAlternate: Bool
    let theme: Theme
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(zip(columns, values)), id: \.0) { column, value in
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(value == "NULL" ? theme.commentColor : theme.foregroundColor)
                    .frame(minWidth: 100, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .lineLimit(1)
                
                Divider()
                    .background(theme.borderColor)
            }
        }
        .background(isAlternate ? theme.tableAlternateRowColor : theme.backgroundColor)
    }
}

struct StatusBar: View {
    let result: QueryResult
    let theme: Theme
    
    var body: some View {
        HStack {
            Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(result.isSuccess ? theme.successColor : theme.errorColor)
            
            Text(result.summary)
                .font(.caption)
                .foregroundColor(theme.foregroundColor)
            
            Spacer()
            
            if !result.columns.isEmpty {
                Text("\(result.columns.count) columns")
                    .font(.caption)
                    .foregroundColor(theme.foregroundColor.opacity(0.7))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(theme.secondaryBackgroundColor)
    }
}

struct ErrorView: View {
    let message: String
    let theme: Theme
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(theme.errorColor)
            
            Text("Query Error")
                .font(.headline)
                .foregroundColor(theme.foregroundColor)
            
            Text(message)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(theme.errorColor)
                .multilineTextAlignment(.center)
                .padding()
                .background(theme.secondaryBackgroundColor)
                .cornerRadius(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct SuccessView: View {
    let message: String
    let theme: Theme
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(theme.successColor)
            
            Text("Query Executed")
                .font(.headline)
                .foregroundColor(theme.foregroundColor)
            
            Text(message)
                .font(.body)
                .foregroundColor(theme.foregroundColor.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    let theme: Theme
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.cursor")
                .font(.system(size: 48))
                .foregroundColor(theme.foregroundColor.opacity(0.5))
            
            Text("No Results")
                .font(.headline)
                .foregroundColor(theme.foregroundColor)
            
            Text("Write a query and press Cmd+Return to execute")
                .font(.body)
                .foregroundColor(theme.foregroundColor.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ResultsTableView(viewModel: DatabaseViewModel())
        .environmentObject(ThemeManager())
}
