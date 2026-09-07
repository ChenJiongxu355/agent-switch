#!/usr/bin/env bash
# Offline tests for Claude Code profile switching.
set -euo pipefail

SW="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/agent-switch"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/claude"
cat > "$T/claude/settings.json" <<'JSON'
{
  "permissions": {"allow": ["Read(*)"]},
  "env": {
    "ANTHROPIC_BASE_URL": "https://old.example",
    "ANTHROPIC_AUTH_TOKEN": "old-secret",
    "ANTHROPIC_MODEL": "old-model",
    "KEEP_ME": "yes"
  }
}
JSON

cat > "$T/a.json" <<'JSON'
{"env": {"ANTHROPIC_BASE_URL": "https://a.example", "ANTHROPIC_AUTH_TOKEN": "a-secret", "ANTHROPIC_MODEL": "a-model"}}
JSON
cat > "$T/b.json" <<'JSON'
{"env": {"ANTHROPIC_BASE_URL": "https://b.example", "ANTHROPIC_AUTH_TOKEN": "b-secret", "ANTHROPIC_MODEL": "b-model", "AWS_REGION": "us-test-1"}}
JSON

run() { CLAUDE_HOME="$T/claude" CODEX_HOME="$T/codex" "$SW" "$@"; }
run cc init >/dev/null
run cc add a --env-file "$T/a.json" >/dev/null
run cc add b --env-file "$T/b.json" >/dev/null
run cc use a >/dev/null

python3 - "$T/claude/settings.json" "$T/claude/provider-profiles/a/env.json" <<'PY'
import json,sys,stat
s=json.load(open(sys.argv[1])); p=json.load(open(sys.argv[2]))
assert s['permissions']['allow']==['Read(*)']
assert s['env']['KEEP_ME']=='yes'
assert s['env']['ANTHROPIC_BASE_URL']=='https://a.example'
assert s['env']['ANTHROPIC_AUTH_TOKEN']=='a-secret'
assert s['env']['ANTHROPIC_MODEL']=='a-model'
assert stat.S_IMODE(__import__('os').stat(sys.argv[2]).st_mode)==0o600
print('PASS: initial merge and permissions')
PY

run cc use b >/dev/null
python3 - "$T/claude/settings.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); e=s['env']
assert e['ANTHROPIC_BASE_URL']=='https://b.example'
assert e['ANTHROPIC_AUTH_TOKEN']=='b-secret'
assert e['ANTHROPIC_MODEL']=='b-model'
assert e['AWS_REGION']=='us-test-1'
assert e['KEEP_ME']=='yes'
assert 'old-secret' not in open(sys.argv[1]).read()
print('PASS: switch removes stale managed values')
PY

run cc model b-model-2 >/dev/null
python3 - "$T/claude/settings.json" "$T/claude/provider-profiles/b/env.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['env']['ANTHROPIC_MODEL']=='b-model-2'
assert json.load(open(sys.argv[2]))['env']['ANTHROPIC_MODEL']=='b-model-2'
print('PASS: model updates profile and settings')
PY

list_out="$(run cc list)"
grep -q '^\* b (current)$' <<< "$list_out"
current_out="$(run cc current)"
grep -q '^b$' <<< "$current_out"
echo 'PASS: list and current'

run cc restore >/dev/null
python3 - "$T/claude/settings.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['env']['ANTHROPIC_MODEL']=='b-model'
print('PASS: restore'
)
PY

echo 'ALL CLAUDE TESTS PASSED'
