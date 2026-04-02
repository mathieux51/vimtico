cask "vimtico" do
  version "0.1.0"
  sha256 :no_check  # Update with actual SHA256 after first release

  url "https://github.com/mathieux51/vimtico/releases/download/v#{version}/Vimtico.dmg"
  name "Vimtico"
  desc "Native macOS PostgreSQL client with Vim mode and Nord theme"
  homepage "https://github.com/mathieux51/vimtico"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Vimtico.app"

  zap trash: [
    "~/.config/vimtico",
    "~/Library/Preferences/com.mathieux51.Vimtico.plist",
    "~/Library/Application Support/Vimtico",
  ]
end
