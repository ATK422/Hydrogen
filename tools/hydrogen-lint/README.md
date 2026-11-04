# hydrogen_lint

Checks a [Hydrogen](../../README.md) game's network before you playtest. From the game's folder:

```bash
pesde x atk422/hydrogen_lint
```

It boots the game's server and client under Lune, compares what Hydrogen's network registered on each side, and reports one-sided names, duplicates, late registrations, `:Encode()` and schema mismatches and other network bugs, each with the file, line and a fix. Exit code 0 means no errors.

```bash
pesde x atk422/hydrogen_lint -- --help                 # flags and rules
pesde x atk422/hydrogen_lint -- games/obby --json      # another folder, JSON for CI and agents
pesde x atk422/hydrogen_lint -- --strict               # fail on warnings too
```

The user guide is the README section [Checking the network before you playtest](../../README.md#checking-the-network-before-you-playtest). Agents: [docs/ai/lint.md](../../docs/ai/lint.md) has every flag, rule, exit code and the JSON format.

## How it's split

This package is only a launcher. The lint engine ships inside Hydrogen, in `src/Testing/Lint/`, because it reads the network runtime's internal registries and has to match the Hydrogen version the game runs. The launcher:

1. finds the project's Hydrogen through the link file pesde writes (`roblox_packages/<alias>.luau`, which requires `./.pesde/atk422+hydrogen/<version>/hydrogen/src`), or takes `--hydrogen <folder>`;
2. loads `src/Testing/Lint/Cli.luau` from there with a small loader (Lune's `require` only takes paths relative to the calling script);
3. exits with `Cli.main(process.args)`.

A Hydrogen without the engine (0.4.0 and older) gets a message asking to update it, with exit code 2.

## Adding it to generated projects

The setup wizard in `tools/create-hydrogen` could offer the lint (on by default). It would add:

- to `pesde.toml`, a pinned launcher and a script, so `pesde run lint` works offline:

  ```toml
  [dev_dependencies]
  hydrogen_lint = { name = "atk422/hydrogen_lint", version = "^0.1.0", target = "lune" }

  [scripts]
  lint = "lune_packages/hydrogen_lint.bin.luau"
  ```

- to the CI workflow template, after "Install packages":

  ```yaml
  - name: Network lint
    run: pesde run lint -- --strict
  ```

- to the generated `AGENTS.md`, a line telling agents to run `pesde run lint -- --json` after changing network code and to fix every `error`.

The example game the wizard writes already lints clean. On Hydrogen 0.4.0 and older, State definitions must stay out of `addNetwork` modules, because that version's object count loops on them (the `addnetwork-hang` rule); later versions don't.

## Developing

```bash
lune run test/run
```

runs the launcher's tests (lookup through link files, the update message, `--hydrogen`, and a real run of the engine on a fixture game). The engine's tests are in Hydrogen's suite (`pesde run test` at the repository root, `test/Lint.luau`). To run the launcher against the repository's fixtures:

```bash
lune run tools/hydrogen-lint/src/main -- test/Fixtures/Lint/one-sided --hydrogen .
```

Publish with `pesde publish` from this folder, after the Hydrogen release that ships the engine.
