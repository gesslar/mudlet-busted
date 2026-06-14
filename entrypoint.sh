#!/usr/bin/env bash
set -euo pipefail

. /usr/bin/symbols

# =============================================================================
# Mudlet Busted Test Runner — Entrypoint
#
# Environment variables:
#   MUDLET_BIN            Path to the Mudlet binary (default: extracted AppImage)
#   PROFILE_NAME          Mudlet profile name (default: derived from .output, or BustedTests)
#   PROFILE_SOURCE        Path to test profile dir (default: test/profile, or built-in)
#   TESTS_DIRECTORY       Path to spec files or single spec (default: auto-detect)
#   SPEC_FILE             Single spec file to run (overrides TESTS_DIRECTORY)
#   MFILE                 Path to mfile for muddy (default: mfile)
#   SENTINEL              Path to failure sentinel file (default: /tmp/busted-tests-failed)
#   OUTPUT_LOG            Path to raw output log (default: /tmp/test-output.log)
# =============================================================================

MUDLET_BIN="${MUDLET_BIN:-/opt/mudlet/mudlet-app/AppRun}"
PROFILE_NAME="${PROFILE_NAME:-BustedTests}"
PROFILE_DIR="$HOME/.config/mudlet/profiles/$PROFILE_NAME"
SENTINEL="${SENTINEL:-/tmp/busted-tests-failed}"
OUTPUT_LOG="${OUTPUT_LOG:-/tmp/test-output.log}"
SKIP_BUILD="${SKIP_BUILD:-false}"
# BUSTED_FMT="${BUSTED_OUTPUT:-treeOutput}"
BUSTED_FMT="${BUSTED_OUTPUT:-plainTerminal}"

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
elif [[ -f "$TESTS_DIR/mfile" ]]; then
  MFILE="$TESTS_DIR/mfile"
else
  MFILE="mfile"
fi

# ---------------------------------------------------------------------------
# Build step (in a temp directory — no writes to the mounted workspace)
# ---------------------------------------------------------------------------
BUILD_DIR="$(mktemp -d)"

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
  node -e "
    const fs = require('fs')
    const mf = JSON.parse(fs.readFileSync('$BUILD_MFILE', 'utf8'))
    mf.outputFile = true
    fs.writeFileSync('$BUILD_MFILE', JSON.stringify(mf, null, 2) + '\n')
  "

  cd "$BUILD_DIR"
  npx @gesslar/muddy --mfile "$BUILD_MFILE"

  # muddy writes .output with {"name":"...","path":"/build/Foo.mpackage"}
  if [[ -f "$BUILD_DIR/.output" ]]; then
    PKG_NAME="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('$BUILD_DIR/.output','utf8')).name)")"
    PKG_PATH="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('$BUILD_DIR/.output','utf8')).path)")"
    PRETEST_PACKAGE="${BUILD_DIR}${PKG_PATH}"
    PROFILE_NAME="${PKG_NAME}Tests"
    PROFILE_DIR="$HOME/.config/mudlet/profiles/$PROFILE_NAME"
    echo "    Built: $PRETEST_PACKAGE"
  fi

  cd /workspace
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


xvfb-run --auto-servernum \
  "$MUDLET_BIN" \
  --profile "$PROFILE_NAME" \
  --mirror \
  >"$OUTPUT_LOG" 2>&1 || true

# ---------------------------------------------------------------------------
# Parse and display results
# ---------------------------------------------------------------------------

# Tree output handler prints its own formatted results — pass them through.
# For plainTerminal, parse the summary line and reformat.
if [[ "$BUSTED_FMT" == "treeOutput" ]]; then
  # The tree handler emits describe/it tree + summary directly.
  # Strip Mudlet noise, show everything from the first test output onward.
  sed -n 's/^main| \[mudlet-busted\] //p' "$OUTPUT_LOG" || true
else
  SUMMARY=$(grep -oP '\d+ successes? / \d+ failures? / \d+ errors? / \d+ pending.*seconds' "$OUTPUT_LOG" || echo "")

  # Capture complete failure/error blocks. A fixed -A window truncates the
  # assertion diff (Expected/Passed-in tables can run many lines), so instead
  # print from the first 'Failure ->'/'Error ->' marker until the summary or
  # shutdown line.
  DETAILS=$(awk '
    /successes? \/ .*failures?/ {show=0}
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

if [[ -f "$SENTINEL" ]]; then
  rm -f "$SENTINEL"
  exit 1
else
  rm -f "$OUTPUT_LOG"
  exit 0
fi
