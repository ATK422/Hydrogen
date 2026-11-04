# hydrogen-lint

> A command (`pesde x atk422/hydrogen_lint`) that boots a Hydrogen game's server and client under Lune, compares what each side registered on the network, and reports one-sided names, duplicates, late registrations, schema and `:Encode()` mismatches and other network bugs before you playtest. Text for people, `--json` for CI and agents.

## Use it when / Don't use it when

Use it when:
- Before a playtest, or in CI, after changing network definitions, `app:addNetwork` calls, `Hydrogen.State` definitions or where modules live.
- You see `[HYDROGEN] NETWORK MISMATCH`, `Network event X not found`, `Network already initialized ignoring X registration` or messages reaching the wrong object, and want to know which name and which module.
- An agent changed network code: run with `--json` and fix every `error` diagnostic.

Don't use it when:
- Testing game logic: use `Hydrogen.test` (`docs/ai/testing.md`). The lint only boots the game; it never plays it.
- Checking types or style: use luau-lsp, selene, StyLua.
- The game isn't a Rojo project with a `DataModel` root: the lint builds the game from the Rojo sourcemap.

## Quick start

From the game's folder (the one with `default.project.json`):

```bash
pesde x atk422/hydrogen_lint
```

```
error[one-sided] on the server: ServerEvent "Kick" is registered on the server only
  --> src/server/Admin.luau:7 (ServerScriptService.Server.Admin)
  fix: Ids come from the sorted names, so every name after it reaches the wrong object. It's defined in ServerScriptService.Server.Admin, which clients can't see. Move it to a shared module (such as ReplicatedStorage.Shared.Network) and pass that folder to app:addNetwork on both sides.

error[one-sided] on the server: ClientEvent "Trade" is registered on the server only
  --> src/shared/Trading.luau:6 (ReplicatedStorage.Shared.Trading)
  fix: Ids come from the sorted names, so every name after it reaches the wrong object. The client never required ReplicatedStorage.Shared.Trading. Pass its folder to app:addNetwork in the client's entry script too, before app:start(). addNetwork on the server: ReplicatedStorage.Shared.Network, ReplicatedStorage.Shared.Trading; on the client: ReplicatedStorage.Shared.Network.

server: 1 script, 3 names, network started
client: 1 script, 1 name, network started
2 errors, 0 warnings
```

CI step (exit code 1 fails the job):

```yaml
- name: Network lint
  run: pesde x atk422/hydrogen_lint -- --strict
```

## API

Command: `pesde x atk422/hydrogen_lint -- [directory] [flags]` (pesde passes everything after `--`).

- `directory`: the game's folder. Default: the current directory.
- `--project <file>`: Rojo project file, relative to the directory. Default `default.project.json`.
- `--sourcemap <file>`: use this sourcemap instead of running `rojo sourcemap <project>`. Without it the lint runs Rojo; if Rojo isn't on the PATH it falls back to `sourcemap.json` (and says so in the report's `sourcemap` field).
- `--json`: print the report as JSON on stdout (format below). Nothing else is printed on stdout.
- `--strict`: exit 1 on warnings too.
- `--ignore <rule>[,<rule>...]`: leave rules out of the report and the counts. Repeatable. Unknown rule names exit 2.
- `--wait <seconds>`: after the scripts start and finish loading, let deferred code (`task.defer`, `task.delay`) run this long. Default `0.1`.
- `--verbose`: also print the game's own `print`/`warn` output and the Instances the lint stood in for.
- `--no-color`: plain text. `NO_COLOR` in the environment does the same.
- `--hydrogen <folder>`: the Hydrogen package to take the lint engine from. Default: the one `roblox_packages/<alias>.luau` links to.
- `--help`: usage and the rule list.

Exit codes: `0` no errors (warnings allowed), `1` at least one error (or a warning with `--strict`), `2` the lint couldn't run (bad flag, no project, no sourcemap, no Hydrogen installed).

Programmatic (Lune only; the engine ships in Hydrogen at `src/Testing/Lint/`):
- `Lint.run(options: { root: string, project: string?, sourcemap: (string | table)?, wait: number?, ignore: { string }? }): Report` (yields; errors with a `[HYDROGEN]` message when it can't run).
- `Report.text(report, { color: boolean?, verbose: boolean? }): string`, `Report.json(report): string`.
- `Cli.main(args: { string }, output: { write, ewrite }?): number` returns the exit code.
- `Lint.rules`: `{ { name, severity, summary } }`. `Lint.FORMAT`: the JSON format version (1).

JSON report (`format` 1; keys sorted; optional fields are absent, not `null`):

```json
{
  "format": 1,
  "ok": false,
  "errors": 2,
  "warnings": 0,
  "sourcemap": "rojo sourcemap default.project.json",
  "diagnostics": [
    {
      "rule": "one-sided",
      "severity": "error",
      "name": "Kick",
      "sides": ["server"],
      "message": "ServerEvent \"Kick\" is registered on the server only",
      "fix": "...",
      "locations": [
        { "side": "server", "file": "src/server/Admin.luau", "line": 7, "instance": "ServerScriptService.Server.Admin" }
      ]
    },
    { "rule": "one-sided", "...": "the Trade diagnostic" }
  ],
  "server": {
    "started": true,
    "names": ["Chat", "Kick", "Trade"],
    "hash": "3:24680247",
    "addNetwork": ["ReplicatedStorage.Shared.Network", "ReplicatedStorage.Shared.Trading"],
    "scripts": [{ "instance": "ServerScriptService.Server.Main", "file": "src/server/Main.server.luau", "status": "finished" }],
    "missing": [],
    "output": []
  },
  "client": { "...": "same shape" }
}
```

- `name` (network name), `fix` and `instance` may be absent. `locations` may be empty. `file` is relative to the project directory (`../` for files outside it, such as Hydrogen itself in a monorepo).
- `script.status`: `finished`, `errored`, or `running` (still waiting, e.g. on a function call no server answers).
- `hash` is Hydrogen's fingerprint of the names it assigned ids to; equal hashes mean the ready handshake would match.
- If the lint can't run, `--json` prints `{"format": 1, "ok": false, "fatal": "<message>"}` and exits 2.

Rules (`severity`):

| rule | severity | what it means |
| --- | --- | --- |
| `script-error` | error (warning after the network started) | a Script or LocalScript errored while booting |
| `multiple-runtimes` | error | one side loaded two copies of Hydrogen |
| `addnetwork-hang` | error | `app:addNetwork` would never return on a module (it returns a State object or a bare GreenTea schema). Only a pre-release Hydrogen build could do this; every released version with the lint (0.5.0 and later) counts these without looping, so the rule stays quiet. |
| `one-sided` | error | a name is registered on one side only |
| `duplicate` | error | a name is registered twice on one side, including `Hydrogen.namespace` prefixes and `State/<name>` |
| `late-registration` | error | a network object is created after `app:start()` started the network |
| `kind-mismatch` | error | a name is, say, a `ServerEvent` on the server but a `ClientEvent` on the client |
| `encode-mismatch` | error | `:Encode()` is called on one side only |
| `schema-mismatch` | error | the sides' schemas (`gt` types) for a name format differently |
| `missing-returns` | error | `Hydrogen.serverFunction(name, args...)` was never called with its returns, so it is never registered |
| `function-schema` | error / warning | `clientFunction` without returns, or with extra schemas (error); bare schemas instead of `gt.args`/`gt.returns` (warning) |
| `stalled` | warning | a script never finished and that side's network never started |
| `not-started` | warning | names were registered but no `app:start()` ran on that side |
| `no-scripts` | warning | no scripts found on one side |
| `no-handler` | warning | nothing on the receiving side listens (`:On`) to an event or answers a function after boot |
| `similar-names` | warning | two names differ only by case |
| `reserved-prefix` | warning | a game name starts with `State/` or `Hydrogen/` |
| `runtime-warning` | warning | Hydrogen printed a `[HYDROGEN]` warning while booting |

## Rules

- The lint runs the game for real: the server world runs Scripts in ServerScriptService and Workspace; the client world copies StarterPlayerScripts, StarterGui, StarterPack and StarterCharacterScripts into a fake `Players.LocalPlayer` (as Roblox does) and runs ReplicatedFirst, then those copies. Code at require time and in `init`/`start` hooks runs. `playerAdded` never runs (no players join), and no frames run (Heartbeat never fires).
- Each side is its own world: its own Instance tree from the sourcemap, globals, `_G`, module cache and `RunService:IsServer()`/`IsClient()` answers. Side-specific code takes the branch it would take in Roblox.
- Network functions called during boot (`ClientFunction:Fire()` in a client `start`) wait forever, as if the other side never answered. The code after them in that hook doesn't run; anything it would register isn't checked.
- Engine APIs the lint doesn't emulate return permissive stand-ins (callable, indexable, connectable; `Wait()` returns at once). `WaitForChild` of something the Rojo project doesn't have returns a stand-in instead of waiting. `require` of a stand-in errors (`script-error`): the lint can't load modules that only exist in the place file.
- Game `print`/`warn` output never reaches stdout; it is in `server.output` / `client.output` and in `--verbose`.
- Only what the boot reaches is checked. A network module first required from a `playerAdded` hook, a UI button or a `task.delay` longer than `--wait` isn't seen: keep definitions in modules both sides require before `app:start()`.
- `no-handler` is a warning because handlers connected later (when a UI opens) are legitimate; events that arrive earlier are dropped.
- The engine ships inside Hydrogen and reads its network runtime's registries, so the lint always matches the Hydrogen version the game installed. Hydrogen 0.4.0 and older have no engine: the launcher exits 2 asking you to update.
- Infinite loops without yields at require time hang the lint, as they would hang Roblox.

## Recipes

Lint a game in a subfolder, as JSON:

```bash
pesde x atk422/hydrogen_lint -- games/obby --json
```

Fail CI on warnings, but allow events without listeners:

```bash
pesde x atk422/hydrogen_lint -- --strict --ignore no-handler
```

Use an existing sourcemap (no Rojo on the machine):

```bash
rojo sourcemap default.project.json --output sourcemap.json
pesde x atk422/hydrogen_lint -- --sourcemap sourcemap.json
```

Pin the lint as a script instead of `pesde x`, in the game's `pesde.toml`:

```toml
[dev_dependencies]
hydrogen_lint = { name = "atk422/hydrogen_lint", version = "^0.1.0", target = "lune" }

[scripts]
lint = "lune_packages/hydrogen_lint.bin.luau"
```

Then `pesde run lint`.

An agent's fix loop: run `pesde x atk422/hydrogen_lint -- --json`, then for each diagnostic with `severity == "error"` open `locations[1].file` at `locations[1].line`, apply `fix`, and rerun until `ok` is `true`.

## Mistakes

- Don't define network objects in ServerScriptService or StarterPlayer modules; define them in `ReplicatedStorage` modules and `app:addNetwork` them on both sides (`one-sided`).
- Don't call `:Encode()` or pick schemas behind `RunService:IsServer()`; the shared definition must be identical on both sides (`encode-mismatch`, `schema-mismatch`).
- Don't require a network module for the first time from a `start` hook or after `app:start()`; require it before (usually via `app:addNetwork`) (`late-registration`).
- Don't write `Hydrogen.serverFunction("Ask", gt.string())` and stop; it is curried: `Hydrogen.serverFunction("Ask", gt.string())(gt.number())` (`missing-returns`).
- Don't pass bare schemas to `clientFunction`; use `Hydrogen.clientFunction("Get", gt.args(gt.string()), gt.returns(gt.number()))` (`function-schema`).
- Don't vendor a pre-release Hydrogen build: if `addnetwork-hang` fires, the copy's `app:addNetwork` loops forever on State objects and schemas. Update to a released version.
- Don't name your own objects `State/...`; `Hydrogen.State` registers `State/<name>` for each state (`duplicate`, `reserved-prefix`).
- Don't silence a `script-error` with `--ignore` without reading it: names registered after the error weren't checked.

## Testing

- Hydrogen tests the lint against fixture games in `test/Fixtures/Lint/<name>/` (each a Rojo project with a committed `sourcemap.json` and `packages/hydrogen.luau` standing in for pesde's link file): `clean`, `one-sided`, `duplicate`, `late`, `mismatch`, `functions`, `broken`. The suite is `test/Lint.luau`; it calls `Lint.run({ root = "test/Fixtures/Lint/<name>", sourcemap = "sourcemap.json", wait = 0 })` and checks rules, names and locations.
- The launcher's own tests: `lune run test/run` from `tools/hydrogen-lint`.
- To check that a game is clean in its own CI, run the lint with `--strict` and assert exit code 0.

## Errors and warnings

The lint's own fatal errors (exit 2):
- `[HYDROGEN] No Rojo project at <path>. Run the lint from the game's folder, or pass --project <file>.`: wrong directory.
- ``[HYDROGEN] Couldn't run `rojo sourcemap <project>`: ... Install Rojo (rokit install), or pass --sourcemap <file>.``: Rojo isn't installed and there is no `sourcemap.json`.
- `[HYDROGEN] The Rojo project's root must be a DataModel (a game project)`: you pointed it at a library project.
- `This project's Hydrogen (<version>) has no network lint. Update Hydrogen in pesde.toml ...`: the installed Hydrogen predates the lint.
- `Couldn't find Hydrogen in <dir>/roblox_packages. Run pesde install ...`: install packages first, or pass `--hydrogen`.
- `unknown flag --x`, `--ignore: unknown rule x`, `--wait needs a number of seconds`: bad arguments.

Messages that appear inside `script-error` diagnostics:
- `[HYDROGEN] require(X): it isn't in the Rojo project, so the lint can't load it`: the module exists only in the place file, or the path is mistyped. Sync it with Rojo or fix the path.
- `[HYDROGEN] require(X): it is a Folder, not a ModuleScript`: the path names a folder.
- `[HYDROGEN] Can't find module ./x (looked for ...)`: a string require that doesn't resolve.
- `Requested module experienced an error while loading: <file>`: a module that already failed was required again (as in Roblox). Fix the first error.

## Works with

- `docs/ai/network.md`: the definitions the lint checks, and the runtime messages it predicts.
- `docs/ai/app.md`: `app:addNetwork` and the boot order (init, network start, start).
- `docs/ai/state.md`: `State/<name>` network names.
- `docs/ai/testing.md`: `Hydrogen.test` for behaviour, and `src/Testing/Lune.luau`, the Lune runtime for tests.
