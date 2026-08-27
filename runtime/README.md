# Integrated Computer Use runtime

This directory is the canonical source and distribution boundary for the native runtime shipped by `dsh-desktop-operator`.

## Layout

- `windows/`: Windows Go MCP entry point, tests, embedded PowerShell UI Automation bridge, and desktop smoke scripts.
- `bin/`: generated Windows artifacts and `runtime-manifest.json`; created by `pnpm build:runtime` and intentionally not committed.
- `LICENSE.open-computer-use`: original upstream MIT license.
- `THIRD_PARTY_NOTICES.open-computer-use.md`: upstream third-party notices retained with the vendored source.
- `upstream.json`: source repository, base revision, and the local-patch state imported into this canonical copy.

The plugin starts `runtime/bin/win32-x64/open-computer-use.exe` or `runtime/bin/win32-arm64/open-computer-use.exe` directly. Consumers do not need Go and do not install a second runtime package. `runtimeExecutable` remains an explicit development override only.

## Maintainer commands

Requirements: PowerShell, Node.js, pnpm, and Go 1.22 or newer.

```powershell
pnpm build:runtime
pnpm package:plugin
```

`build:runtime` runs the vendored Go tests and `go vet`, cross-compiles both Windows architectures, and writes SHA-256 metadata. `package:plugin` then runs plugin tests, creates the single `.tgz`, and fails if either binary, the source, smoke fixtures, or licensing files are missing from the archive.

## Upstream sync policy

`runtime/windows/` is now the maintained product source. The separate upstream checkout is only a temporary comparison and synchronization workspace. When importing a later upstream change:

1. review the upstream diff and license changes;
2. port only the required runtime changes into this directory;
3. update `upstream.json` to the reviewed commit;
4. run `pnpm package:plugin` plus the window, action/postcondition, modal, and capture smoke scripts;
5. record behavior changes in `ROADMAP.md`.

Do not make the installed plugin depend on an adjacent checkout or an absolute local path.
