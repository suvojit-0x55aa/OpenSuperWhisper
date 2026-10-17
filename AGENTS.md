# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- The normal local/CI build entry point is `./run.sh build`; initialize the two git submodules first and provide CMake, Rust/Cargo, and Homebrew `libomp` as documented in `Readme.md` and `.github/workflows/build.yml`.
- macOS privacy state and prompts are owned by `OpenSuperWhisper/PermissionsManager.swift`. Trigger permission boundaries and fallback behavior are resolved in `OpenSuperWhisper/ShortcutManager.swift`; keep Accessibility, Input Monitoring, and Microphone independent.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
