import SwiftUI

/// Nord Theme implementation
/// Based on the Nord color palette: https://www.nordtheme.com/
struct NordTheme: Theme {
    let name = "Nord"
    
    // Nord Polar Night (dark backgrounds)
    private let nord0 = Color(red: 0.180, green: 0.204, blue: 0.251)  // #2E3440
    private let nord1 = Color(red: 0.231, green: 0.259, blue: 0.322)  // #3B4252
    private let nord2 = Color(red: 0.263, green: 0.298, blue: 0.369)  // #434C5E
    private let nord3 = Color(red: 0.298, green: 0.337, blue: 0.416)  // #4C566A
    
    // Nord Snow Storm (light text/backgrounds)
    private let nord4 = Color(red: 0.847, green: 0.871, blue: 0.914)  // #D8DEE9
    private let nord5 = Color(red: 0.898, green: 0.914, blue: 0.941)  // #E5E9F0
    private let nord6 = Color(red: 0.925, green: 0.937, blue: 0.957)  // #ECEFF4
    
    // Nord Frost (accent blues/greens)
    private let nord7 = Color(red: 0.557, green: 0.737, blue: 0.733)  // #8FBCBB
    private let nord8 = Color(red: 0.533, green: 0.753, blue: 0.816)  // #88C0D0
    private let nord9 = Color(red: 0.506, green: 0.631, blue: 0.757)  // #81A1C1
    private let nord10 = Color(red: 0.369, green: 0.506, blue: 0.675) // #5E81AC
    
    // Nord Aurora (accents)
    private let nord11 = Color(red: 0.749, green: 0.380, blue: 0.416) // #BF616A - Red
    private let nord12 = Color(red: 0.816, green: 0.529, blue: 0.439) // #D08770 - Orange
    private let nord13 = Color(red: 0.922, green: 0.796, blue: 0.545) // #EBCB8B - Yellow
    private let nord14 = Color(red: 0.639, green: 0.745, blue: 0.549) // #A3BE8C - Green
    private let nord15 = Color(red: 0.706, green: 0.557, blue: 0.678) // #B48EAD - Purple
    
    // MARK: - Theme Protocol Implementation
    
    // Base colors
    var backgroundColor: Color { nord0 }
    var foregroundColor: Color { nord4 }
    var secondaryBackgroundColor: Color { nord1 }
    var accentColor: Color { nord8 }
    
    // Editor colors
    var editorBackgroundColor: Color { nord0 }
    var editorForegroundColor: Color { nord4 }
    var editorLineNumberColor: Color { nord3 }
    var editorSelectionColor: Color { nord2 }
    var editorCursorColor: Color { nord4 }
    
    // Syntax highlighting
    var keywordColor: Color { nord9 }      // SQL keywords like SELECT, FROM, WHERE
    var stringColor: Color { nord14 }       // String literals
    var numberColor: Color { nord15 }       // Numeric values
    var commentColor: Color { nord3 }       // Comments
    var functionColor: Color { nord8 }      // Function names
    var typeColor: Color { nord7 }          // Data types
    var operatorColor: Color { nord9 }      // Operators
    
    // UI colors
    var sidebarBackgroundColor: Color { nord1 }
    var sidebarForegroundColor: Color { nord4 }
    var sidebarSelectionColor: Color { nord2 }
    var tableHeaderColor: Color { nord2 }
    var tableAlternateRowColor: Color { nord1 }
    var borderColor: Color { nord3 }
    
    // Status colors
    var successColor: Color { nord14 }
    var errorColor: Color { nord11 }
    var warningColor: Color { nord13 }
    
    // Vim mode colors
    var vimNormalModeColor: Color { nord9 }
    var vimInsertModeColor: Color { nord14 }
    var vimVisualModeColor: Color { nord15 }
    var vimCommandModeColor: Color { nord12 }
}

/// Nord Light variant
struct NordLightTheme: Theme {
    let name = "Nord Light"
    
    // Nord Snow Storm (light backgrounds)
    private let nord4 = Color(red: 0.847, green: 0.871, blue: 0.914)  // #D8DEE9
    private let nord5 = Color(red: 0.898, green: 0.914, blue: 0.941)  // #E5E9F0
    private let nord6 = Color(red: 0.925, green: 0.937, blue: 0.957)  // #ECEFF4
    
    // Nord Polar Night (dark text)
    private let nord0 = Color(red: 0.180, green: 0.204, blue: 0.251)  // #2E3440
    private let nord1 = Color(red: 0.231, green: 0.259, blue: 0.322)  // #3B4252
    private let nord2 = Color(red: 0.263, green: 0.298, blue: 0.369)  // #434C5E
    private let nord3 = Color(red: 0.298, green: 0.337, blue: 0.416)  // #4C566A
    
    // Nord Frost (accent blues/greens)
    private let nord7 = Color(red: 0.557, green: 0.737, blue: 0.733)  // #8FBCBB
    private let nord8 = Color(red: 0.533, green: 0.753, blue: 0.816)  // #88C0D0
    private let nord9 = Color(red: 0.506, green: 0.631, blue: 0.757)  // #81A1C1
    private let nord10 = Color(red: 0.369, green: 0.506, blue: 0.675) // #5E81AC
    
    // Nord Aurora (accents)
    private let nord11 = Color(red: 0.749, green: 0.380, blue: 0.416) // #BF616A - Red
    private let nord12 = Color(red: 0.816, green: 0.529, blue: 0.439) // #D08770 - Orange
    private let nord13 = Color(red: 0.922, green: 0.796, blue: 0.545) // #EBCB8B - Yellow
    private let nord14 = Color(red: 0.639, green: 0.745, blue: 0.549) // #A3BE8C - Green
    private let nord15 = Color(red: 0.706, green: 0.557, blue: 0.678) // #B48EAD - Purple
    
    // MARK: - Theme Protocol Implementation
    
    var backgroundColor: Color { nord6 }
    var foregroundColor: Color { nord0 }
    var secondaryBackgroundColor: Color { nord5 }
    var accentColor: Color { nord10 }
    
    var editorBackgroundColor: Color { nord6 }
    var editorForegroundColor: Color { nord0 }
    var editorLineNumberColor: Color { nord3 }
    var editorSelectionColor: Color { nord4 }
    var editorCursorColor: Color { nord0 }
    
    var keywordColor: Color { nord10 }
    var stringColor: Color { nord14 }
    var numberColor: Color { nord15 }
    var commentColor: Color { nord3 }
    var functionColor: Color { nord10 }
    var typeColor: Color { nord7 }
    var operatorColor: Color { nord9 }
    
    var sidebarBackgroundColor: Color { nord5 }
    var sidebarForegroundColor: Color { nord0 }
    var sidebarSelectionColor: Color { nord4 }
    var tableHeaderColor: Color { nord4 }
    var tableAlternateRowColor: Color { nord5 }
    var borderColor: Color { nord4 }
    
    var successColor: Color { nord14 }
    var errorColor: Color { nord11 }
    var warningColor: Color { nord13 }
    
    var vimNormalModeColor: Color { nord10 }
    var vimInsertModeColor: Color { nord14 }
    var vimVisualModeColor: Color { nord15 }
    var vimCommandModeColor: Color { nord12 }
}
