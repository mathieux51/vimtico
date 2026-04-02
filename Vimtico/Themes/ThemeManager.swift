import SwiftUI

class ThemeManager: ObservableObject {
    @Published var currentTheme: Theme = NordTheme()
    @Published var currentThemeName: String = "Nord"
    
    private var themes: [String: Theme] = [
        "Light": DefaultLightTheme(),
        "Dark": DefaultDarkTheme(),
        "Nord": NordTheme(),
        "Nord Light": NordLightTheme()
    ]
    
    var availableThemes: [String] {
        Array(themes.keys).sorted()
    }
    
    func setTheme(named name: String) {
        if let theme = themes[name] {
            currentTheme = theme
            currentThemeName = name
        }
    }
    
    func theme(named name: String) -> Theme {
        themes[name] ?? currentTheme
    }
    
    func registerTheme(_ theme: Theme) {
        themes[theme.name] = theme
    }
    
    /// Load custom themes from JSON configuration
    func loadCustomTheme(from json: [String: Any]) -> Theme? {
        guard let name = json["name"] as? String else { return nil }
        
        let theme = CustomTheme(
            name: name,
            colors: json
        )
        
        registerTheme(theme)
        return theme
    }
}

/// A custom theme that can be loaded from JSON configuration
struct CustomTheme: Theme {
    let name: String
    private let colors: [String: Any]
    
    init(name: String, colors: [String: Any]) {
        self.name = name
        self.colors = colors
    }
    
    private func color(for key: String, default defaultColor: Color) -> Color {
        guard let hex = colors[key] as? String else { return defaultColor }
        return Color(hex: hex) ?? defaultColor
    }
    
    var backgroundColor: Color { color(for: "backgroundColor", default: .black) }
    var foregroundColor: Color { color(for: "foregroundColor", default: .white) }
    var secondaryBackgroundColor: Color { color(for: "secondaryBackgroundColor", default: .gray) }
    var accentColor: Color { color(for: "accentColor", default: .blue) }
    
    var editorBackgroundColor: Color { color(for: "editorBackgroundColor", default: backgroundColor) }
    var editorForegroundColor: Color { color(for: "editorForegroundColor", default: foregroundColor) }
    var editorLineNumberColor: Color { color(for: "editorLineNumberColor", default: .gray) }
    var editorSelectionColor: Color { color(for: "editorSelectionColor", default: .blue.opacity(0.3)) }
    var editorCursorColor: Color { color(for: "editorCursorColor", default: foregroundColor) }
    
    var keywordColor: Color { color(for: "keywordColor", default: .purple) }
    var stringColor: Color { color(for: "stringColor", default: .green) }
    var numberColor: Color { color(for: "numberColor", default: .blue) }
    var commentColor: Color { color(for: "commentColor", default: .gray) }
    var functionColor: Color { color(for: "functionColor", default: .blue) }
    var typeColor: Color { color(for: "typeColor", default: .cyan) }
    var operatorColor: Color { color(for: "operatorColor", default: foregroundColor) }
    
    var sidebarBackgroundColor: Color { color(for: "sidebarBackgroundColor", default: secondaryBackgroundColor) }
    var sidebarForegroundColor: Color { color(for: "sidebarForegroundColor", default: foregroundColor) }
    var sidebarSelectionColor: Color { color(for: "sidebarSelectionColor", default: accentColor) }
    var tableHeaderColor: Color { color(for: "tableHeaderColor", default: secondaryBackgroundColor) }
    var tableAlternateRowColor: Color { color(for: "tableAlternateRowColor", default: backgroundColor.opacity(0.5)) }
    var borderColor: Color { color(for: "borderColor", default: .gray) }
    
    var successColor: Color { color(for: "successColor", default: .green) }
    var errorColor: Color { color(for: "errorColor", default: .red) }
    var warningColor: Color { color(for: "warningColor", default: .orange) }
    
    var vimNormalModeColor: Color { color(for: "vimNormalModeColor", default: .blue) }
    var vimInsertModeColor: Color { color(for: "vimInsertModeColor", default: .green) }
    var vimVisualModeColor: Color { color(for: "vimVisualModeColor", default: .purple) }
    var vimCommandModeColor: Color { color(for: "vimCommandModeColor", default: .orange) }
}

extension Color {
    /// Initialize Color from hex string (e.g., "#2E3440" or "2E3440")
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }
        
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        
        self.init(red: r, green: g, blue: b)
    }
}
