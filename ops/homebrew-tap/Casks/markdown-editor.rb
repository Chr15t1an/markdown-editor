cask "markdown-editor" do
  version "0.3.2"
  sha256 "f1486a31b68dfa25d22bb2626148f97a608778e3e4a1875238eb38e1951c5180"

  url "https://markdown.chri5tian.com/Markdown-Editor-#{version}.zip"
  name "Markdown Editor"
  desc "Native markdown editor that renders formatting inline as you type"
  homepage "https://markdown.chri5tian.com/"

  livecheck do
    url "https://markdown.chri5tian.com/version.json"
    strategy :json do |json|
      json["version"]
    end
  end

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Markdown Editor.app"

  zap trash: "~/Library/Preferences/com.chri5tian.markdown-editor.plist"

  caveats <<~EOS
    Markdown Editor is signed ad-hoc, not with an Apple Developer ID, and is not notarized,
    so macOS blocks its first launch. Open it once, click Done, then go to
    System Settings > Privacy & Security > Security and click Open Anyway next to
    "Markdown Editor" was blocked. It opens normally after that.

    To install without that step, use the Terminal installer instead (it checks the SHA-256):
      curl -fsSL https://markdown.chri5tian.com/install.sh | bash

    Updates: run `brew upgrade --cask markdown-editor`. The app's own Check for Updates
    sheet links to the website, not to Homebrew.
  EOS
end
