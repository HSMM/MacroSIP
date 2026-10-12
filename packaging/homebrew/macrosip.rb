cask "macrosip" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/HSMM/MacroSIP/releases/download/#{version}/MacroSIP-#{version}.dmg"
  name "MacroSIP"
  desc "SIP softphone"
  homepage "https://github.com/HSMM/MacroSIP"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "MacroSIP.app"

  zap trash: [
    "~/Library/Application Support/MacroSIP",
    "~/Library/Logs/MacroSIP",
    "~/Library/Preferences/com.hsmm.macrosip.plist",
  ]

  caveats <<~EOS
    MacroSIP is signed ad hoc, not notarized. On first launch macOS may refuse to open it.
    Either right-click the app in /Applications and choose Open, or run:
      xattr -dr com.apple.quarantine /Applications/MacroSIP.app
  EOS
end
