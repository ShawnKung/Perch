#!/bin/bash
set -euo pipefail
ROOT="$(dirname "$(realpath "$0")")"
APP="$ROOT/build/Perch.app"
printf '[%s] [编译中] Perch\n' "$(date '+%H:%M:%S')"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Cache the vault executable so browser updates do not change its Keychain identity.
VAULT_HASH="$(shasum -a 256 "$ROOT/VaultHelper.swift" | cut -d' ' -f1)"
VAULT_CACHE="$HOME/Library/Application Support/Perch Signing"
mkdir -p "$VAULT_CACHE"
if [[ ! -f "$VAULT_CACHE/PerchVault" || "$(cat "$VAULT_CACHE/vault-source-hash" 2>/dev/null || true)" != "$VAULT_HASH" ]]; then
  swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
    "$ROOT/VaultHelper.swift" -framework Security -framework CryptoKit -o "$VAULT_CACHE/PerchVault"
  bash "$ROOT/sign-app.sh" "$VAULT_CACHE/PerchVault"
  printf '%s' "$VAULT_HASH" > "$VAULT_CACHE/vault-source-hash"
fi
cp "$VAULT_CACHE/PerchVault" "$APP/Contents/MacOS/PerchVault"
AI_HASH="$(shasum -a 256 "$ROOT/AIKeyHelper.swift" | cut -d' ' -f1)"
if [[ ! -f "$VAULT_CACHE/PerchAIKeys" || "$(cat "$VAULT_CACHE/ai-key-source-hash" 2>/dev/null || true)" != "$AI_HASH" ]]; then
  swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
    "$ROOT/AIKeyHelper.swift" -framework Security -framework CryptoKit -framework LocalAuthentication -o "$VAULT_CACHE/PerchAIKeys"
  bash "$ROOT/sign-app.sh" "$VAULT_CACHE/PerchAIKeys"
  printf '%s' "$AI_HASH" > "$VAULT_CACHE/ai-key-source-hash"
fi
cp "$VAULT_CACHE/PerchAIKeys" "$APP/Contents/MacOS/PerchAIKeys"
swiftc -swift-version 5 -parse-as-library -Osize -whole-module-optimization -lto=llvm-full -target "$(uname -m)-apple-macosx13.0" \
  "$ROOT/URLInput.swift" "$ROOT/Settings.swift" "$ROOT/BrowserImport.swift" "$ROOT/AIChat.swift" "$ROOT/AISearch.swift" "$ROOT/AIGeneratedFile.swift" "$ROOT/AIFilePreview.swift" "$ROOT/AIInteraction.swift" "$ROOT/AITable.swift" "$ROOT/AIAttachment.swift" "$ROOT/AIMarkdown.swift" "$ROOT/AIDiagram.swift" "$ROOT/AIHistory.swift" "$ROOT/AIViews.swift" "$ROOT/AISelfCheck.swift" \
  "$ROOT/Library.swift" "$ROOT/Bookmarks.swift" "$ROOT/LinkPreview.swift" "$ROOT/Passwords.swift" "$ROOT/AddressSuggestions.swift" "$ROOT/NativeTabs.swift" "$ROOT/Favicon.swift" "$ROOT/ImportView.swift" "$ROOT/SelfTests.swift" "$ROOT/AIExperienceCheck.swift" "$ROOT/main.swift" \
  -framework AppKit -framework SwiftUI -framework WebKit -framework PDFKit -framework Carbon -framework ServiceManagement -framework Security -lsqlite3 \
  -o "$APP/Contents/MacOS/Perch"
xcrun strip -S -x "$APP/Contents/MacOS/Perch"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE-Perch.txt"
swift "$ROOT/make-icon.swift" "$ROOT/build/Perch.iconset" "$ROOT/assets/noto-bird.png"
iconutil --convert icns "$ROOT/build/Perch.iconset" --output "$APP/Contents/Resources/Perch.icns"
python3 "$ROOT/optimize-icon.py" "$APP/Contents/Resources/Perch.icns"
cp "$ROOT/assets/LICENSE-noto.txt" "$ROOT/assets/ATTRIBUTION.md" "$APP/Contents/Resources/"
# Rebuild this derived directory so removed or renamed assets cannot survive incremental builds.
rm -rf "$APP/Contents/Resources/markdown"
cp -R "$ROOT/assets/markdown" "$APP/Contents/Resources/"
swift -e 'import Foundation; let root = URL(fileURLWithPath: CommandLine.arguments[1]); for name in ["mermaid.js", "marked.js", "purify.js", "diagram.js", "diagram.css", "tables.js"] { let source = root.appendingPathComponent(name); let data = try Data(contentsOf: source); let packed = try (data as NSData).compressed(using: .lzma); let restored = try packed.decompressed(using: .lzma) as Data; precondition(restored == data); let output = name == "mermaid.js" ? "mermaid.lzma" : name + ".lzma"; try (packed as Data).write(to: root.appendingPathComponent(output)); try FileManager.default.removeItem(at: source) }' \
  "$APP/Contents/Resources/markdown"
bash "$ROOT/sign-app.sh" "$APP"
printf '[%s] [完成] %s\n' "$(date '+%H:%M:%S')" "$APP"
if [[ "${1:-}" == "--run" ]]; then open "$APP"; fi
