---
name: keychain-secrets
description: Manage local API keys and other secrets for AI agents using macOS Keychain without exposing values in chat, plaintext files, or shell history. Use whenever the user mentions API keys, tokens, credentials, OPENAI_API_KEY, ANTHROPIC_API_KEY, agent environment variables, or asks to store/update/list/annotate/retrieve/export/inject any secret on a Mac — even if the user does not explicitly say "Keychain". Trigger this skill even if the user only describes the goal ("set up an API key for this agent", "inject a token into this script", "save these credentials so I don't have to paste them again"); do not require the user to know the tool name. Also trigger when the user asks how to keep secrets out of `.env` files, shell history, dotfiles, or repo commits on macOS.
allowed-tools: Bash, Read, Write
metadata:
  short-description: Manage agent secrets via macOS Keychain
  compatibility: macOS 13+ (requires `/usr/bin/security` and Python 3.9+); the native release app needs no Python; source builds require Xcode Command Line Tools
---

# Clinklet (Keychain Secrets CLI)

Use this skill to manage local secrets for agent workflows. The durable secret value must live in macOS Keychain; metadata such as env var name and notes may live in the skill index.

## Safety Rules

- Never paste secret values into the conversation.
- Prefer `run` to inject secrets into a subprocess environment without printing them.
- If a user asks to view a secret, warn that it will print locally and use `get --show`; do not repeat the value in the final answer.
- Do not store secret values in repo files, notes, logs, generated reports, or shell snippets shown in the chat.
- Use `put --prompt` or `put --stdin` instead of putting secrets directly in shell commands.

## Tool

Use the bundled script:

```bash
python scripts/keychain_secrets.py --help
```

The script stores values in macOS Keychain and keeps a plaintext metadata index at:

```text
~/Library/Application Support/KeychainSecrets/index.json
```

The index does not contain secret values.

## Repository Layout

- `scripts/keychain_secrets.py` — the CLI entry point. Wraps `/usr/bin/security` for Keychain reads/writes and serves the optional web UI.
- `scripts/install_macos_app.sh` — builds and installs the native `Clinklet.app` bundle. Invoked by `keychain_secrets.py app`.
- `macos/KeychainSecretsApp.m` — source for the native macOS app (Cocoa). Uses `SecretStore.m` and Security.framework directly; no Python is needed by the desktop app. The CLI uses the same Keychain item identity and metadata schema.
- `agents/openai.yaml` — agent-interface manifest. Declares the skill's display name, short description, default prompt, and invocation policy so Codex / OpenAI-Agent-style runtimes can discover and auto-invoke the skill. Not needed for Claude Code, which reads the frontmatter of this file.
- `docs/` — documentation assets (screenshots, etc.) referenced by `README.md`.
- No `package.json` exists. This skill is pure Python (stdlib only) plus an Objective-C app; there are no npm or pip dependencies to install.

## Common Workflows

### Basic operations — manage entries

Store or update a secret:

```bash
python scripts/keychain_secrets.py put OPENAI_API_KEY \
  --prompt \
  --note "OpenAI API key for Codex and Harbor evals"
```

Why `--prompt`: reads the secret interactively via `getpass`, so the value never appears in shell history, `ps` output, or the chat transcript. Use `--stdin` for non-interactive pipelines (e.g. piping from another secret manager) and avoid `--value VALUE` for anything you would not paste into chat — that form puts the secret on the command line.

List managed secrets and notes:

```bash
python scripts/keychain_secrets.py list
```

Why: prints only metadata (name, env var, service, note), never values. Safe to run with the chat visible and a good first step before any other operation.

Show metadata for one secret:

```bash
python scripts/keychain_secrets.py info OPENAI_API_KEY
```

Why: same safety guarantee as `list`, scoped to one entry. Use before `put` to confirm the existing service/account before overwriting.

Delete a managed secret from Keychain and remove its metadata:

```bash
python scripts/keychain_secrets.py delete OPENAI_API_KEY
```

Why: removes both the Keychain item and the index entry in one step so the two cannot drift.

### Injection and running — use a secret without revealing it

Run a command with one or more secrets injected as environment variables:

```bash
python scripts/keychain_secrets.py run OPENAI_API_KEY -- python3 your_script.py
```

Why this is the preferred form: the secret is fetched from Keychain and handed directly to the child process's environment. It never appears on the command line, in shell history, or in this chat — only the child process sees it. Reach for this whenever the goal is "let this command see the key".

Export a shell command locally. **This prints the secret to the terminal**, so do not paste its output into chat:

```bash
python scripts/keychain_secrets.py export OPENAI_API_KEY
```

Why an explicit `export` exists at all: occasionally a long-running shell session legitimately needs the value (e.g. `eval "$(... export X)"` at the top of a script). Prefer `run` whenever the consumer is a single command.

Print a secret to stdout (refuses unless `--show` is given):

```bash
python scripts/keychain_secrets.py get OPENAI_API_KEY --show
```

Why the `--show` gate: by default `get` refuses to print, so an accidental `get` cannot leak the value. The flag is a deliberate confirmation that the caller has a local-only use for the plaintext.

### Debug and UI tools — human-facing helpers

Install and open the native macOS app for configuring names, env vars, notes, and Keychain values without running a localhost service:

```bash
python scripts/keychain_secrets.py app
```

Why prefer the native app over the web UI: no localhost port, no background service, and Keychain access happens in the app's own process so macOS prompts the user with a recognizable bundle name. The app is installed at:

```text
~/Applications/Clinklet.app
```

You can open it later from Finder, Spotlight, or:

```bash
open "$HOME/Applications/Clinklet.app"
```

Start the legacy local web UI when a browser-based fallback is useful:

```bash
python scripts/keychain_secrets.py open
```

Why this is a fallback: it binds to `127.0.0.1:8765` and is convenient when you want to manage entries from a browser, but it requires a localhost service. Stop it with `stop` when you are done.

```text
http://127.0.0.1:8765
```

In the web UI, use `Edit` on a row to load its metadata into the form. Leave the secret field blank to update only env var name and note; provide the secret again when changing Keychain service or account.

Stop the local web UI:

```bash
python scripts/keychain_secrets.py stop
```

Why: shuts down the launchd job started by `open`/`launch` so the localhost service is not left running.

## Notes

- `security add-generic-password` without `-U` does not update an existing item. The script uses `-U`.
- Keychain values do not automatically become environment variables. Use `run` or evaluate the local `export` output in a shell.
- The default Keychain `service` and injected env var name are both the provided name, for example `OPENAI_API_KEY`.
- `app` installs and opens a native macOS app; no localhost service is involved.
- `open` starts the web UI only when needed and opens it. `launch` starts the web UI through a user-level `launchctl` job; `serve` runs it in the foreground for debugging.
- The web UI binds to `127.0.0.1` by default and never renders secret values back into the page.
