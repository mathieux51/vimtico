import SwiftUI

protocol Theme {
    var name: String { get }
    
    // Base colors
    var backgroundColor: Color { get }
    var foregroundColor: Color { get }
    var secondaryBackgroundColor: Color { get }
    var accentColor: Color { get }
    
    // Editor colors
    var editorBackgroundColor: Color { get }
    var editorForegroundColor: Color { get }
    var editorLineNumberColor: Color { get }
    var editorSelectionColor: Color { get }
    var editorCursorColor: Color { get }
    
    // Syntax highlighting
    var keywordColor: Color { get }
    var stringColor: Color { get }
    var numberColor: Color { get }
    var commentColor: Color { get }
    var functionColor: Color { get }
    var typeColor: Color { get }
    var operatorColor: Color { get }
    
    // UI colors
    var sidebarBackgroundColor: Color { get }
    var sidebarForegroundColor: Color { get }
    var sidebarSelectionColor: Color { get }
    var tableHeaderColor: Color { get }
    var tableAlternateRowColor: Color { get }
    var borderColor: Color { get }
    
    // Status colors
    var successColor: Color { get }
    var errorColor: Color { get }
    var warningColor: Color { get }
    
    // Vim mode colors
    var vimNormalModeColor: Color { get }
    var vimInsertModeColor: Color { get }
    var vimVisualModeColor: Color { get }
    var vimCommandModeColor: Color { get }
}

// Default light theme
struct DefaultLightTheme: Theme {
    let name = "Light"
    
    var backgroundColor: Color { Color(nsColor: .windowBackgroundColor) }
    var foregroundColor: Color { Color(nsColor: .textColor) }
    var secondaryBackgroundColor: Color { Color(nsColor: .controlBackgroundColor) }
    var accentColor: Color { .accentColor }
    
    var editorBackgroundColor: Color { Color(nsColor: .textBackgroundColor) }
    var editorForegroundColor: Color { Color(nsColor: .textColor) }
    var editorLineNumberColor: Color { Color.gray }
    var editorSelectionColor: Color { Color(nsColor: .selectedTextBackgroundColor) }
    var editorCursorColor: Color { Color(nsColor: .textColor) }
    
    var keywordColor: Color { Color(red: 0.6, green: 0.2, blue: 0.6) }
    var stringColor: Color { Color(red: 0.8, green: 0.2, blue: 0.2) }
    var numberColor: Color { Color(red: 0.1, green: 0.4, blue: 0.8) }
    var commentColor: Color { Color.gray }
    var functionColor: Color { Color(red: 0.2, green: 0.4, blue: 0.6) }
    var typeColor: Color { Color(red: 0.4, green: 0.5, blue: 0.2) }
    var operatorColor: Color { Color(nsColor: .textColor) }
    
    var sidebarBackgroundColor: Color { Color(nsColor: .windowBackgroundColor) }
    var sidebarForegroundColor: Color { Color(nsColor: .textColor) }
    var sidebarSelectionColor: Color { Color(nsColor: .selectedContentBackgroundColor) }
    var tableHeaderColor: Color { Color(nsColor: .headerColor) }
    var tableAlternateRowColor: Color { Color(nsColor: .alternatingContentBackgroundColors[1]) }
    var borderColor: Color { Color(nsColor: .separatorColor) }
    
    var successColor: Color { Color.green }
    var errorColor: Color { Color.red }
    var warningColor: Color { Color.orange }
    
    var vimNormalModeColor: Color { Color.blue }
    var vimInsertModeColor: Color { Color.green }
    var vimVisualModeColor: Color { Color.purple }
    var vimCommandModeColor: Color { Color.orange }
}

// Default dark theme
struct DefaultDarkTheme: Theme {
    let name = "Dark"
    
    var backgroundColor: Color { Color(red: 0.15, green: 0.15, blue: 0.15) }
    var foregroundColor: Color { Color.white }
    var secondaryBackgroundColor: Color { Color(red: 0.2, green: 0.2, blue: 0.2) }
    var accentColor: Color { .accentColor }
    
    var editorBackgroundColor: Color { Color(red: 0.12, green: 0.12, blue: 0.12) }
    var editorForegroundColor: Color { Color.white }
    var editorLineNumberColor: Color { Color.gray }
    var editorSelectionColor: Color { Color(red: 0.3, green: 0.3, blue: 0.4) }
    var editorCursorColor: Color { Color.white }
    
    var keywordColor: Color { Color(red: 0.8, green: 0.5, blue: 0.8) }
    var stringColor: Color { Color(red: 0.9, green: 0.6, blue: 0.5) }
    var numberColor: Color { Color(red: 0.6, green: 0.8, blue: 0.9) }
    var commentColor: Color { Color.gray }
    var functionColor: Color { Color(red: 0.6, green: 0.8, blue: 1.0) }
    var typeColor: Color { Color(red: 0.7, green: 0.9, blue: 0.6) }
    var operatorColor: Color { Color.white }
    
    var sidebarBackgroundColor: Color { Color(red: 0.18, green: 0.18, blue: 0.18) }
    var sidebarForegroundColor: Color { Color.white }
    var sidebarSelectionColor: Color { Color(red: 0.3, green: 0.3, blue: 0.35) }
    var tableHeaderColor: Color { Color(red: 0.25, green: 0.25, blue: 0.25) }
    var tableAlternateRowColor: Color { Color(red: 0.17, green: 0.17, blue: 0.17) }
    var borderColor: Color { Color(red: 0.3, green: 0.3, blue: 0.3) }
    
    var successColor: Color { Color.green }
    var errorColor: Color { Color.red }
    var warningColor: Color { Color.orange }
    
    var vimNormalModeColor: Color { Color.blue }
    var vimInsertModeColor: Color { Color.green }
    var vimVisualModeColor: Color { Color.purple }
    var vimCommandModeColor: Color { Color.orange }
}
