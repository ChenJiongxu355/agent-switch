# codex-switch

Switch the [OpenAI Codex](https://github.com/openai/codex) CLI **and** the VSCode
Codex plugin between multiple API relays (中转站) with one command — without losing
your session history across relays.

```
$ codex-switch list
* n1n        (current)  model=gpt-5-codex
  dmx                   model=gpt-5-codex-cdx

$ codex-switch dmx
switched to 'dmx'  (model=gpt-5-codex-cdx)
  base_url=https://relay-b.example.com/v1  wire_api=responses  provider=codex
  unified session model to gpt-5-codex-cdx (66 sessions)
tip: reload the VSCode window for the Codex plugin to pick this up.
```

It touches only three things: the top-level `model` and the single
`[model_providers.codex]` `base_url` in `config.toml`, the key in `auth.json`, and
`threads.model` in Codex's state DB. It never touches your session bodies, memories,
or Claude Code.

---

## Why this exists

Naively switching relays by editing `config.toml` breaks in three non-obvious ways.
This tool exists because each of these has a real root cause and a specific fix.

### 1. The `env_key` trap

If you give each relay its own `[model_providers.*]` block with the **same**
`env_key = "OPENAI_API_KEY"`, Codex stops reading `auth.json` and reads **only** the
environment variable. If that env var is pinned in your shell rc to one relay's key,
every other relay fails auth (`401 invalid token`) even though `curl` works fine.

**Fix:** the provider block has **no `env_key`** at all. The key travels in
`auth.json`, which the tool swaps atomically on each switch.

### 2. The plugin filters sessions by provider

The VSCode Codex plugin lists sessions filtered by the *current* `model_provider`
(`ThreadListParams.modelProviders`). If each relay is a different provider key, you
switch relay and your old sessions **vanish** from the list — they reappear only when
you switch back.

**Fix:** all relays share **one fixed provider key, `codex`**. Only the `base_url`
inside that block changes. The session list stays visible across every relay.

### 3. Sessions store their model

Each session pins its model in `state_*.sqlite`'s `threads.model`. When the plugin
resumes an old session it sends that stored model — so resuming a session created on
relay A, while pointed at relay B that doesn't offer that model, returns
`503 model_not_found`.

**Fix:** on switch, the tool rewrites `threads.model` for all sessions to the target
relay's model, so any session resumes cleanly on the current relay. Disable with
`--no-db` if you'd rather keep per-session models.

---

## Install

```bash
git clone <this-repo> codex-switch
cd codex-switch
./install.sh          # copies to ~/.local/bin, ensures PATH
```

Requirements:
- `bash`, `awk`, `sed` (standard on Linux/macOS)
- `sqlite3` — optional, only for the session-model rewrite (feature 3). Missing → skipped with a warning.
- `python3` — optional, used to write/validate `auth.json`. Missing → a `printf`/`grep` fallback is used.

---

## Usage

```bash
codex-switch init              # set up config.toml with the single provider block
codex-switch add n1n           # add a relay (prompts for base_url / model / key)
codex-switch add dmx
codex-switch list              # list profiles, mark current
codex-switch dmx               # switch to relay 'dmx'
codex-switch current           # show current relay
codex-switch model             # list models the current relay offers
codex-switch model gpt-5-codex # switch active model (validated against the relay)
codex-switch rm dmx            # remove a profile
```

`add` prompts for:
- **base_url** — e.g. `https://relay.example.com/v1`
- **model** — the model name this relay serves, e.g. `gpt-5-codex`
- **wire_api** — defaults to `responses` (current Codex requires it)
- **API key** — read silently, stored in `cc-profiles/<name>/auth.json` (mode 600), never echoed

### Switch options

- `--no-db` — do not rewrite session models in the state DB (keep each session's stored model).

### Switching models on a relay

`codex-switch model` lists the models the **current relay** actually serves (live
`/v1/models` fetch), marking the active one with `*`. `codex-switch model <name>`
validates `<name>` against that list (refusing, with the available list, if it's
not there — so you can't accidentally pin a model the relay lacks), then updates
the top-level `model` in `config.toml`, writes the choice back to the current
profile's `meta`, and rewrites session models in the state DB (skip with `--no-db`).

Requires `curl`. Reload the VSCode window afterward.

### After switching in VSCode

Run **Developer: Reload Window** so the Codex plugin (which runs a persistent
`codex app-server`) re-reads `config.toml` and `auth.json`.

---

## How it stores things

```
~/.codex/
  config.toml                  # managed: top model + [model_providers.codex].base_url
  auth.json                    # managed: swapped on switch
  state_*.sqlite               # managed: threads.model rewritten on switch
  cc-profiles/                 # your relay definitions (NEVER commit — has keys)
    n1n/
      meta                     # model= / base_url= / wire_api=
      auth.json                # mode 600
    dmx/
      meta
      auth.json
    .last-backup/              # rolling backups, last 5 of each file kept
```

A `meta` file is plain `key=value`:

```
model=gpt-5-codex
base_url=https://relay.example.com/v1
wire_api=responses
```

`wire_api=` is optional and defaults to `responses`; profiles written by older
versions without it keep working.

---

## FAQ

**Does this touch my Codex sessions or memories?**
No. It only edits `config.toml`, `auth.json`, and the `threads.model` column. Session
bodies (`sessions/**/rollout-*.jsonl`) and memories are never modified.

**Does it affect Claude Code?**
No. It only manages Codex's `~/.codex/`.

**Why is my state DB called `state_5.sqlite` but the tool never hardcodes `5`?**
The numeric suffix is a schema version that changes across Codex upgrades. The tool
globs `state_*.sqlite` and picks the newest, so it survives upgrades.

**A switch says "state DB busy".**
Codex/the plugin had the DB open. The config/auth switch still applied; only the
session-model rewrite was skipped. Reload the window and switch again, or use
`--no-db`.

**Is it safe to commit my profiles?**
No — `cc-profiles/` holds API keys. The included `.gitignore` excludes it. This repo
is pure logic; every user builds their own profiles with `add`.

**The plugin shows my model as "Custom" and I can't pick relay models from its menu.**
The plugin's model menu only lists its built-in whitelist of official names. Relays
often use their own names (suffixes like `-cdx`, `-high`), which aren't on that
whitelist, so the plugin labels them "Custom" — this is cosmetic and doesn't affect
function. To see and switch among the names a relay actually accepts, use
`codex-switch model` / `codex-switch model <name>` instead of the plugin menu.

**The VSCode plugin gives `401 Unauthorized: 未提供令牌 / Invalid token` on a relay, but the CLI works fine on the same relay.**
This is almost certainly **not** a codex-switch problem — it's the codex binary
version. The CLI on your `PATH` and the codex binary **bundled inside the VSCode
`openai.chatgpt` extension** are often different builds, and some prebuilt/alpha
builds fail to attach the `Authorization` header when using apikey auth against a
custom relay `base_url` (so the relay sees no token at all).

Diagnose it in one step — run the *extension's own* binary from the shell against
your live `~/.codex`:

```bash
# find the bundled binary and check its version
ls -d ~/.vscode-server/extensions/openai.chatgpt-*/bin/*/codex   # (path varies by OS/arch)
<that-path> --version                                            # vs: codex --version

# reproduce the plugin's auth path directly
CODEX_HOME=~/.codex <that-path> exec --skip-git-repo-check "say OK"
```

If the bundled binary 401s here while your PATH `codex` succeeds, the bundled build
is the culprit. Confirm the relay/key are actually fine with a raw request:

```bash
curl -sS -X POST "$BASE_URL/responses" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"<model>","input":"hi","stream":false}' -w '\nHTTP %{http_code}\n'
# HTTP 200 with a token, HTTP 401 "未提供令牌" without one → key/relay are fine
```

Fixes: install a different version of the extension (in VSCode: *Extensions →
the gear → Install Another Version*) until its bundled binary authenticates, or point
the extension at a known-good binary via the `chatgpt.cliExecutable` setting. Over
SSH remote, the extension runs on the **remote** host, so you must change the version
on the remote (`~/.vscode-server/extensions/`), not your local machine. Reload the
window afterward. *(Observed: bundled `0.148.0-alpha.21` authenticated; `0.149.0-alpha.4` did not — so newer is not always better here.)*

---

## Compatibility & caveats

- Verified against **Codex 0.144.4** (CLI + `openai.chatgpt` VSCode extension).
- This is a community tool that depends on Codex's internal state DB schema
  (`state_*.sqlite`, `threads` table). A future Codex upgrade may change that schema
  and require adapting the tool.
- `wire_api = "responses"` reflects current Codex; the chat-completions wire API is
  deprecated.

## License

MIT — see [LICENSE](LICENSE).
