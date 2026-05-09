# Porto

A tiny native macOS menu bar app that lists every TCP port being listened on locally — Python dev servers (Streamlit, Shiny, FastAPI, Jupyter…), Node, Docker containers, system services — and lets you stop them with one click.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![swift](https://img.shields.io/badge/swift-6-orange) ![size](https://img.shields.io/badge/binary-~360KB-brightgreen)

## Features

- Lives in the menu bar (custom monochrome glyph), zero dock icon
- Auto-refreshes every 3 seconds
- Categorized: Python / Node / Docker / Other / System
- Click a row → opens `http://localhost:PORT` in your browser
- ✕ button → SIGTERM, then SIGKILL after 1.2s (or `docker stop` for containers)
- **Sudo escalation when needed**: if a process resists, Porto asks for confirmation, then triggers macOS's native auth prompt (Touch ID or password)
- **launchd-respawn detection**: when killing services managed by Homebrew or LaunchAgents (e.g. `ollama`, `postgres`), Porto identifies the launchd entry and offers a one-click "Stop Permanently"
- Newly-detected services pop to the top within each category
- Optional: register Porto as a Login Item so it starts at boot (offered on first launch)

## Install

1. Download `Porto.zip` from the latest [release](../../releases).
2. Unzip → drag `Porto.app` to `/Applications`.
3. **First launch (Gatekeeper)**: Porto is ad-hoc signed (not notarized), so macOS won't open it directly. Either:
   - **Right-click → Open**, then click "Open" in the dialog, *or*
   - Run once: `xattr -dr com.apple.quarantine /Applications/Porto.app`

## Build from source

Requires macOS 13+, Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/<you>/porto.git
cd porto
./build.sh
open build/Porto.app
```

The build script produces `build/Porto.app` and `build/Porto.zip`.

## How it works

- **Process discovery**: `lsof -nP -iTCP -sTCP:LISTEN -F pcn` — parses listening sockets owned by the current user.
- **Docker discovery**: `docker ps --format '{{json .}}'` — picks up host port mappings (including ranges).
- **Kill**: `kill -TERM <pid>` → wait 1.2s → `kill -KILL <pid>` → verify with `kill -0 <pid>`.
- **Privileged kill**: if the process resists and the PID still belongs to the expected command, an `osascript ... with administrator privileges` call presents the system auth prompt.
- **launchd identification**: `launchctl list` is matched by PID first, then by label. Homebrew services (`homebrew.mxcl.<name>`) are stopped via `brew services stop <name>`; user LaunchAgents via `launchctl bootout gui/<uid>/<label>`.

No entitlements required, no sandbox, no network access.

## Limitations

- Only sees processes owned by the current user (lsof without root).
- System-domain LaunchDaemons are detected on a best-effort basis only.
- Ad-hoc signed: the macOS Login Items registry tracks each build by its code signature, so if you rebuild Porto from source you may need to re-register it.
- Not notarized — for wider distribution, sign with a Developer ID and run `xcrun notarytool submit … --wait`.

## Project layout

```
Porto/
├── README.md
├── LICENSE
├── .gitignore
├── build.sh                    ← one-shot rebuild + zip
├── Resources/
│   ├── AppIcon.icns
│   ├── MenuBarIcon.png
│   └── MenuBarIcon@2x.png
└── Sources/
    ├── App.swift               ← @main + MenuBarExtra
    ├── AppDelegate.swift       ← welcome alert, login-item registration
    ├── Models.swift            ← Service, ServiceCategory, classifier
    ├── Shell.swift             ← Process API helpers
    ├── PortScanner.swift       ← lsof parser
    ├── DockerScanner.swift     ← docker ps parser
    ├── LaunchctlScanner.swift  ← launchd identification + stop
    ├── ServiceMonitor.swift    ← refresh loop + kill orchestration
    └── MenuView.swift          ← SwiftUI dropdown
```

## License

MIT.
