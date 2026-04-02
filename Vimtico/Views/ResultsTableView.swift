import SwiftUI

struct ResultsTableView: View {
    @ObservedObject var viewModel: DatabaseViewModel
    @EnvironmentObject var themeManager: ThemeManager
    
    /// Font size for the results area is slightly smaller than the editor.
    private var resultsFontSize: CGFloat {
        max(viewModel.fontSize - 2, 10)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                ProgressView("Executing query...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = viewModel.queryResult {
                if let error = result.error {
                    ErrorView(message: error, theme: themeManager.currentTheme, fontSize: resultsFontSize)
                } else if result.columns.isEmpty {
                    SuccessView(message: result.summary, theme: themeManager.currentTheme, fontSize: resultsFontSize)
                } else {
                    // Use filtered rows if filter is active
                    let displayRows = viewModel.filteredResultRows ?? result.rows
                    let filteredResult = QueryResult(
                        columns: result.columns,
                        rows: displayRows,
                        rowsAffected: result.rowsAffected,
                        executionTime: result.executionTime
                    )
                    ResultsTable(
                        result: filteredResult,
                        theme: themeManager.currentTheme,
                        fontSize: resultsFontSize,
                        selectedRow: viewModel.selectedResultRow,
                        selectedColumn: viewModel.selectedResultColumn,
                        isFocused: viewModel.focusedPane == .results
                    )
                }
                
                // Status bar
                StatusBar(result: result, theme: themeManager.currentTheme, fontSize: resultsFontSize)
            } else if let info = viewModel.tableInfo {
                TableInfoView(
                    info: info,
                    filteredColumns: viewModel.filteredSchemaRows,
                    theme: themeManager.currentTheme,
                    fontSize: resultsFontSize,
                    selectedRow: viewModel.selectedSchemaRow,
                    isFocused: viewModel.focusedPane == .results
                )
            } else {
                EmptyStateView(theme: themeManager.currentTheme, fontSize: resultsFontSize)
            }
            
            if viewModel.isResultsFiltering {
                FilterBar(
                    filterText: viewModel.resultsFilterText,
                    theme: themeManager.currentTheme,
                    fontSize: resultsFontSize,
                    isActive: true
                )
            } else if !viewModel.resultsFilterText.isEmpty {
                FilterBar(
                    filterText: viewModel.resultsFilterText,
                    theme: themeManager.currentTheme,
                    fontSize: resultsFontSize,
                    isActive: false
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(themeManager.currentTheme.backgroundColor)
    }
}

struct ResultsTable: View {
    let result: QueryResult
    let theme: Theme
    let fontSize: CGFloat
    var selectedRow: Int? = nil
    var selectedColumn: Int = 0
    var isFocused: Bool = false
    
    /// Compute a fixed width per column based on the longest value (header or data).
    private var columnWidths: [CGFloat] {
        let charWidth: CGFloat = fontSize * 0.6  // approximate monospaced char width ratio
        let padding: CGFloat = 24     // horizontal padding (8 * 2) + some breathing room
        let minWidth: CGFloat = 80
        let maxWidth: CGFloat = 400
        
        return result.columns.indices.map { colIndex in
            let headerLen = result.columns[colIndex].count
            let maxDataLen = result.rows.reduce(0) { maxLen, row in
                guard colIndex < row.count else { return maxLen }
                return max(maxLen, row[colIndex].count)
            }
            let longest = max(headerLen, maxDataLen)
            let computed = CGFloat(longest) * charWidth + padding
            return min(max(computed, minWidth), maxWidth)
        }
    }
    
    var body: some View {
        let widths = columnWidths
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(Array(result.rows.enumerated()), id: \.offset) { index, row in
                                ResultRow(
                                    rowIndex: index,
                                    columns: result.columns,
                                    values: row,
                                    columnWidths: widths,
                                    isAlternate: index % 2 == 1,
                                    isSelected: isFocused && selectedRow == index,
                                    selectedColumn: isFocused ? selectedColumn : nil,
                                    theme: theme,
                                    fontSize: fontSize
                                )
                            }
                        } header: {
                            HeaderRow(
                                columns: result.columns,
                                columnWidths: widths,
                                theme: theme,
                                fontSize: fontSize,
                                selectedColumn: isFocused ? selectedColumn : nil
                            )
                        }
                    }
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                }
                .onChange(of: selectedRow) { _, _ in
                    scrollToCell(proxy: proxy)
                }
                .onChange(of: selectedColumn) { _, _ in
                    scrollToCell(proxy: proxy)
                }
            }
        }
    }
    
    private func scrollToCell(proxy: ScrollViewProxy) {
        guard let row = selectedRow else { return }
        let cellId = "cell-\(row)-\(selectedColumn)"
        withAnimation(.easeInOut(duration: 0.1)) {
            proxy.scrollTo(cellId, anchor: .center)
        }
    }
}

struct HeaderRow: View {
    let columns: [String]
    let columnWidths: [CGFloat]
    let theme: Theme
    let fontSize: CGFloat
    var selectedColumn: Int? = nil
    @State private var copiedIndex: Int? = nil
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                Text(copiedIndex == index ? "Copied!" : column)
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundColor(copiedIndex == index ? theme.successColor : theme.foregroundColor)
                    .frame(width: index < columnWidths.count ? columnWidths[index] : 100, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(selectedColumn == index ? theme.editorSelectionColor.opacity(0.3) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(column, forType: .string)
                        copiedIndex = index
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            if copiedIndex == index {
                                copiedIndex = nil
                            }
                        }
                    }
                
                Divider()
                    .background(theme.borderColor)
            }
        }
        .background(theme.tableHeaderColor)
    }
}

struct ResultRow: View {
    let rowIndex: Int
    let columns: [String]
    let values: [String]
    let columnWidths: [CGFloat]
    let isAlternate: Bool
    var isSelected: Bool = false
    var selectedColumn: Int? = nil
    let theme: Theme
    let fontSize: CGFloat
    @State private var copiedIndex: Int? = nil
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, _ in
                let value = index < values.count ? values[index] : ""
                let isCellSelected = isSelected && selectedColumn == index
                Text(copiedIndex == index ? "Copied!" : value)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(copiedIndex == index ? theme.successColor : (value == "NULL" ? theme.commentColor : theme.foregroundColor))
                    .frame(width: index < columnWidths.count ? columnWidths[index] : 100, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .lineLimit(1)
                    .background(
                        isCellSelected ? theme.editorSelectionColor.opacity(0.7) :
                        (isSelected ? theme.editorSelectionColor.opacity(0.15) :
                        Color.clear)
                    )
                    .contentShape(Rectangle())
                    .id("cell-\(rowIndex)-\(index)")
                    .onTapGesture {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                        copiedIndex = index
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            if copiedIndex == index {
                                copiedIndex = nil
                            }
                        }
                    }
                
                Divider()
                    .background(theme.borderColor)
            }
        }
        .background(
            isSelected ? theme.editorSelectionColor.opacity(0.1) :
            (isAlternate ? theme.tableAlternateRowColor : theme.backgroundColor)
        )
    }
}

struct StatusBar: View {
    let result: QueryResult
    let theme: Theme
    let fontSize: CGFloat
    
    var body: some View {
        HStack {
            Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(result.isSuccess ? theme.successColor : theme.errorColor)
            
            Text(result.summary)
                .font(.system(size: max(fontSize - 2, 10), design: .monospaced))
                .foregroundColor(theme.foregroundColor)
            
            Spacer()
            
            if !result.columns.isEmpty {
                Text("\(result.columns.count) columns")
                    .font(.system(size: max(fontSize - 2, 10), design: .monospaced))
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
    let fontSize: CGFloat
    @State private var copied = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: fontSize + 4))
                    .foregroundColor(theme.errorColor)
                
                Text("Query Error")
                    .font(.system(size: fontSize + 2, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.foregroundColor)
            }
            
            Text(copied ? "Copied!" : message)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundColor(copied ? theme.successColor : theme.errorColor)
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.secondaryBackgroundColor)
                .cornerRadius(8)
                .contentShape(Rectangle())
                .onTapGesture {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        copied = false
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}

struct SuccessView: View {
    let message: String
    let theme: Theme
    let fontSize: CGFloat
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: fontSize + 4))
                    .foregroundColor(theme.successColor)
                
                Text("Query Executed")
                    .font(.system(size: fontSize + 2, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.foregroundColor)
            }
            
            Text(message)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundColor(theme.foregroundColor.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}

struct TableInfoView: View {
    let info: TableSchemaInfo
    var filteredColumns: [DatabaseColumn]?
    let theme: Theme
    let fontSize: CGFloat
    var selectedRow: Int? = nil
    var isFocused: Bool = false
    
    private var displayColumns: [DatabaseColumn] {
        filteredColumns ?? info.columns
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with table name and stats
            HStack {
                Image(systemName: info.table.type == .view ? "eye.fill" : "tablecells.fill")
                    .foregroundColor(theme.keywordColor)
                
                Text(info.table.fullName)
                    .font(.system(size: fontSize + 2, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.foregroundColor)
                
                Spacer()
                
                if let rowCount = info.approximateRowCount {
                    Text("~\(rowCount.formatted()) rows")
                        .font(.system(size: fontSize - 1, design: .monospaced))
                        .foregroundColor(theme.foregroundColor.opacity(0.7))
                }
                
                if let size = info.tableSize {
                    Text(size)
                        .font(.system(size: fontSize - 1, design: .monospaced))
                        .foregroundColor(theme.foregroundColor.opacity(0.7))
                        .padding(.leading, 8)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(theme.secondaryBackgroundColor)
            
            Divider()
            
            // Columns table
            let columns = ["column", "type", "nullable", "default", "pk"]
            let rows: [[String]] = displayColumns.map { col in
                [
                    col.name,
                    col.dataType,
                    col.isNullable ? "yes" : "no",
                    col.defaultValue ?? "",
                    col.isPrimaryKey ? "yes" : ""
                ]
            }
            let schemaResult = QueryResult(
                columns: columns,
                rows: rows,
                rowsAffected: displayColumns.count,
                executionTime: 0
            )
            ResultsTable(
                result: schemaResult,
                theme: theme,
                fontSize: fontSize,
                selectedRow: selectedRow,
                isFocused: isFocused
            )
            
            // Footer status
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(theme.keywordColor)
                Text("\(displayColumns.count) columns")
                    .font(.system(size: max(fontSize - 2, 10), design: .monospaced))
                    .foregroundColor(theme.foregroundColor)
                Spacer()
                Text(info.table.type.rawValue.lowercased())
                    .font(.system(size: max(fontSize - 2, 10), design: .monospaced))
                    .foregroundColor(theme.foregroundColor.opacity(0.7))
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(theme.secondaryBackgroundColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct EmptyStateView: View {
    let theme: Theme
    let fontSize: CGFloat
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "text.cursor")
                    .font(.system(size: fontSize + 4))
                    .foregroundColor(theme.foregroundColor.opacity(0.5))
                
                Text("No Results")
                    .font(.system(size: fontSize + 2, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.foregroundColor)
            }
            
            Text("Write a query and press Cmd+Return to execute")
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundColor(theme.foregroundColor.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}

#Preview {
    ResultsTableView(viewModel: DatabaseViewModel())
        .environmentObject(ThemeManager())
}
