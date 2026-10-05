#!/usr/bin/env bash
# Hekz tests WITHOUT Roblox: real Luau syntax check + mocked runtime tests.
# Usage: ./test.sh        (network needed once to fetch the Luau runtime)
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/.testbin"
LUAC="$BIN/luau-compile"
LUAU="$BIN/luau"
FILES="Config.lua HekzBook.lua ToolRegistry.lua HekzServer.lua HekzExecutor.lua"
fail=0

# --- 1. Luau runtime (cached in .testbin) ---
if [ ! -x "$LUAU" ] || [ ! -x "$LUAC" ]; then
	echo "-- fetching Luau runtime (once, cached in .testbin) --"
	mkdir -p "$BIN"
	if ! curl -sL --max-time 120 -o "$BIN/luau.zip" \
		https://github.com/Roblox/luau/releases/latest/download/luau-ubuntu.zip; then
		echo "FAIL: could not download Luau runtime (need network once)"
		exit 1
	fi
	if command -v unzip >/dev/null 2>&1; then
		unzip -o -q "$BIN/luau.zip" -d "$BIN"
	else
		python3 -c "import zipfile; zipfile.ZipFile('$BIN/luau.zip').extractall('$BIN')"
	fi
	chmod +x "$BIN"/luau*
fi

# --- 2. syntax check every Luau file (real parser) ---
echo "-- syntax --"
for f in $FILES tests/mock.luau tests/prelude.luau tests/test_tools.luau tests/test_chat.luau tests/summary.luau; do
	if [ ! -f "$ROOT/$f" ]; then
		echo "FAIL syntax $f (missing)"
		fail=1
		continue
	fi
	if "$LUAC" --only-parse "$ROOT/$f" 2>/tmp/hekz_syn_err.txt; then
		echo "PASS syntax $f"
	else
		echo "FAIL syntax $f"
		cat /tmp/hekz_syn_err.txt
		fail=1
	fi
done

# --- 3. runtime tests: one bundle (this Luau runtime sandboxes require,
# --- so mocks + modules + server + tests are concatenated into one chunk ---
echo "-- runtime (mocked game, real Luau) --"
BUNDLE=/tmp/hekz_bundle.luau
{
	cat "$ROOT/tests/mock.luau"
	sed 's/^return Config$/__MOD_Config = Config/' "$ROOT/Config.lua"
	sed 's/^return HekzBook$/__MOD_HekzBook = HekzBook/' "$ROOT/HekzBook.lua"
	sed 's/^return ToolRegistry$/__MOD_ToolRegistry = ToolRegistry/' "$ROOT/ToolRegistry.lua"
	cat "$ROOT/tests/prelude.luau"
	cat "$ROOT/HekzServer.lua"
	cat "$ROOT/tests/test_tools.luau"
	cat "$ROOT/tests/test_chat.luau"
	cat "$ROOT/tests/summary.luau"
} > "$BUNDLE"
if "$LUAU" "$BUNDLE"; then
	echo "PASS runtime"
else
	echo "FAIL runtime"
	fail=1
fi

# executor GUI file is syntax-checked above; its panel wiring is manual-test only
echo "-- note: HekzExecutor.lua UI (panel/buttons) needs a real executor to eyeball --"

if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit "$fail"
