# create_hydrogen: scaffolding a Hydrogen game (for coding agents)

`create_hydrogen` creates a new Roblox game project that uses Hydrogen. Run it non-interactively with `--yes` and flags. Without `--yes` it asks questions on a terminal, and with no terminal it exits with code 1 before writing anything.

## Command

```bash
pesde x atk422/create_hydrogen -- <directory> --yes [flags]
```

- Requires pesde 0.7+. `pesde x` downloads the package and the Lune runtime it needs.
- Everything after `--` goes to the generator. Without `--`, pesde reads the flags itself and fails.
- `<directory>` is created if missing. `.` means the current directory. It must be empty unless you pass `--force`.
- From a Hydrogen checkout instead: `lune run tools/create-hydrogen/src/main.luau -- <directory> --yes [flags]`.

## Flags and `--yes` defaults

| Flag | Value | `--yes` default |
| --- | --- | --- |
| `<directory>` | path | the project name |
| `--name <name>` | letters, digits, `-`, `_`, `.`; starts with a letter or digit; at most 64 characters; not a Windows reserved name (`con`, `nul`, `com1`...) | the directory's last part, else `my-game` |
| `--package <scope/name>` | pesde rules: `a-z`, `0-9`, `_`; scope 3-32 characters, name 1-32; not all digits; no leading or trailing `_` | `<author slug>/<name slug>`, scope `game` if the author slug is under 3 characters |
| `--description <text>` | one line | `A Roblox game built with Hydrogen` |
| `--author <name>` | any | `git config user.name`, else empty (then no `authors` in pesde.toml) |
| `--license <id>` | `MIT`, `Apache-2.0`, `MPL-2.0`, `None` | `MIT` |
| `--examples` / `--no-examples` | | on: example systems, network module and tests. Off: empty `Game.luau` and `Interface.luau` systems, no network module |
| `--tools <list>` | comma-separated `stylua`, `selene`, `luau-lsp`, or `none` | all three |
| `--ci` / `--no-ci` | | on: `.github/workflows/ci.yml` |
| `--agents` / `--no-agents` | | on: `AGENTS.md` and `CLAUDE.md` |
| `--no-git` | | git runs |
| `--no-install` | | installs run |
| `-f`, `--force` | | off. With it, files with template names are overwritten and other files are left alone |
| `-y`, `--yes` | | |
| `-h`, `--help` / `-v`, `--version` | | print and exit 0 |

Flag values may also be written `--flag=value`. An invalid value is an error. Nothing falls back to a default without saying so.

Fully explicit example:

```bash
pesde x atk422/create_hydrogen -- my-game --yes --name my-game --package studio/my_game --description "Tower defense" --author "Studio" --license None --examples --tools stylua,selene,luau-lsp --ci --agents
```

## What it does, in order

1. Validates everything and checks the directory. On any problem it exits with 1 before writing.
2. Writes the files.
3. Git, unless `--no-git`: `git init --initial-branch=<branch>`, where the branch is the global `init.defaultBranch` or else `main`. The CI workflow triggers on that branch. Skipped, as a note and not a failure, when the directory is already inside a git repository.
4. Installs, unless `--no-install`: `rokit install`, then `pesde install`, then `rojo sourcemap default.project.json --output sourcemap.json`.
5. `git add -A`, then a commit with the message `Create project with create_hydrogen`.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Done. Steps turned off with `--no-git` / `--no-install`, and skipping git inside an existing repository, still count as done. |
| 1 | Stopped before writing: invalid value, directory not empty (pass `--force`), target is a file, or prompts needed with no terminal (pass `--yes`). The message is on stderr after `error:`. |
| 2 | Bad command line: unknown flag, unknown `--tools` value, a flag missing its value, two directories. |
| 3 | The project was written, but a step that should have run didn't. Each one is listed under `Not done:` on stdout with what to run instead. |

## When tools are missing or fail (exit code 3)

The project is always written first. Then, for each step:

| Situation | Reported | What to do |
| --- | --- | --- |
| git not installed | `git: not found` | install git, then `git init` and commit, or pass `--no-git` |
| Rokit not installed | `Rokit isn't installed` (with install commands for Windows and macOS/Linux) | install Rokit, then `rokit install` in the project |
| Rokit tools not trusted (only with `--yes`, since nothing can answer Rokit's question) | `some tools aren't trusted yet` with the exact `rokit trust ...` command | that is a change to the user's Rokit settings: ask the user before running `rokit trust`, then `rokit install` |
| pesde not installed | `pesde isn't installed` | install pesde, then `pesde install` |
| `rokit install` / `pesde install` failed | the tool's error | fix it and rerun the command in the project |
| commit failed (usually no git identity) | the git error and the `git config --global user.name/user.email` commands | set the identity (ask the user), then `git commit -m "First commit"` |

The generator never changes Rokit's trust list or git's config by itself.

## After it finishes

In the project directory:

```bash
rojo build default.project.json --output build.rbxl
```

```bash
pesde run test
```

Both should succeed on a fresh project with examples (three example tests pass). Then read the project's `AGENTS.md` (if generated) for its layout, commands and conventions, and Hydrogen's docs under `roblox_packages/.pesde/atk422+hydrogen/*/hydrogen/` before writing Hydrogen code.
