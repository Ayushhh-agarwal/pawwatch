# Contributing

Thanks for improving PawWatch.

## Build

```bash
./build.sh
open build/PawWatch.app
```

## Add an Agent Detector

Agent detection lives in `AgentPets.swift` in the `kinds` list.

Add:

- `name`: display name
- `color`: fallback pet color
- `executables`: process executable names
- `hints`: lowercase command substrings for packaged apps or CLIs

Then run:

```bash
./build.sh
build/PawWatch.app/Contents/MacOS/PawWatch --list
```

## Icons

Do not commit third-party product logos. Local image overrides are ignored by git. Put personal overrides in `assets/`, for example:

```text
assets/Claude Code.png
assets/Codex.png
```
