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
                        isFocused: viewModel.focusedPane == .results,
                        visualRowRange: viewModel.visualRowRange,
                        visualColumnRange: viewModel.visualColumnRange,
                        editingCell: viewModel.editingCell,
                        editingText: $viewModel.editingText,
                        isEditable: viewModel.isResultEditable,
                        pendingEdits: viewModel.pendingEdits,
                        onCommitEdit: { viewModel.commitEdit() },
                        onCancelEdit: { viewModel.cancelEditing() }
                    )
                }
                
                // Status bar
                StatusBar(
                    result: result,
                    theme: themeManager.currentTheme,
                    fontSize: resultsFontSize,
                    resultsVimMode: viewModel.resultsVimMode,
                    isFocused: viewModel.focusedPane == .results,
                    isEditable: viewModel.isResultEditable,
                    isEditing: viewModel.editingCell != nil
                )
            } else if let info = viewModel.tableInfo {
                TableInfoView(
                    info: info,
                    filteredColumns: viewModel.filteredSchemaRows,
                    theme: themeManager.currentTheme,
                    fontSize: resultsFontSize,
                    selectedRow: viewModel.selectedSchemaRow,
                    selectedColumn: viewModel.selectedResultColumn,
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
        .overlay(alignment: .bottom) {
            if viewModel.showCopiedFeedback {
                Text("Copied!")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.successColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(themeManager.currentTheme.backgroundColor)
                            .shadow(radius: 4)
                    )
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut(duration: 0.2), value: viewModel.showCopiedFeedback)
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
    var visualRowRange: ClosedRange<Int>? = nil
    var visualColumnRange: ClosedRange<Int>? = nil
    var editingCell: (row: Int, column: Int)? = nil
    @Binding var editingText: String
    var isEditable: Bool = false
    var pendingEdits: [Int: [Int: String]] = [:]
    var onCommitEdit: (() -> Void)? = nil
    var onCancelEdit: (() -> Void)? = nil
    
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
                                let isInVisualRow = visualRowRange?.contains(index) ?? false
                                ResultRow(
                                    rowIndex: index,
                                    columns: result.columns,
                                    values: row,
                                    columnWidths: widths,
                                    isAlternate: index % 2 == 1,
                                    isSelected: isFocused && selectedRow == index,
                                    selectedColumn: isFocused ? selectedColumn : nil,
                                    isInVisualSelection: isFocused && isInVisualRow,
                                    visualColumnRange: isFocused ? visualColumnRange : nil,
                                    theme: theme,
                                    fontSize: fontSize,
                                    editingColumn: editingCell?.row == index ? editingCell?.column : nil,
                                    editingText: editingCell?.row == index ? $editingText : nil,
                                    pendingEdits: pendingEdits[index],
                                    isEditable: isEditable,
                                    onCommitEdit: onCommitEdit,
                                    onCancelEdit: onCancelEdit
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
                    .background(selectedColumn == index ? theme.accentColor.opacity(0.25) : Color.clear)
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
    var isInVisualSelection: Bool = false
    var visualColumnRange: ClosedRange<Int>? = nil
    let theme: Theme
    let fontSize: CGFloat
    var editingColumn: Int? = nil
    var editingText: Binding<String>? = nil
    var pendingEdits: [Int: String]? = nil
    var isEditable: Bool = false
    var onCommitEdit: (() -> Void)? = nil
    var onCancelEdit: (() -> Void)? = nil
    @State private var copiedIndex: Int? = nil
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, _ in
                cellView(at: index)
                
                Divider()
                    .background(theme.borderColor)
            }
        }
        .background(rowBackground)
    }
    
    private var rowBackground: Color {
        if isInVisualSelection && visualColumnRange == nil {
            return theme.accentColor.opacity(0.2)
        }
        if isSelected {
            return theme.editorSelectionColor.opacity(0.15)
        }
        return isAlternate ? theme.tableAlternateRowColor : theme.backgroundColor
    }
    
    private func cellBackground(isCellSelected: Bool, isVisualCell: Bool, hasPendingEdit: Bool = false) -> Color {
        if hasPendingEdit {
            return theme.warningColor.opacity(0.15)
        }
        if isCellSelected {
            return theme.accentColor.opacity(0.35)
        }
        if isVisualCell {
            return theme.accentColor.opacity(0.2)
        }
        if isSelected {
            return theme.editorSelectionColor.opacity(0.15)
        }
        return Color.clear
    }
    
    private func cellForeground(value: String, isCopied: Bool, hasPendingEdit: Bool = false) -> Color {
        if isCopied { return theme.successColor }
        if hasPendingEdit { return theme.warningColor }
        if value == "NULL" { return theme.commentColor }
        return theme.foregroundColor
    }
    
    @ViewBuilder
    private func cellView(at index: Int) -> some View {
        let value = pendingEdits?[index] ?? (index < values.count ? values[index] : "")
        let isCellSelected = isSelected && selectedColumn == index
        let isVisualCell = isInVisualSelection && (visualColumnRange == nil || visualColumnRange!.contains(index))
        let isCopied = copiedIndex == index
        let width: CGFloat = index < columnWidths.count ? columnWidths[index] : 100
        let hasPendingEdit = pendingEdits?[index] != nil
        let isEditingThisCell = editingColumn == index
        
        if isEditingThisCell, let binding = editingText {
            EditingCellView(
                text: binding,
                width: width,
                fontSize: fontSize,
                theme: theme,
                onCommit: { onCommitEdit?() },
                onCancel: { onCancelEdit?() }
            )
            .id("cell-\(rowIndex)-\(index)")
        } else {
            Text(isCopied ? "Copied!" : value)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundColor(cellForeground(value: value, isCopied: isCopied, hasPendingEdit: hasPendingEdit))
                .frame(width: width, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .lineLimit(1)
                .background(cellBackground(isCellSelected: isCellSelected, isVisualCell: isVisualCell, hasPendingEdit: hasPendingEdit))
                .overlay(
                    isCellSelected ?
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(isEditable ? theme.successColor.opacity(0.8) : theme.accentColor.opacity(0.8), lineWidth: 2)
                    : nil
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
        }
    }
}

/// An inline text field for editing a cell value.
struct EditingCellView: View {
    @Binding var text: String
    let width: CGFloat
    let fontSize: CGFloat
    let theme: Theme
    var onCommit: () -> Void
    var onCancel: () -> Void
    @FocusState private var isFocused: Bool
    
    var body: some View {
        TextField("", text: $text)
            .font(.system(size: fontSize, design: .monospaced))
            .textFieldStyle(.plain)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(theme.editorBackgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(theme.successColor, lineWidth: 2)
            )
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onSubmit { onCommit() }
            .onExitCommand { onCancel() }
    }
}

struct StatusBar: View {
    let result: QueryResult
    let theme: Theme
    let fontSize: CGFloat
    var resultsVimMode: ResultsVimMode = .normal
    var isFocused: Bool = false
    var isEditable: Bool = false
    var isEditing: Bool = false
    
    var body: some View {
        HStack {
            // Visual mode indicator
            if isFocused && resultsVimMode != .normal {
                Text("-- \(resultsVimMode.rawValue) --")
                    .font(.system(size: max(fontSize - 2, 10), weight: .bold, design: .monospaced))
                    .foregroundColor(theme.keywordColor)
                    .padding(.trailing, 4)
            }
            
            // Edit mode indicator
            if isFocused && isEditing {
                Text("-- EDIT --")
                    .font(.system(size: max(fontSize - 2, 10), weight: .bold, design: .monospaced))
                    .foregroundColor(theme.successColor)
                    .padding(.trailing, 4)
            }
            
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
            
            if isEditable {
                Text("editable")
                    .font(.system(size: max(fontSize - 2, 10), weight: .medium, design: .monospaced))
                    .foregroundColor(theme.successColor)
                    .padding(.leading, 4)
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
    var selectedColumn: Int = 0
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
                selectedColumn: selectedColumn,
                isFocused: isFocused,
                editingText: .constant("")
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
