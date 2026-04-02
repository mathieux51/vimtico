# Vimtico

A native macOS PostgreSQL client with Vim mode and Nord theme support. Built with SwiftUI.

## Features

- **Native macOS App**: Built with SwiftUI for a seamless Mac experience
- **Vim Mode**: Full Vim keybindings in the query editor (toggle with Cmd+Shift+V)
- **Nord Theme**: Beautiful Nord color scheme included, with support for custom themes
- **JSON Configuration**: All settings stored in `~/.config/vimtico/config.json`
- **SQL Syntax Highlighting**: Keywords, strings, numbers, and comments are highlighted
- **Connection Management**: Save and manage multiple PostgreSQL connections
- **Query History**: Track your executed queries

## Installation

### Homebrew (Recommended)

```bash
brew install --cask mathieux51/tap/vimtico
```

### Manual Installation

1. Download the latest release from [GitHub Releases](https://github.com/mathieux51/vimtico/releases)
2. Move `Vimtico.app` to your Applications folder

### Building from Source

Requirements:
- Xcode 15+
- macOS 14.0+

```bash
git clone https://github.com/mathieux51/vimtico.git
cd vimtico
open Vimtico.xcodeproj
```

Build with Xcode or from command line:
```bash
xcodebuild -project Vimtico.xcodeproj -scheme Vimtico -configuration Release
```

## Configuration

Vimtico stores its configuration in `~/.config/vimtico/config.json`. Here's an example configuration:

```json
{
  "theme": "Nord",
  "vimMode": {
    "enabled": true,
    "relativeLineNumbers": false,
    "cursorBlink": true
  },
  "editor": {
    "fontSize": 14,
    "fontFamily": "SF Mono",
    "tabSize": 4,
    "insertSpaces": true,
    "wordWrap": true,
    "showLineNumbers": true
  }
}
```

### Available Themes

- `Light` - System light theme
- `Dark` - System dark theme
- `Nord` - Nord dark theme (default)
- `Nord Light` - Nord light variant

### Custom Themes

You can define custom themes in your configuration:

```json
{
  "theme": "My Custom Theme",
  "customThemes": [
    {
      "name": "My Custom Theme",
      "backgroundColor": "#1a1b26",
      "foregroundColor": "#c0caf5",
      "keywordColor": "#bb9af7",
      "stringColor": "#9ece6a",
      "numberColor": "#ff9e64",
      "commentColor": "#565f89"
    }
  ]
}
```

## Vim Mode

Vimtico includes a Vim emulation mode for the query editor. Toggle it with `Cmd+Shift+V` or enable it by default in settings.

### Supported Commands

**Normal Mode:**
- `h/j/k/l` - Movement
- `w/b` - Word movement
- `0/$` - Line start/end
- `^` - First non-blank
- `gg/G` - Document start/end
- `i/a/I/A` - Enter insert mode
- `o/O` - Insert line below/above
- `dd` - Delete line
- `yy` - Yank line
- `p` - Paste
- `u` - Undo
- `Ctrl+r` - Redo
- `v/V` - Visual mode

**Visual Mode:**
- Movement keys extend selection
- `d/x` - Delete selection
- `y` - Yank selection

**Command Mode:**
- `:` - Enter command mode
- `:{number}` - Go to line

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+N` | New Connection |
| `Cmd+Return` | Execute Query |
| `Cmd+Shift+V` | Toggle Vim Mode |
| `Esc` | Return to Normal mode (Vim) |

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by [Postico](https://eggerapps.at/postico2/)
- [Nord Theme](https://www.nordtheme.com/) color palette
- [PostgresNIO](https://github.com/vapor/postgres-nio) for PostgreSQL connectivity
