# mudlet-busted

Welcome to Mudlet busted! I promise you it doesn't mean that Mudlet is busted. It's just called that because some brilliant engineer thought naming their thing that proves something isn't busted would be a playful inversion. Probably. Idk.

A Fedora-based Docker image for running [Busted](https://lunarmodules.github.io/busted/) tests inside a headless [Mudlet](https://www.mudlet.org/) instance.

## What's Inside

- **Mudlet** — installed from its [official Fedora RPM repository](https://packages.mudlet.net)
- **Lua 5.1** — matching Mudlet's embedded runtime
- **Busted** — Lua testing framework, installed via luarocks
- **Node.js 24** — for building mpackages with [muddy](https://www.npmjs.com/package/@gesslar/muddy)
- **Xvfb** — virtual framebuffer for headless GUI execution

## What Your Project Needs

By default the image builds your package with [muddy](https://www.npmjs.com/package/@gesslar/muddy), installs it into a fresh Mudlet profile, and then runs your specs against it. So the zero-config path expects:

- **An `mfile`** (muddy's package config, a JSON file) alongside your test specs or in your project root. For any other location inside your project, set `MFILE` to its path. If no `mfile` is found, the run stops with `Error: mfile not found`.
- **Spec files** named `*_spec.lua`.

Not using muddy? See [Bring Your Own Package](#bring-your-own-package).

## Quick Start

From your project root:

```bash
docker run --rm -v "$PWD":/workspace gesslardev/mudlet-busted
```

or, to test against a specific Mudlet release:

```bash
docker run --rm -v "$PWD":/workspace gesslardev/mudlet-busted:{{VERSION}}
```

## Tags

Image tags are **Mudlet versions**: `:5.0.2` runs your tests in Mudlet 5.0.2. `:latest` is whatever Mudlet release was current when the image was last published. Pin a version tag in CI if you want results that don't change when Mudlet does.

## What It Does

1. Auto-detects your test specs (`src/resources/test/`, `src/test/`, `test/specs/`, or `specs/`)
2. Finds an `mfile` in the test directory (or falls back to the project root)
3. Builds your `.mpackage` with muddy, in a temporary copy of your project
4. Derives the profile name (`<Package>Tests`) and package path from muddy's output
5. Installs a clean Mudlet test profile with the Busted bootstrap scripts, and installs your package into it
6. Runs Mudlet headlessly via `xvfb-run`, offline (it never connects to a game server)
7. Parses and displays results, and exits with a status code your CI can use

**No files are written to your project directory.**

## Convention Over Configuration

For zero-config usage, place an `mfile` alongside your test specs:

```
src/resources/test/
  mfile              # muddy config for the test build
  my_module_spec.lua
  another_spec.lua
```

The test `mfile` is usually a copy of your release `mfile` minus any `ignore` rule that excludes your test directory (for example `"ignore": ["resources/test/*"]`), so the test build includes everything. If there's no `mfile` next to your specs, the one in your project root is used.

## Bring Your Own Package

If you build your package some other way, skip the muddy step and point the image at the built file instead:

```bash
docker run --rm -v "$PWD":/workspace \
  -e SKIP_BUILD=true \
  -e PRETEST_PACKAGE=/workspace/build/MyPackage.mpackage \
  gesslardev/mudlet-busted
```

`PRETEST_PACKAGE` must be a path inside the container, so put it under `/workspace`. With `SKIP_BUILD=true` and no `PRETEST_PACKAGE`, nothing is installed and your specs run against a bare Mudlet profile. That works for specs that load their own code.

## Environment Variables

All optional — override only when the defaults don't fit. Paths are relative to your project root (mounted at `/workspace`), and anything you point at must be inside it.

| Variable | Default | Purpose |
|---|---|---|
| `MFILE` | Auto-detected | Path to the mfile for muddy |
| `TESTS_DIRECTORY` | Auto-detected | Directory containing `*_spec.lua` files |
| `SPEC_FILE` | — | Run a single spec file |
| `PROFILE_NAME` | `${PackageName}Tests`, or `BustedTests` | Mudlet profile name |
| `PROFILE_SOURCE` | `test/profile/` if present, else built-in | Custom test profile directory |
| `SKIP_BUILD` | `false` | Skip the muddy build step |
| `PRETEST_PACKAGE` | Muddy's build output | Package to install before the specs run (use with `SKIP_BUILD=true`) |
| `BUSTED_OUTPUT` | `plainTerminal` | Busted output handler (`treeOutput` for a nested describe/it tree) |
| `TEST_TIMEOUT` | `300` | Max seconds for the test run before it is killed |
| `SENTINEL` | `/tmp/busted-tests-failed` | Failure sentinel file path |
| `OUTPUT_LOG` | `/tmp/test-output.log` | Raw Mudlet output log path |

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | Every test passed |
| `1` | At least one failure or error, **or** no results were produced: Mudlet failed to start, crashed, or hit `TEST_TIMEOUT` |

A run that produces no results never reports success.

## Output

A passing run:

```
========================================
  Test Results
========================================

✓ 1083 successes
✗ 0 failures
⊘ 0 errors
? 0 pending
≈ 1.041343 seconds
```

A failing run adds each failure or error, with the spec file and line:

```
✓ 2 successes
✗ 1 failure
⊘ 0 errors
? 0 pending
≈ 0.000737 seconds

----------------------------------------
  FAILURES / ERRORS
----------------------------------------
Failure -> /workspace/specs/my_module_spec.lua @ 10
my module formats a name
/workspace/specs/my_module_spec.lua:11: Expected objects to be equal.
Passed in:
(string) 'Hello, world'
Expected:
(string) 'Hello, World'
```

If the results can't be parsed, the raw Mudlet output is printed instead, so you can see what went wrong.

## CI

The exit code is all CI needs. For GitHub Actions:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run Busted tests in Mudlet
        run: docker run --rm -v "$PWD":/workspace gesslardev/mudlet-busted:{{VERSION}}
```

## Examples

```bash
# Run all tests (zero config)
docker run --rm -v "$PWD":/workspace gesslardev/mudlet-busted

# Run a single spec
docker run --rm -v "$PWD":/workspace \
  -e SPEC_FILE=src/resources/test/date_spec.lua \
  gesslardev/mudlet-busted

# Use a specific mfile
docker run --rm -v "$PWD":/workspace \
  -e MFILE=path/to/my/mfile \
  gesslardev/mudlet-busted

# Test a package you built yourself (no muddy)
docker run --rm -v "$PWD":/workspace \
  -e SKIP_BUILD=true \
  -e PRETEST_PACKAGE=/workspace/build/MyPackage.mpackage \
  gesslardev/mudlet-busted

# Tree-style output (nested describe/it)
docker run --rm -v "$PWD":/workspace \
  -e BUSTED_OUTPUT=treeOutput \
  gesslardev/mudlet-busted

# Drop into a shell for debugging
docker run --rm -it -v "$PWD":/workspace gesslardev/mudlet-busted bash
```

## Writing Tests

Test files must be named `*_spec.lua` and use Busted's `describe`/`it` syntax. Your specs run inside Mudlet, so the Mudlet Lua API is available directly.

```lua
describe("my module", function()
  it("should do the thing", function()
    assert.are.equal(42, my_function())
  end)
end)
```

Mudlet runs **offline**: there's no game connection. Anything that depends on a server, such as `send()` reaching a game or connection events firing, should be shimmed in your specs. Simulate incoming game text with `feedTriggers()`.

## Test Profile

The image includes a default Busted bootstrap profile based on [demonnic/MudletBusted](https://github.com/demonnic/MudletBusted). To use a custom profile, place it at `test/profile/` in your project or set `PROFILE_SOURCE`.

## Credits

- [demonnic/test-in-mudlet](https://github.com/demonnic/test-in-mudlet)
- [demonnic/MudletBusted](https://github.com/demonnic/MudletBusted)
