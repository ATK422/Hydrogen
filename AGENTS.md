# Hydrogen: notes for coding agents

Hydrogen is a Luau framework for Roblox, published on pesde as `atk422/hydrogen`.

## Goals

Every change is judged against three goals, in this order of tie-breaking:

1. **Developer experience.** Very little boilerplate, a typed API that autocompletes, clear `[HYDROGEN]` errors that say how to fix the problem. Users should never have to fight the library.
2. **Reliability.** Think through yields, errors in user callbacks, players leaving mid-operation and server shutdown, and test them.
3. **Performance.** No per-frame work when idle, no per-access metatable cost on hot paths, and opt-in features cost nothing when unused.

The vision: Hydrogen should feel like Kotlin's standard library. Everything a Roblox game needs is already there, and it fits together.

## If you are writing a game with Hydrogen

Read [`llms.txt`](llms.txt) and the files it links in `docs/ai/`. Start with `systems.md` and `app.md`.

## If you are working on Hydrogen itself

- The contributor guide is README "Part 2: Working on Hydrogen itself": toolchain, layout, conventions and releasing.
- Install with `pesde install`, then run the tests with `pesde run test`. The full suite must pass.
- Strict mode everywhere. Match the indentation of the file you edit. Prefix warnings and errors with `[HYDROGEN]`.
- Public API changes go through `src/init.luau`.
- Kit modules live in `src/<Module>/` and are exported as `Hydrogen.<Module>`. Requiring a module must have no side effects until it is used.

### Documentation is part of every change

A change to the public API, or to a rule users rely on, updates all of these:

- `README.md` (Part 1), for humans
- `docs/ai/<topic>.md`, for agents (format below)
- `llms.txt`, when a docs file is added or renamed
- `CHANGELOG.md`, under `## Unreleased`

`docs/ai/` and `llms.txt` ship inside the package, so agents in game projects can read them from `roblox_packages`.

Every `docs/ai/*.md` file uses this layout:

```
# <API name>
> One sentence: what it is and when to reach for it.
## Use it when / Don't use it when
## Quick start      smallest complete copy-pasteable example
## API              every public signature, one line each; mark what yields and what is server-only or client-only
## Rules            invariants and gotchas that cause bugs if ignored
## Recipes          3-6 common tasks done the idiomatic way
## Mistakes         "Don't X; do Y" pairs
## Testing          how to test code that uses it
## Errors and warnings   each [HYDROGEN] message, its meaning and the fix
## Works with       related modules
```

Write for an LLM: dense, with exact names and real signatures, and no marketing. Examples must type-check in strict mode and match the code. Each file must be self-contained.
