# create_hydrogen

Create a new Roblox game with [Hydrogen](https://github.com/ATK422/Hydrogen) in one command:

```bash
pesde x atk422/create_hydrogen
```

It asks a few questions, then creates a project with Rojo, Rokit, pesde, tests, editor settings and (optionally) linting and CI, installs everything, and makes the first git commit.

## Before you start

You need [pesde](https://docs.pesde.dev/installation), which you need for Hydrogen anyway. `pesde x` downloads the Lune runtime the generator runs on, so nothing else is required to run it.

To install the new project's tools, the generator uses [Rokit](https://github.com/rojo-rbx/rokit) and git if you have them. If you don't, it still writes the project and tells you what to install.

## Usage

```bash
pesde x atk422/create_hydrogen                         # ask everything
pesde x atk422/create_hydrogen -- my-game              # into ./my-game
pesde x atk422/create_hydrogen -- . --yes              # current (empty) directory, all defaults
pesde x atk422/create_hydrogen -- my-game --yes --tools stylua --no-ci --license None
```

Arguments for the generator go after `--`, which tells pesde to pass them on.

### Questions

| Question | Default | Flag |
| --- | --- | --- |
| Project name | the directory's name, else `my-game` | `[directory]`, `--name` |
| Description | `A Roblox game built with Hydrogen` | `--description` |
| Author | `git config user.name` | `--author` |
| pesde package name | `<author>/<project>`, e.g. `atk/my_game` | `--package` |
| License | MIT (also Apache-2.0, MPL-2.0, None) | `--license` |
| Example systems, network module and test | yes | `--examples`, `--no-examples` |
| Lint, format and type-check tools | StyLua, Selene and luau-lsp | `--tools stylua,selene,luau-lsp` or `--tools none` |
| GitHub Actions workflow | yes | `--ci`, `--no-ci` |
| `AGENTS.md` and `CLAUDE.md` for coding agents | yes | `--agents`, `--no-agents` |

Other flags: `--no-git` (no `git init` or commit), `--no-install` (no `rokit install` or `pesde install`), `--force` (write into a directory that isn't empty; files with the same names are overwritten, others are left alone), `-y` / `--yes` (use the default for anything not given and ask nothing), `--help`, `--version`.

Project names can use letters, digits, `-`, `_` and `.`, start with a letter or digit and be up to 64 characters, so they work as folder names on Windows, macOS and Linux. Package names follow pesde's rules: `scope/name`, lowercase letters, digits and `_`.

### What it runs

1. Writes the files.
2. `git init --initial-branch=main` (or the branch in your global `init.defaultBranch`). Skipped when the directory is already inside a git repository.
3. `rokit install`, which installs the tools pinned in `rokit.toml`. Rokit asks before installing a tool you haven't trusted yet. With `--yes` there's no one to ask, so the generator reports which tools to trust (`rokit trust ...`) and doesn't change your trust list itself.
4. `pesde install`, then `rojo sourcemap` so luau-lsp works the first time you open the folder.
5. `git add -A` and the first commit, including `pesde.lock`.

A step whose tool is missing or fails is listed at the end with what to do instead. The project is still written.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Done (steps turned off with `--no-git` / `--no-install` don't count against it) |
| 1 | Stopped before writing anything: invalid value, directory not empty, or questions with no terminal |
| 2 | Bad command line |
| 3 | Project written, but a tool was missing or a git or install step failed (listed under "Not done") |

### For coding agents

[docs/ai/create.md](docs/ai/create.md) is written for agents that scaffold a project: every flag, the `--yes` defaults, the exit codes and what to do when a tool is missing. It ships in the package.

## The generated project

```
my-game/
  .github/workflows/ci.yml   build, test, format check, lint, type check (optional)
  .vscode/
    settings.json            luau-lsp with the Rojo sourcemap, StyLua format on save
    extensions.json          luau-lsp, Rojo, StyLua, Selene
  src/
    server/
      Main.server.luau       Hydrogen.App: addNetwork, addSystemsFolders, start
      Systems/
        Visits.luau          example: player hooks
        Greeter.luau         example: use(...) and a network listener
    client/
      Main.client.luau       the client app (waits for replicated folders)
      Systems/
        Greetings.luau       example: says hello, keeps the reply
    shared/
      Network/
        Greeting.luau        example: a clientEvent and a serverEvent
  test/
    run.luau                 `pesde run test`: every *.test.luau with frktest
    Roblox.luau              loads game code under Lune through the Rojo sourcemap
    Greeter.test.luau        example tests with Hydrogen.loopback() and app:replace
  AGENTS.md                  layout, commands and conventions for coding agents, and where Hydrogen's
                             AI docs are installed (CLAUDE.md just says @AGENTS.md)
  .gitattributes  .gitignore  .luaurc  .styluaignore
  default.project.json       src/server -> ServerScriptService.Server, src/client -> StarterPlayerScripts.Client,
                             src/shared -> ReplicatedStorage.Shared, roblox_packages -> ReplicatedStorage.roblox_packages
  pesde.toml                 private game package depending on atk422/hydrogen
  rokit.toml                 rojo, pesde, lune (+ stylua, selene, luau-lsp)
  selene.toml  stylua.toml
  LICENSE  README.md
```

Without examples, `Systems/` gets an empty `Game.luau` (server) and `Interface.luau` (client), and the Main scripts show where to add `addNetwork`.

`test/Roblox.luau` exists because Hydrogen 0.4 doesn't ship a way to run game code under Lune. It reads `rojo sourcemap`, so tests require game code through the DataModel (`require(ServerScriptService.Server.Systems.Greeter)`) the same way game code does. Once Hydrogen ships its own Lune runner, the template should use that instead (see [Maintaining](#maintaining)).

## Why `pesde x`

The goal is one command, on Windows, macOS and Linux, with as few prerequisites as possible for a typical Roblox developer, and easy to keep updated. The options compared:

| Option | Prerequisites | One command | Updates |
| --- | --- | --- | --- |
| **pesde binary package, `pesde x atk422/create_hydrogen`** (chosen) | pesde only. Hydrogen is a pesde package, so every Hydrogen user has it. `pesde x` downloads the Lune version the package declares. | Yes | `pesde publish`. `pesde x` runs the newest version every time, so users never update anything. |
| `bun create` / `npm create hydrogen` | Bun or Node.js, which many Roblox developers don't have and Hydrogen doesn't otherwise need | Yes | `npm publish` |
| Rokit-installable CLI | Rokit, plus a compiled binary per platform in GitHub releases | No: `rokit add`, then run it, then update it by hand | A release with three or more binaries each time |
| Lune script run from a clone or URL | Lune, plus cloning the repo (Lune can't run a script from a URL) | No | Users pull the repo |
| Shell one-liner (`curl ... \| sh`, `irm ... \| iex`) | None, but two scripts (sh and PowerShell) to write and keep in sync | Yes | Host the scripts |

`pesde x` is the only option that adds no new tool, works the same on every OS and updates itself. It also keeps the generator in Luau, the language the template is written in, and lets it live in this repository next to the code the template depends on. There's precedent: Nova's scaffolder runs as `pesde x nova/create`.

It lives in this repository (`tools/create-hydrogen/`) rather than a separate one so a change to Hydrogen's API and the template that uses it can land in one commit, and so the generator's tests can run next to Hydrogen's. It's a separate pesde package (its own `pesde.toml`), and Hydrogen's `includes` don't reach it, so neither package ships the other.

## Maintaining

```
tools/create-hydrogen/
  pesde.toml          the atk422/create_hydrogen package (Lune target, bin = src/main.luau)
  src/
    main.luau         entry point: flags, output, exit codes
    cli.luau          flag parsing and --help
    options.luau      choices, defaults, and the list of optional kit modules
    wizard.luau       answers (flags, prompts, defaults), then write, git, install, commit
    scaffold.luau     picks template overlays, renders and writes them
    render.luau       the template language
    names.luau        project and package name rules
    prompts.luau      terminal prompts, and scripted ones for tests
    tools.luau        running git, rokit, pesde and rojo; install instructions
    versions.luau     every pinned version in one place
  template/
    base/             always copied
    examples/         --examples
    starter/          --no-examples
    ci/  agents/  stylua/  selene/   one folder per option
    licenses/         LICENSE texts; MIT.tmpl gets the year and author
  docs/ai/create.md   how coding agents should run the generator
  test/run.luau       the generator's tests
```

### Run it from a checkout

```bash
lune run src/main.luau -- my-game
```

(from `tools/create-hydrogen/`, with Lune 0.10 on your PATH; `pesde run` works too).

### Test

```bash
lune run test/run
```

```bash
lune run test/run e2e
```

The first runs the unit tests: names, flags, the template language, every combination of options rendering valid JSON and TOML, and the wizard against a fake toolchain (missing tools, a non-empty directory, failed installs, untrusted Rokit tools, a nested repository, a failed commit). The second also generates a real project in a temporary directory, runs `rokit install` and `pesde install`, then `rojo build`, `pesde run test`, `stylua --check` and `selene`, and checks the commit. It needs git, Rokit and pesde, the tools trusted in Rokit, and network access.

### Templates

- Files ending in `.tmpl` are rendered; everything else is copied byte for byte. Rendering supports `{{variable}}`, `{{#if flag}} ... {{/if}}` and `{{#unless flag}} ... {{/unless}}`. A block tag alone on its line removes the line. Unknown variables and unclosed blocks are errors, and the tests render every combination, so a typo fails the tests instead of shipping.
- Dotfiles are named `dot-x` in the template (`dot-gitignore`, `dot-vscode/`) so no packaging step skips them.
- The variables come from `Scaffold.vars` in `src/scaffold.luau`: `name`, `package`, `description`, `author`, `license`, `year`, `branch`, `hydrogen_version`, `<tool>_tool` and `<tool>_version` for each Rokit tool, and a flag per option (`examples`, `ci`, `agents`, `stylua`, `selene`, `luau_lsp`, `lint`, `has_author`, `has_license`, `kit_<id>`).
- Template code may only use Hydrogen's released API. After changing it, run `lune run test/run e2e`.
- `template/agents/AGENTS.md.tmpl` lists the generated project's commands and conventions, and `docs/ai/create.md` lists the generator's flags and exit codes. Update them with the template and the flags. A test fails if a flag in `--help` is missing from `docs/ai/create.md`.

### Bumping versions

Change `src/versions.luau`: Hydrogen's requirement, the Rokit tool pins, pesde's engines and dev dependencies, and the GitHub Actions. Keep the Lune pin and the Lune engine on the same version. Then run the end-to-end test, which installs exactly those versions.

### Offering a kit module

When a module such as `Hydrogen.Data` ships in a Hydrogen release, add it to `Options.kit` in `src/options.luau`:

```luau
{
	id = "data",
	label = "Hydrogen.Data: saved player data with session locking",
	hydrogen = "^0.5.0",
	overlays = { "kit/data" },
},
```

The wizard then asks "Which Hydrogen modules do you want?", accepts `--kit data`, copies `template/kit/data/` over the project, and templates can test `{{#if kit_data}}`. Raise `versions.hydrogen` to the release that has the module (the `hydrogen` field records which release that is).

### Publishing

From `tools/create-hydrogen/`: bump `version` in `pesde.toml` and `cli` in `src/versions.luau`, run both test commands, then:

```bash
pesde publish --dry-run
```

```bash
pesde publish
```
