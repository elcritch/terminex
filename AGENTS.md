# Repository Guidelines

## Project Structure & Modules
- `src/`: Library modules. Keep the root module named after the package.
- `tests/`: Unit tests using Nim's `unittest`; test files should start with `t`.
- Root files: `nim_repo.nimble` for package metadata, `config.nims` for common compiler switches, and `README.md` for usage.

## Build, Test, And Development
- Install deps with Atlas: `atlas install`.
- Do not use Nimble for dependency resolution in normal development; use Atlas and its generated `deps/` folder and `nim.cfg`.
- Run multiple or all tests with `atlas-run tests [test-selections]`. Omit selections to run the full suite, or pass one or more test selectors to run focused tests. Selectors match as `foo` -> `tests/tfoo*.nim`, `foo.nim` -> `tests/tfoo.nim`, and `examples/foo*.nim` -> `examples/foo*.nim`. Do not adjust the `--jobs` count or the `--nimcache`.
- Compile the example bundle with `atlas-run tests --compile-only examples/all_compile.nim`; do not run `examples/all_compile.nim` as a test.
- Execute a single test locally using Nim:
  - `nim r tests/ttransfer.nim`
  - `nim r tests/ttransfer.nim -d:debug`


## Coding Style & Naming
- Indentation: 2 spaces; no tabs.
- Nim style: types in `PascalCase`, procs/vars in `camelCase`, modules in lowercase or concise `lowerCamel`.
- Format touched Nim files with `nph src/*.nim tests/*.nim` when available.

## Testing Guidelines
- Use `unittest` with descriptive `suite` and `test` names.
- Add tests under `tests/`, mirroring module names where practical.
- Keep tests deterministic and avoid network access unless the test explicitly targets networking.

## Commit & Pull Requests
- Commits: short, imperative mood, such as `add parser`.
- PRs: include a clear description, summary of changes, test coverage notes, and any concurrency or GC considerations.
- Requirements: CI must pass; include tests for new behavior and update docs for user-facing changes.

