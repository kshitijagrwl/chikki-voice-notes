# Homebrew formula for Chikki — local meeting transcription + notes.
#
# Repo-as-tap install:
#   brew tap kshitijagrwl/chikki https://github.com/kshitijagrwl/chikki-voice-notes
#   brew install kshitijagrwl/chikki/chikki
#
# Or once moved to a dedicated tap:
#   brew tap kshitijagrwl/chikki
#   brew install chikki

class Chikki < Formula
  include Language::Python::Virtualenv

  desc "Local meeting transcription + AI notes for macOS (mic + system audio, diarization, Hinglish)"
  homepage "https://github.com/kshitijagrwl/chikki-voice-notes"
  url "https://github.com/kshitijagrwl/chikki-voice-notes/archive/refs/tags/v0.2.tar.gz"
  # Update on release: `shasum -a 256 chikki-v0.2.tar.gz`
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/kshitijagrwl/chikki-voice-notes.git", branch: "main"

  depends_on "portaudio"          # sounddevice runtime
  depends_on "ffmpeg"             # mlx-whisper preprocessing
  depends_on "python@3.13"
  depends_on :macos
  depends_on macos: :sonoma       # Settings window APIs (macOS 14+)
  depends_on arch: :arm64         # MLX + pyannote MPS

  uses_from_macos "swift" => :build

  # Python deps are resolved at install time via pip. We don't list each
  # `resource` block — pyannote/torch pull a 1GB+ wheel tree, and pinning
  # transitively in a Formula is brittle. Instead we let pip handle it.
  # Trade-off: install isn't fully reproducible. For v0.2 this is fine.

  def install
    # 1. Python virtualenv inside the keg
    venv = virtualenv_create(libexec/"venv", "python3.13", system_site_packages: false)
    venv.pip_install_and_link buildpath, build_isolation: false
    system libexec/"venv/bin/pip", "install", "-r", "requirements.txt"

    # 2. Source layout under libexec so the wrapper can import it
    libexec.install Dir["src", "prompts", "config.yaml.example"]

    # 3. Swift binaries — ChikkiApp (.app bundle) + chikki-syscap CLI
    cd "menubar" do
      system "swift", "build", "-c", "release", "--product", "ChikkiApp"
      system "swift", "build", "-c", "release", "--product", "chikki-syscap"

      # Bundle the menubar app properly so users can open it from Finder
      app_dir = libexec/"Chikki.app/Contents"
      (app_dir/"MacOS").mkpath
      cp ".build/release/ChikkiApp", app_dir/"MacOS/Chikki"
      cp "Sources/Info.plist", app_dir/"Info.plist"

      # System-audio helper into PATH so the Python recorder can locate it
      bin.install ".build/release/chikki-syscap"
    end

    # 4. CLI wrapper that activates the venv and exec's the Python entry point
    (bin/"chikki").write <<~SCRIPT
      #!/bin/bash
      export CHIKKI_HOME="#{libexec}"
      export PYTHONPATH="#{libexec}:$PYTHONPATH"
      exec "#{libexec}/venv/bin/python" -m src.cli "$@"
    SCRIPT
    chmod 0755, bin/"chikki"

    # 5. Launcher for the .app
    (bin/"chikki-app").write <<~SCRIPT
      #!/bin/bash
      exec open "#{libexec}/Chikki.app" "$@"
    SCRIPT
    chmod 0755, bin/"chikki-app"
  end

  def caveats
    <<~EOS
      Chikki is installed.

      First-run setup:

        1. Create a config dir and copy the example:
             mkdir -p ~/.config/chikki
             cp #{libexec}/config.yaml.example ~/.config/chikki/config.yaml

        2. Add API keys to ~/.config/chikki/.env (Gemini is the default provider):
             GOOGLE_API_KEY=...
             # Optional for diarization:
             HF_TOKEN=...

        3. Accept the pyannote EULA (one-time, only if you want diarization):
             https://huggingface.co/pyannote/speaker-diarization-3.1
             https://huggingface.co/pyannote/embedding

        4. Launch the menubar app:
             chikki-app

        5. Or use the CLI:
             chikki quick           # record → transcribe → notes
             chikki --help

      To allow Screen Recording (system audio) and Microphone access,
      open the app once and approve when macOS prompts. Calendar access
      is requested when you enable auto-record in Settings.

      Notes are written to ~/Documents/Chikki/ by default — adjust paths
      in Settings if you prefer something else.

      Models (~3–4 GB across Whisper + pyannote) download on first use.
    EOS
  end

  test do
    # Smoke test: the CLI loads and lists meeting types
    assert_match "default", shell_output("#{bin}/chikki types")
    # Swift helper exists
    assert_predicate bin/"chikki-syscap", :exist?
  end
end
