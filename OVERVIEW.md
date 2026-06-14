# mudlet-busted

Welcome to Mudlet busted! I promise you it doesn't mean that Mudlet is busted. It's just called that because some brilliant engineer thought naming their thing that proves something isn't busted would be a playful inversion. Probably. Idk.

A Fedora-based Docker image for running [Busted](https://lunarmodules.github.io/busted/) tests inside a headless [Mudlet](https://www.mudlet.org/) instance.

## What's Inside

- **Mudlet AppImage** — extracted AppImage, no FUSE required
- **Lua 5.1** — matching Mudlet's embedded runtime
- **Busted** — Lua testing framework, installed via luarocks
- **Node.js 24** — for building mpackages with [muddy](https://www.npmjs.com/package/@gesslar/muddy)
- **Xvfb** — virtual framebuffer for headless GUI execution

## Quick Start

```bash
docker run --rm -v "$PWD":/workspace gesslardev/mudlet-busted
```
or
```bash
docker run --rm -v "$PWD":/workspace gesslardev/mudlet-busted:4.21.0
```

## What It Does

1. Auto-detects your test specs (`src/resources/test/`, `src/test/`, `test/specs/`, or `specs/`)
2. Finds an `mfile` in the test directory (or falls back to project root)
3. Builds your `.mpackage` with [muddy](https://www.npmjs.com/package/@gesslar/muddy)
4. Derives the profile name and package path from muddy's output
5. Installs a clean Mudlet test profile with Busted bootstrap scripts
6. Runs tests headlessly via `xvfb-run`
7. Parses and displays results

**No files are written to your project directory.**

## Convention Over Configuration

For zero-config usage, place an `mfile` alongside your test specs:

```
src/resources/test/
  mfile              # muddy config (without ignore for test specs)
  my_module_spec.lua
  another_spec.lua
```

The image handles everything else automatically.

## Environment Variables

All optional — override only when the defaults don't fit:

| Variable | Default | Purpose |
|---|---|---|
| `MFILE` | Auto-detected | Path to mfile for muddy |
| `TESTS_DIRECTORY` | Auto-detected | Directory containing `*_spec.lua` files |
| `SPEC_FILE` | — | Run a single spec file |
| `PROFILE_NAME` | `${PackageName}Tests` | Mudlet profile name |
| `PROFILE_SOURCE` | Built-in or `test/profile/` | Custom test profile directory |
| `SKIP_BUILD` | `false` | Skip the muddy build step |
| `SENTINEL` | `/tmp/busted-tests-failed` | Failure sentinel file path |
| `OUTPUT_LOG` | `/tmp/test-output.log` | Raw Mudlet output log path |

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

# Skip build (pre-built mpackage)
docker run --rm -v "$PWD":/workspace \
  -e SKIP_BUILD=true \
  gesslardev/mudlet-busted

# Drop into a shell for debugging
docker run --rm -it -v "$PWD":/workspace gesslardev/mudlet-busted bash
```

## Writing Tests

Test files must be named `*_spec.lua` and use Busted's `describe`/`it` syntax. All Mudlet APIs are available natively.

```lua
describe("my module", function()
  it("should do the thing", function()
    assert.are.equal(42, my_function())
  end)
end)
```

## Test Profile

The image includes a default Busted bootstrap profile based on [demonnic/MudletBusted](https://github.com/demonnic/MudletBusted). To use a custom profile, place it at `test/profile/` in your project or set `PROFILE_SOURCE`.

## Credits

- [demonnic/test-in-mudlet](https://github.com/demonnic/test-in-mudlet)
- [demonnic/MudletBusted](https://github.com/demonnic/MudletBusted)
