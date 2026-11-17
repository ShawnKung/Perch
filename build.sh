#!/bin/bash
set -euo pipefail
ROOT="$(dirname "$(realpath "$0")")"
APP="$ROOT/build/Perch.app"
printf '[%s] [编译中] Perch\n' "$(date '+%H:%M:%S')"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Cache the vault executable so browser updates do not change its Keychain identity.
VAULT_HASH="$(shasum -a 256 "$ROOT/src/Helpers/VaultHelper.swift" | cut -d' ' -f1)"
VAULT_CACHE="$HOME/Library/Application Support/Perch Signing"
mkdir -p "$VAULT_CACHE"
if [[ ! -f "$VAULT_CACHE/PerchVault" || "$(cat "$VAULT_CACHE/vault-source-hash" 2>/dev/null || true)" != "$VAULT_HASH" ]]; then
  swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
    "$ROOT/src/Helpers/VaultHelper.swift" -framework Security -framework CryptoKit -o "$VAULT_CACHE/PerchVault"
  bash "$ROOT/scripts/sign-app.sh" "$VAULT_CACHE/PerchVault"
  printf '%s' "$VAULT_HASH" > "$VAULT_CACHE/vault-source-hash"
fi
cp "$VAULT_CACHE/PerchVault" "$APP/Contents/MacOS/PerchVault"
AI_HASH="$(shasum -a 256 "$ROOT/src/Helpers/AIKeyHelper.swift" | cut -d' ' -f1)"
if [[ ! -f "$VAULT_CACHE/PerchAIKeys" || "$(cat "$VAULT_CACHE/ai-key-source-hash" 2>/dev/null || true)" != "$AI_HASH" ]]; then
  swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
    "$ROOT/src/Helpers/AIKeyHelper.swift" -framework Security -framework CryptoKit -framework LocalAuthentication -o "$VAULT_CACHE/PerchAIKeys"
  bash "$ROOT/scripts/sign-app.sh" "$VAULT_CACHE/PerchAIKeys"
  printf '%s' "$AI_HASH" > "$VAULT_CACHE/ai-key-source-hash"
fi
cp "$VAULT_CACHE/PerchAIKeys" "$APP/Contents/MacOS/PerchAIKeys"
swiftc -swift-version 5 -parse-as-library -Osize -whole-module-optimization -lto=llvm-full -target "$(uname -m)-apple-macosx13.0" \
  "$ROOT/src/Browser/URLInput.swift" "$ROOT/src/App/Settings.swift" "$ROOT/src/Browser/BrowserImport.swift" \
  "$ROOT/src/AI/AIChat.swift" "$ROOT/src/AI/AISearch.swift" "$ROOT/src/AI/AIGeneratedFile.swift" \
  "$ROOT/src/AI/AIFilePreview.swift" "$ROOT/src/AI/AIInteraction.swift" "$ROOT/src/AI/AITable.swift" \
  "$ROOT/src/AI/AIAttachment.swift" "$ROOT/src/AI/AIMarkdown.swift" "$ROOT/src/AI/AIDiagram.swift" \
  "$ROOT/src/AI/AIHistory.swift" "$ROOT/src/AI/AIViews.swift" \
  "$ROOT/src/App/Library.swift" "$ROOT/src/Browser/Bookmarks.swift" "$ROOT/src/Browser/LinkPreview.swift" \
  "$ROOT/src/Browser/Passwords.swift" "$ROOT/src/Browser/ScrollRouting.swift" "$ROOT/src/Browser/AddressSuggestions.swift" \
  "$ROOT/src/Browser/NativeTabs.swift" "$ROOT/src/Browser/TabContents.swift" "$ROOT/src/Browser/Favicon.swift" "$ROOT/src/Browser/ImportView.swift" \
  "$ROOT/tests/SelfTests.swift" "$ROOT/tests/ScrollSelfCheck.swift" "$ROOT/tests/AISelfCheck.swift" "$ROOT/tests/AIExperienceCheck.swift" \
  "$ROOT/src/App/main.swift" \
  -framework AppKit -framework SwiftUI -framework WebKit -framework PDFKit -framework Carbon -framework ServiceManagement -framework Security -lsqlite3 \
  -o "$APP/Contents/MacOS/Perch"
xcrun strip -S -x "$APP/Contents/MacOS/Perch"
cp "$ROOT/resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE-Perch.txt"
swift "$ROOT/scripts/make-icon.swift" "$ROOT/build/Perch.iconset" "$ROOT/assets/noto-bird.png"
iconutil --convert icns "$ROOT/build/Perch.iconset" --output "$APP/Contents/Resources/Perch.icns"
python3 "$ROOT/scripts/optimize-icon.py" "$APP/Contents/Resources/Perch.icns"
cp "$ROOT/assets/LICENSE-noto.txt" "$ROOT/assets/ATTRIBUTION.md" "$APP/Contents/Resources/"
# Rebuild this derived directory so removed or renamed assets cannot survive incremental builds.
rm -rf "$APP/Contents/Resources/markdown"
cp -R "$ROOT/assets/markdown" "$APP/Contents/Resources/"
swift -e 'import Foundation; let root = URL(fileURLWithPath: CommandLine.arguments[1]); for name in ["mermaid.js", "marked.js", "purify.js", "diagram.js", "diagram.css", "tables.js"] { let source = root.appendingPathComponent(name); let data = try Data(contentsOf: source); let packed = try (data as NSData).compressed(using: .lzma); let restored = try packed.decompressed(using: .lzma) as Data; precondition(restored == data); let output = name == "mermaid.js" ? "mermaid.lzma" : name + ".lzma"; try (packed as Data).write(to: root.appendingPathComponent(output)); try FileManager.default.removeItem(at: source) }' \
  "$APP/Contents/Resources/markdown"
bash "$ROOT/scripts/sign-app.sh" "$APP"
printf '[%s] [完成] %s\n' "$(date '+%H:%M:%S')" "$APP"
if [[ "${1:-}" == "--run" ]]; then open "$APP"; fi
