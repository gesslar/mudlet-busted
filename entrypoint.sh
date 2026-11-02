#!/usr/bin/env bash
set -euo pipefail

. /usr/bin/symbols

# =============================================================================
# Mudlet Busted Test Runner — Entrypoint
#
# Environment variables:
#   MUDLET_BIN            Path to the Mudlet binary (default: /usr/bin/mudlet)
#   PROFILE_NAME          Mudlet profile name (default: derived from .output, or BustedTests)
#   PROFILE_SOURCE        Path to test profile dir (default: test/profile, or built-in)
#   TESTS_DIRECTORY       Path to spec files or single spec (default: auto-detect)
#   SPEC_FILE             Single spec file to run (overrides TESTS_DIRECTORY)
#   MFILE                 Path to mfile for muddy (default: mfile)
#   SENTINEL              Path to failure sentinel file (default: /tmp/busted-tests-failed)
#   OUTPUT_LOG            Path to raw output log (default: /tmp/test-output.log)
#   TEST_TIMEOUT          Max seconds for the Mudlet test run (default: 300)
#   ALLOW_LUA_ERRORS      Set to true to report Lua errors raised outside specs
#                         without failing the run (default: false)
# =============================================================================

MUDLET_BIN="${MUDLET_BIN:-/usr/bin/mudlet}"
PROFILE_NAME="${PROFILE_NAME:-BustedTests}"
PROFILE_DIR="$HOME/.config/mudlet/profiles/$PROFILE_NAME"
SENTINEL="${SENTINEL:-/tmp/busted-tests-failed}"
OUTPUT_LOG="${OUTPUT_LOG:-/tmp/test-output.log}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
SKIP_BUILD="${SKIP_BUILD:-false}"
# BUSTED_FMT="${BUSTED_OUTPUT:-treeOutput}"
BUSTED_FMT="${BUSTED_OUTPUT:-plainTerminal}"
ALLOW_LUA_ERRORS="${ALLOW_LUA_ERRORS:-false}"

# ---------------------------------------------------------------------------
# If a command was passed, just run it (allows overriding the entrypoint)
# ---------------------------------------------------------------------------
if [[ $# -gt 0 ]]; then
  exec "$@"
fi

# ---------------------------------------------------------------------------
# Set up Lua paths
# ---------------------------------------------------------------------------
eval "$(luarocks --lua-version 5.1 path)"

# ---------------------------------------------------------------------------
# Determine what to test
# ---------------------------------------------------------------------------
if [[ -n "${SPEC_FILE:-}" ]]; then
  TESTS_DIR="$(cd "$(dirname "$SPEC_FILE")" && pwd)/$(basename "$SPEC_FILE")"
elif [[ -n "${TESTS_DIRECTORY:-}" ]]; then
  TESTS_DIR="$TESTS_DIRECTORY"
else
  # Auto-detect common spec locations
  for candidate in src/resources/test src/test test/specs specs; do
    if [[ -d "$candidate" ]]; then
      TESTS_DIR="$(pwd)/$candidate"
      break
    fi
  done
  TESTS_DIR="${TESTS_DIR:-$(pwd)}"
fi

# ---------------------------------------------------------------------------
# Resolve mfile — check tests directory first, then project root
# ---------------------------------------------------------------------------
if [[ -n "${MFILE:-}" ]]; then
  : # explicit override, use as-is
else
  # A co-located mfile lives in the spec's directory. TESTS_DIR may be a single
  # spec file (SPEC_FILE mode) or a directory — resolve the directory for either.
  if [[ -d "$TESTS_DIR" ]]; then
    mfile_dir="$TESTS_DIR"
  else
    mfile_dir="$(dirname "$TESTS_DIR")"
  fi

  if [[ -f "$mfile_dir/mfile" ]]; then
    MFILE="$mfile_dir/mfile"
  else
    MFILE="mfile"
  fi
fi

# ---------------------------------------------------------------------------
# Build step (in a temp directory — no writes to the mounted workspace)
# ---------------------------------------------------------------------------
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

if [[ "$SKIP_BUILD" != "true" ]]; then
  echo "==> Building package with muddy..."
  echo "    mfile:    $MFILE"

  # Copy project into the build dir so muddy doesn't write to the mount
  cp -a /workspace/. "$BUILD_DIR/"

  # The build runs against a copy of /workspace, so the mfile must live inside
  # it for the corresponding path in the build dir to exist.
  if [[ ! -f "$MFILE" ]]; then
    echo "Error: mfile not found: $MFILE"
    exit 1
  fi

  MFILE_ABS="$(cd "$(dirname "$MFILE")" && pwd)/$(basename "$MFILE")"
  case "$MFILE_ABS" in
    /workspace/*) ;;
    *) echo "Error: mfile must be inside the mounted workspace (/workspace): $MFILE"; exit 1 ;;
  esac

  # Ensure outputFile is true in the mfile so .output gets written
  BUILD_MFILE="$BUILD_DIR/${MFILE_ABS#/workspace/}"
  # Path is passed as argv (not interpolated into the JS source) so special
  # characters in a user-supplied MFILE can't break or inject into the script.
  node -e '
    const fs = require("fs")
    const p = process.argv[1]
    const mf = JSON.parse(fs.readFileSync(p, "utf8"))
    mf.outputFile = true
    fs.writeFileSync(p, JSON.stringify(mf, null, 2) + "\n")
  ' "$BUILD_MFILE"

  cd "$BUILD_DIR"
  npx @gesslar/muddy --mfile "$BUILD_MFILE"

  # muddy writes .output with {"name":"...","path":"/build/Foo.mpackage"}
  if [[ -f "$BUILD_DIR/.output" ]]; then
    PKG_NAME="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).name)' "$BUILD_DIR/.output")"
    PKG_PATH="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).path)' "$BUILD_DIR/.output")"
    PRETEST_PACKAGE="${BUILD_DIR}${PKG_PATH}"
    PROFILE_NAME="${PKG_NAME}Tests"
    PROFILE_DIR="$HOME/.config/mudlet/profiles/$PROFILE_NAME"
    echo "    Built: $PRETEST_PACKAGE"
  fi

  cd /workspace
fi

# ---------------------------------------------------------------------------
# Validate PROFILE_NAME before it touches the filesystem.
# It is user-controlled (env) and derived from package metadata (.output's
# name), and feeds both rm -rf "$PROFILE_DIR" and a sed replacement. Restrict
# it to a safe charset: no '/' (path traversal), no '&'/'|' (sed breakage),
# and reject the '.'/'..' directory references outright.
# ---------------------------------------------------------------------------
if [[ ! "$PROFILE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$PROFILE_NAME" == "." || "$PROFILE_NAME" == ".." ]]; then
  echo "Error: invalid PROFILE_NAME '$PROFILE_NAME'"
  echo "       (allowed: letters, digits, '.', '_', '-'; no '/', and not '.' or '..')"
  exit 1
fi

# ---------------------------------------------------------------------------
# Install test profile
# ---------------------------------------------------------------------------
# Use project-local profile if present, otherwise fall back to the one
# baked into the image.
PROFILE_SOURCE="${PROFILE_SOURCE:-}"
if [[ -z "$PROFILE_SOURCE" ]]; then
  if [[ -d "test/profile" ]]; then
    PROFILE_SOURCE="test/profile"
  else
    PROFILE_SOURCE="/opt/mudlet/default-profile"
  fi
fi

echo "==> Installing test profile ($PROFILE_NAME)..."
rm -rf "$PROFILE_DIR"
mkdir -p "$PROFILE_DIR"
cp -a "$PROFILE_SOURCE"/. "$PROFILE_DIR/"

# Replace placeholder with actual profile name
find "$PROFILE_DIR" -name '*.xml' -exec \
  sed -i "s|__PROFILE_NAME__|$PROFILE_NAME|g" {} +

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------
rm -f "$SENTINEL" "$OUTPUT_LOG"

echo "==> Running tests..."
echo "    Profile:  $PROFILE_NAME"
echo "    Tests:    $TESTS_DIR"
echo "    Package:  ${PRETEST_PACKAGE:-none}"
echo ""

export AUTORUN_BUSTED_TESTS=true
export TESTS_DIRECTORY="$TESTS_DIR"
export QUIT_MUDLET_AFTER_TESTS=true
export PRETEST_PACKAGE="${PRETEST_PACKAGE:-NONE}"
export SENTINEL
# Unique to this run, so only this run's treeOutput can report completion.
MUDLET_BUSTED_RUN_ID="$(cat /proc/sys/kernel/random/uuid)"
export MUDLET_BUSTED_RUN_ID
# The profile keeps the current spec here, to name it if the run never finishes.
export MUDLET_BUSTED_SPEC_STATE="$BUILD_DIR/spec-state"
# Skips Mudlet's startup update check. Otherwise, whenever a newer Mudlet is
# released, the updater downloads it in the background and closeMudlet()
# never completes, so the run hangs until TEST_TIMEOUT.
export MUDLET_TEST_MODE=1


MUDLET_RC=0
timeout "$TEST_TIMEOUT" \
  xvfb-run --auto-servernum \
  "$MUDLET_BIN" \
  --profile "$PROFILE_NAME" \
  --offline \
  --mirror \
  >"$OUTPUT_LOG" 2>&1 || MUDLET_RC=$?

# ---------------------------------------------------------------------------
# Parse and display results
# ---------------------------------------------------------------------------

# Lua errors Mudlet caught itself (event handlers, timers) never reach busted,
# so they appear in neither its counts nor the sentinel. Since 5.1 they are
# mirrored from the profile's errors console. plainTerminal's progress marks can
# sit ahead of the prefix on the same line. Find the exact prefix first, since a
# profile name may itself start with one of those marks, then allow only marks
# before it, so text a spec feeds to the main console can't count as an error.
LUA_ERRORS=$(awk -v prefix="$PROFILE_NAME.errors_$PROFILE_NAME| " '
  { start = index($0, prefix) }
  start == 0 || substr($0, 1, start - 1) !~ /^[-+*.]*$/ { next }
  { line = substr($0, start + length(prefix)) }
  line ~ /^\[ERROR:\]/ { seen = 1 }
  seen { print line }
' "$OUTPUT_LOG" 2>/dev/null || true)
LUA_ERROR_COUNT=$(printf '%s\n' "$LUA_ERRORS" | grep -c '^\[ERROR:\]' || true)
if [[ "$LUA_ERROR_COUNT" -eq 1 ]]; then
  LUA_ERROR_LABEL="Lua error"
else
  LUA_ERROR_LABEL="Lua errors"
fi

# Tree output handler prints its own formatted results — pass them through.
# For plainTerminal, parse the summary line and reformat.
if [[ "$BUSTED_FMT" == "treeOutput" ]]; then
  # The tree handler emits describe/it tree + summary directly.
  # Strip Mudlet noise, show everything from the first test output onward.
  # Mudlet 5.1 prefixes mirrored lines with "<profile>.<console>| " (5.0 used
  # "<console>| "), and a spec's unterminated echo() can sit ahead of the tag on
  # the same line. Keep main-console lines only, cut through the last tag.
  # The handler prints its summary before late errors (timers) can fire, so the
  # Lua error count is added here, only when non-zero like its other categories.
  TREE_OUTPUT=$(sed -n 's/^[^|]*main|.*\[mudlet-busted\] //p' "$OUTPUT_LOG" || true)
  if [[ -n "$TREE_OUTPUT" ]]; then
    echo "$TREE_OUTPUT"
    if [[ "$LUA_ERROR_COUNT" -gt 0 ]]; then
      # The LUA ERRORS section below supplies the blank line.
      echo "$(WARN)  $LUA_ERROR_COUNT $LUA_ERROR_LABEL"
    else
      echo ""
    fi
  fi
else
  # Anchored: busted's own summary is unprefixed at line start, while text a
  # spec feeds through feedTriggers() is mirrored with a console prefix and must
  # not be mistaken for it.
  SUMMARY=$(grep -oP '^\d+ success(es)? / \d+ failures? / \d+ errors? / \d+ pending.*seconds' "$OUTPUT_LOG" || echo "")

  # Capture complete failure/error blocks. A fixed -A window truncates the
  # assertion diff (Expected/Passed-in tables can run many lines), so instead
  # print from the first 'Failure ->'/'Error ->' marker until the summary or
  # shutdown line.
  DETAILS=$(awk '
    /success(es)? \/ .*failures?/ {show=0}
    /shutting down Mudlet/ {show=0}
    /^(Failure|Error) -> / {show=1}
    show {print}
  ' "$OUTPUT_LOG" || true)

  echo "========================================"
  echo "  Test Results"
  echo "========================================"
  echo ""

  if [[ -n "$SUMMARY" ]]; then
    IFS='/' read -ra parts <<< "$SUMMARY"
    IFS=':' read -ra lastbit <<< "${parts[3]}"

    # Now do some data transposition for cleanliness
    parts[3]=${lastbit[0]}
    dur=${lastbit[1]}

    # Access elements
    echo "$(OK) ${parts[0]}" | awk '{$1=$1; print}'     # successes
    echo "$(FAIL) ${parts[1]}" | awk '{$1=$1; print}'   # failures
    echo "$(NO) ${parts[2]}" | awk '{$1=$1; print}'     # errors
    echo "$(WARN) $LUA_ERROR_COUNT $LUA_ERROR_LABEL"    # raised outside specs
    echo "$(ASK) ${parts[3]}" | awk '{$1=$1; print}' # pending
    echo "$(ALMOST) ${dur}" | awk '{$1=$1; print}' # pending
  else
    echo "  Could not parse test results."
    echo ""
    echo "----------------------------------------"
    echo "  RAW OUTPUT"
    echo "----------------------------------------"
    cat "$OUTPUT_LOG" 2>/dev/null || echo "  (no output captured)"
    echo "----------------------------------------"
  fi

  if [[ -n "$DETAILS" ]]; then
    echo ""
    echo "----------------------------------------"
    echo "  FAILURES / ERRORS"
    echo "----------------------------------------"
    echo "$DETAILS"
    echo ""
  fi
fi

if [[ -n "$LUA_ERRORS" ]]; then
  echo ""
  echo "----------------------------------------"
  echo "  LUA ERRORS ($LUA_ERROR_COUNT, raised outside specs)"
  echo "----------------------------------------"
  echo "$LUA_ERRORS"
  echo ""
fi

if [[ -f "$SENTINEL" ]]; then
  # Tests ran and at least one failed.
  rm -f "$SENTINEL"
  exit 1
elif grep -qP "^\\d+ success(es)? / \\d+ failures? / |^[^|]*main\\| \\[mudlet-busted:complete:$MUDLET_BUSTED_RUN_ID\\]\$" "$OUTPUT_LOG"; then
  # Tests ran to completion and none failed. These match only plainTerminal's
  # summary and treeOutput's completion marker for this run, so mirrored game
  # text or a spec named "3 passing" can't pass off a crashed or hung run as a
  # success.
  if [[ -n "$LUA_ERRORS" && "$ALLOW_LUA_ERRORS" != "true" ]]; then
    echo "  FAILED: all specs passed, but the $LUA_ERROR_COUNT Lua error(s) above were raised"
    echo "  outside them. If they're expected, set ALLOW_LUA_ERRORS=true."
    exit 1
  fi
  rm -f "$OUTPUT_LOG"
  exit 0
else
  # No sentinel and no result summary — Mudlet failed to start, crashed or hung
  # before the suite finished. Never report success in this case.

  # plainTerminal already dumped the raw log above, when it found no summary.
  if [[ "$BUSTED_FMT" == "treeOutput" ]]; then
    echo "----------------------------------------"
    cat "$OUTPUT_LOG" 2>/dev/null || echo "  (no output captured)"
    echo "----------------------------------------"
  fi

  if [[ "$MUDLET_RC" -eq 124 ]]; then
    STOPPED="Timed out after ${TEST_TIMEOUT}s (TEST_TIMEOUT)"
    ADVICE="Check it for an infinite loop or a call that blocks."
  else
    STOPPED="Mudlet stopped unexpectedly (exit: $MUDLET_RC)"
    ADVICE="Check it for a call that exits or crashes Mudlet."
  fi

  # Left in place by the profile. A custom test/profile may not write it.
  SPEC_STATE=""
  SPEC_DESCRIPTION=""
  if [[ -f "$MUDLET_BUSTED_SPEC_STATE" ]]; then
    IFS=$'\t' read -r SPEC_STATE SPEC_DESCRIPTION <"$MUDLET_BUSTED_SPEC_STATE" || true
  fi

  echo ""
  case "$SPEC_STATE" in
    running)
      echo "  ERROR: $STOPPED while running this spec:"
      echo "    $SPEC_DESCRIPTION"
      echo "  $ADVICE"
      ;;
    finished)
      echo "  ERROR: $STOPPED after this spec finished:"
      echo "    $SPEC_DESCRIPTION"
      echo "  $ADVICE The cause may be in the spec itself, or in the next spec's"
      echo "  before_each, or in a setup or teardown block."
      ;;
    file)
      echo "  ERROR: $STOPPED before any spec started in this file:"
      echo "    $SPEC_DESCRIPTION"
      echo "  $ADVICE Look at its top-level code, its describe bodies and its setup blocks."
      ;;
    *)
      echo "  ERROR: $STOPPED and no test results were produced."
      echo "  Mudlet may have failed to start, or your package may have stopped it"
      echo "  while installing."
      ;;
  esac
  exit 1
fi
