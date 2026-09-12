#!/usr/bin/env bash
# tests for the `model` command. uses a temp CODEX_HOME + CX_MODELS_STUB (no network).
set -uo pipefail
SW="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/agent-switch"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

setup() {
  T="$(mktemp -d)"; export CODEX_HOME="$T"
  "$SW" codex init >/dev/null
  printf 'https://[IP]:9/v1\ngpt-a\n\nsk-fakeAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' | "$SW" codex add p1 >/dev/null
  "$SW" codex use p1 >/dev/null 2>&1
  sqlite3 "$T/state_5.sqlite" "CREATE TABLE threads(id INTEGER PRIMARY KEY, model TEXT); INSERT INTO threads(model) VALUES('old'),('old');"
}
teardown() { unset CODEX_HOME CX_MODELS_STUB; rm -rf "$T"; }

# 1. list marks current
setup
export CX_MODELS_STUB=$'gpt-a\ngpt-b\ngpt-c'
out="$("$SW" codex model)"
echo "$out" | grep -q '^\* gpt-a' && echo "$out" | grep -q '^  gpt-b' && pass "list marks current" || fail "list marks current"

# 2. valid switch updates config + meta + db
"$SW" codex model gpt-b >/dev/null
grep -q '^model = "gpt-b"' "$T/config.toml" && pass "switch updates config" || fail "switch updates config"
grep -q '^model=gpt-b' "$T/cc-profiles/p1/meta" && pass "switch persists meta" || fail "switch persists meta"
[ "$(sqlite3 "$T/state_5.sqlite" "SELECT DISTINCT model FROM threads;")" = "gpt-b" ] && pass "switch rewrites db" || fail "switch rewrites db"
teardown

# 3. invalid model refused, config unchanged
setup
export CX_MODELS_STUB=$'gpt-a\ngpt-b'
before="$(grep '^model = ' "$T/config.toml")"
"$SW" codex model nope 2>/dev/null; rc=$?
[ "$rc" != 0 ] && pass "invalid model exits nonzero" || fail "invalid model exits nonzero"
[ "$(grep '^model = ' "$T/config.toml")" = "$before" ] && pass "invalid model leaves config" || fail "invalid model leaves config"
teardown

# 4. --no-db skips db rewrite
setup
export CX_MODELS_STUB=$'gpt-a\ngpt-b'
"$SW" codex model gpt-b --no-db >/dev/null
[ "$(sqlite3 "$T/state_5.sqlite" "SELECT DISTINCT model FROM threads;")" = "old" ] && pass "--no-db skips db" || fail "--no-db skips db"
teardown

# 5. unavailable list -> warn + proceed (stub unset => curl to [IP]:9 fails fast)
setup
unset CX_MODELS_STUB
"$SW" codex model gpt-z 2>/dev/null
grep -q '^model = "gpt-z"' "$T/config.toml" && pass "unavailable list proceeds" || fail "unavailable list proceeds"
teardown

# 6. injection-safe: special chars in model name must not damage db or config
setup
mal="e'&|d"
export CX_MODELS_STUB=$'gpt-a\ngpt-b\n'"$mal"
"$SW" codex model "$mal" >/dev/null 2>&1
n="$(sqlite3 "$T/state_5.sqlite" "SELECT count(*) FROM threads;" 2>/dev/null)"
[ "$n" = 2 ] && pass "injection: threads table intact" || fail "injection: threads table intact (got '$n')"
[ "$(grep -c '^model = ' "$T/config.toml")" = 1 ] && pass "injection: config has one model line" || fail "injection: config model line"
[ "$(sqlite3 "$T/state_5.sqlite" "SELECT DISTINCT model FROM threads;" 2>/dev/null)" = "$mal" ] && pass "injection: model set literally" || fail "injection: model set literally"
teardown

# 7. requires_openai_auth is added to a legacy provider block and stays idempotent
setup
grep -v '^requires_openai_auth' "$T/config.toml" > "$T/c2" && mv "$T/c2" "$T/config.toml"
export CX_MODELS_STUB=$'gpt-a\ngpt-b'
"$SW" codex use p1 >/dev/null 2>&1
[ "$(grep -c '^requires_openai_auth = true' "$T/config.toml")" = 1 ] \
  && pass "switch adds requires_openai_auth" || fail "switch adds requires_openai_auth"
"$SW" codex use p1 >/dev/null 2>&1
[ "$(grep -c '^requires_openai_auth = true' "$T/config.toml")" = 1 ] \
  && pass "requires_openai_auth is idempotent" || fail "requires_openai_auth is idempotent"
python3 -c "import sys,tomllib; tomllib.load(open(sys.argv[1],'rb'))" "$T/config.toml" \
  && pass "config still parses as TOML" || fail "config still parses as TOML"
teardown

[ "$FAIL" = 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
