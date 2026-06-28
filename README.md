# PawWatch

Native macOS overlay that scans local processes every 10 seconds and shows one small pet per detected coding agent, labeled with its repo/worktree, git branch, runtime, and working state.

Detected by default: Claude Code, Codex, Gemini, Aider, OpenCode, Goose, Cursor Agent, Copilot, and ChatGPT CLIs.

## Requirements

- macOS
- Xcode Command Line Tools or Swift toolchain

## Build

```bash
./build.sh
open build/PawWatch.app
```

`build.sh` creates an ad-hoc signed app. It is not Apple-notarized yet, so macOS may block the first launch. If that happens, right-click `PawWatch.app`, choose `Open`, then confirm `Open`.

For a GitHub release asset:

```bash
./build.sh
ditto -c -k --sequesterRsrc --keepParent build/PawWatch.app PawWatch-macOS.zip
```

## Usage

Click a pet to see only that agent's actions, Claude Code session title when available, copy its repo path, or copy its process command.
Click the menu-bar pet icon for the global running-flow list and `Recent Codex Chats` submenu.
Double-click a pet to jump to its terminal/app. Terminal.app tabs are selected by TTY; JetBrains IDEs focus the Terminal tool window; other apps are focused.
Click the `x` on a pet to terminate only that agent process after confirmation.
Drag the pet stack anywhere on screen; PawWatch remembers the position. Use `Reset Position` from the menu to snap it back.
Use the `-` button to collapse into a compact summary pill, and `+` to expand again.
Use `Hide Pets` from the menu-bar icon to hide the floating overlay while keeping the menu available.

To change an agent image, put a square image in `assets` with the agent name, for example `assets/Claude Code.png`, `assets/Claude.png`, or `assets/Codex.png`, then restart PawWatch. Missing images fall back to the drawn pet.

Install at login:

```bash
./install.sh
```

Stop the login agent:

```bash
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/io.github.ayushhhagarwal.pawwatch.plist"
```

State is inferred locally:

- `working`: the agent has a live child tool process, or CPU is active.
- `waiting for permission`: the agent process has light CPU activity but no live tool child.
- `idle`: the agent exists but is quiet.

Metadata shown locally:

- process: name, pid, runtime, command, owner app, owner pid, terminal tty.
- workspace: cwd, repo/worktree folder, git branch or detached commit.
- Claude Code: latest local session title/slug for that cwd when present.

Privacy: PawWatch does not call network APIs. It reads local process metadata, git metadata, and local agent state files where available.

Trademark note: product names belong to their owners. The repository does not bundle third-party product logos; add local image overrides if you want branded icons on your machine.

## Implementation Notes

- Scans run on AppKit's main thread. The per-process metadata cache is main-thread only.
- New agent processes may trigger local `lsof`, `git`, and agent-state reads once; metadata is cached by pid after that.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
