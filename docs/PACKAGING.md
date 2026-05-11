# Packaging & Distribution

Current state: **Path A (Homebrew formula)** is shipping. **Path B (notarized cask)** is the planned next step.

---

## Path A — Homebrew formula (current, v0.2)

`Formula/chikki.rb` ships in this repo. Users install via repo-as-tap:

```bash
brew tap kshitijagrwl/chikki https://github.com/kshitijagrwl/chikki-voice-notes
brew install kshitijagrwl/chikki/chikki
```

What the formula does:

1. Creates a virtualenv inside the keg under `libexec/venv/`
2. Installs Python deps from `requirements.txt` (no per-package `resource` blocks — too brittle with pyannote/torch's wheel tree)
3. Builds Swift binaries: `ChikkiApp` (wrapped as `Chikki.app`) and `chikki-syscap` (system-audio helper)
4. Drops three things on PATH:
   - `chikki` — CLI wrapper that activates the venv
   - `chikki-syscap` — Swift binary, located by the Python recorder
   - `chikki-app` — launcher that does `open .../Chikki.app`

**Known limitations:**
- No code signing or notarization — first launch of `Chikki.app` requires right-click → Open to bypass Gatekeeper
- No auto-update mechanism — users `brew upgrade chikki` manually
- Install is not bit-for-bit reproducible (pip resolves transitive deps at install time)
- pyannote + torch wheels are ~1 GB; install takes a few minutes
- Config lives in `~/.config/chikki/` (env), `~/Documents/Chikki/` (notes) — not the repo

**Updating the formula on a new release:**

```bash
# Tag and push
git tag v0.X && git push --tags

# Compute sha256
shasum -a 256 <(curl -L https://github.com/kshitijagrwl/chikki-voice-notes/archive/refs/tags/v0.X.tar.gz)

# Update url + sha256 in Formula/chikki.rb, commit, push
```

---

## Path B — Notarized DMG + cask (planned, v0.3)

The polished path Muesli takes. Required steps:

### Prerequisites

- **Apple Developer ID** ($99/yr): `Developer ID Application` certificate + `Developer ID Installer` certificate
- **App-specific password** for notarytool, stored once via `xcrun notarytool store-credentials`

### Build pipeline

A `scripts/release.sh` that:

1. **Build release binaries**
   ```bash
   cd menubar && swift build -c release
   ```

2. **Bundle the .app properly**
   - `Chikki.app/Contents/MacOS/Chikki` (universal arm64 binary)
   - `Chikki.app/Contents/MacOS/chikki-syscap` (shipped inside the bundle, not on PATH)
   - `Chikki.app/Contents/Resources/python/` — embedded Python (see below)
   - `Chikki.app/Contents/Info.plist` with usage descriptions
   - `Chikki.app/Contents/embedded.provisionprofile` if needed

3. **Embed Python** — options:
   - **Option 1:** `python-build-standalone` static Python + `pip install` deps into `Resources/python/`. ~120 MB, predictable.
   - **Option 2:** PyInstaller one-folder build. Smaller, but pyannote's lazy imports can break under PyInstaller's import hooks. Avoid.
   - **Option 3:** Ship a script that downloads + provisions Python on first launch. Easy to build, awkward UX.

   **Recommendation:** python-build-standalone. Add a step that strips unused stdlib modules to shrink the bundle.

4. **Code-sign** every binary in the bundle, then sign the bundle itself with hardened runtime:
   ```bash
   codesign --force --options runtime --sign "Developer ID Application: ..." \
            --entitlements Muesli.entitlements \
            Chikki.app/Contents/MacOS/chikki-syscap
   # ... repeat for Python binaries inside Resources/python/bin/
   codesign --force --options runtime --sign "Developer ID Application: ..." \
            --entitlements Chikki.entitlements Chikki.app
   ```

5. **Build the DMG** with `create-dmg`:
   ```bash
   create-dmg --volname Chikki --background dmg-bg.png --icon-size 100 \
              --app-drop-link 480 250 --icon "Chikki.app" 160 250 \
              Chikki.dmg Chikki.app
   ```

6. **Notarize**:
   ```bash
   xcrun notarytool submit Chikki.dmg --keychain-profile chikki-notary --wait
   xcrun stapler staple Chikki.dmg
   ```

7. **Upload to GitHub Releases** with `gh release create`.

8. **Update the cask** in a dedicated `homebrew-chikki` tap:
   ```ruby
   cask "chikki" do
     version "0.3.0"
     sha256 "..."
     url "https://github.com/kshitijagrwl/chikki-voice-notes/releases/download/v#{version}/Chikki.dmg"
     name "Chikki"
     desc "Local meeting transcription + AI notes"
     homepage "https://github.com/kshitijagrwl/chikki-voice-notes"
     app "Chikki.app"
     zap trash: [
       "~/Library/Application Support/Chikki",
       "~/Library/Preferences/com.chikki.app.plist",
     ]
   end
   ```

### Auto-updates (Sparkle)

Muesli ships `appcast.xml` on their website + Sparkle in the app. For Chikki v0.3:

- Add Sparkle as a SwiftPM dependency
- Host `appcast.xml` on GitHub Pages or any static host
- Each release: regenerate `appcast.xml` (Muesli's `update_appcast_release_notes.py` is a good reference)
- Users get update prompts in-app

### Entitlements (`Chikki.entitlements`)

```xml
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.device.screen-capture</key><true/>
<key>com.apple.security.personal-information.calendars</key><true/>
<key>com.apple.security.automation.apple-events</key><true/>
<key>com.apple.security.cs.allow-jit</key><true/>            <!-- torch/MLX -->
<key>com.apple.security.cs.disable-library-validation</key><true/>  <!-- bundled Python -->
```

### First-run wizard (#13, not yet tracked)

Path B's UX payoff. On first launch:

1. Pick LLM provider, paste API key (writes to `~/Library/Application Support/Chikki/.env`)
2. Prompt for Mic + Screen Recording + Calendar permissions in sequence
3. Optional: download Whisper model with progress bar
4. Optional: HF token + EULA deep-link for diarization
5. Optional: enroll yourself as a speaker

Without this, Path B doesn't actually improve the install experience over Path A.

---

## Why not Path C (Mac App Store)

- ScreenCaptureKit + EventKit are allowed but tightly reviewed
- Bundled Python + arbitrary HF model downloads + BYOK third-party APIs don't fit MAS review well
- `com.apple.security.cs.disable-library-validation` is a hard MAS reject
- Sandbox would block writing to `~/Documents/Chikki/` without a user file picker per save

Skip MAS until the project is mature enough to justify a full sandboxed rewrite (or stays out forever).
