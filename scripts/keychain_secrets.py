#!/usr/bin/env python3
from __future__ import annotations

import argparse
import getpass
import html
import http.server
import json
import os
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse
from urllib.request import urlopen


def _resolve_index_path() -> Path:
    override = os.environ.get("KEYCHAIN_SECRETS_INDEX_PATH")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "KeychainSecrets" / "index.json"


LEGACY_INDEX_PATHS = [
    Path.home() / ".codex" / "keychain-secrets" / "index.json",
]
INDEX_PATH = _resolve_index_path()
LAUNCH_LABEL = "io.github.zpzjzj.keychain-secrets"
DEFAULT_KEYCHAIN = Path.home() / "Library" / "Keychains" / "login.keychain-db"
MACOS_APP_PATH = Path.home() / "Applications" / "Clinklet.app"


def _migrate_legacy_index() -> None:
    if INDEX_PATH.exists():
        return
    for legacy in LEGACY_INDEX_PATHS:
        if legacy.exists():
            INDEX_PATH.parent.mkdir(parents=True, exist_ok=True)
            INDEX_PATH.write_bytes(legacy.read_bytes())
            try:
                INDEX_PATH.chmod(0o600)
            except OSError:
                pass
            print(
                f"[keychain-secrets] migrated metadata index: {legacy} -> {INDEX_PATH}",
                file=sys.stderr,
            )
            return


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def load_index() -> dict[str, dict[str, str]]:
    _migrate_legacy_index()
    if not INDEX_PATH.exists():
        return {}
    return json.loads(INDEX_PATH.read_text())


def save_index(index: dict[str, dict[str, str]]) -> None:
    INDEX_PATH.parent.mkdir(parents=True, exist_ok=True)
    INDEX_PATH.write_text(json.dumps(index, indent=2, sort_keys=True) + "\n")
    INDEX_PATH.chmod(0o600)


def run_security(args: list[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/usr/bin/security", *args],
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def account(args: argparse.Namespace) -> str:
    return args.account or os.environ.get("USER") or getpass.getuser()


def keychain_path(args: argparse.Namespace | None = None) -> str:
    value = getattr(args, "keychain", None) if args else None
    return value or str(DEFAULT_KEYCHAIN)


def service_from_entry(name: str, index: dict[str, dict[str, str]], args: argparse.Namespace) -> str:
    if getattr(args, "service", None):
        return args.service
    return index.get(name, {}).get("service", name)


def keychain_from_entry(name: str, index: dict[str, dict[str, str]], args: argparse.Namespace) -> str:
    if getattr(args, "keychain", None):
        return args.keychain
    return index.get(name, {}).get("keychain", keychain_path(args))


def account_from_entry(name: str, index: dict[str, dict[str, str]], args: argparse.Namespace) -> str:
    if getattr(args, "account", None):
        return args.account
    return index.get(name, {}).get("account", account(args))


def read_secret(args: argparse.Namespace) -> str:
    if args.stdin:
        value = sys.stdin.read()
        return value[:-1] if value.endswith("\n") else value
    if args.prompt:
        return getpass.getpass(f"Secret value for {args.name}: ")
    if args.value is not None:
        return args.value
    raise SystemExit("Provide one of --prompt, --stdin, or --value.")


def store_secret(
    *,
    name: str,
    value: str,
    service: str | None,
    acct: str,
    env_name: str | None,
    note: str | None,
    keychain: str | None = None,
) -> None:
    index = load_index()
    resolved_service = service or name

    security_args = [
        "add-generic-password",
        "-U",
        "-a",
        acct,
        "-s",
        resolved_service,
        "-l",
        name,
        "-D",
        "application password",
        "-w",
        value,
    ]
    if note:
        security_args.extend(["-j", note])
    security_args.append(keychain or keychain_path())
    run_security(security_args)

    previous = index.get(name, {})
    index[name] = {
        "service": resolved_service,
        "account": acct,
        "env": env_name or previous.get("env") or name,
        "keychain": keychain or previous.get("keychain") or keychain_path(),
        "note": note if note is not None else previous.get("note", ""),
        "updated_at": now(),
    }
    save_index(index)


def update_secret_metadata(
    *,
    name: str,
    service: str | None,
    acct: str,
    env_name: str | None,
    note: str | None,
    keychain: str | None = None,
) -> None:
    index = load_index()
    previous = index.get(name)
    if previous is None:
        raise ValueError("secret value is required for a new entry")

    resolved_service = service or previous.get("service") or name
    resolved_keychain = keychain or previous.get("keychain") or keychain_path()
    identity_changed = (
        resolved_service != previous.get("service", name)
        or acct != previous.get("account", account(argparse.Namespace(account=None)))
        or resolved_keychain != previous.get("keychain", keychain_path())
    )
    if identity_changed:
        raise ValueError("secret value is required when changing service, account, or keychain")

    index[name] = {
        "service": resolved_service,
        "account": acct,
        "env": env_name or previous.get("env") or name,
        "keychain": resolved_keychain,
        "note": note if note is not None else previous.get("note", ""),
        "updated_at": now(),
    }
    save_index(index)


def cmd_put(args: argparse.Namespace) -> None:
    acct = account(args)
    value = read_secret(args)
    store_secret(
        name=args.name,
        value=value,
        service=args.service,
        acct=acct,
        env_name=args.env,
        note=args.note,
        keychain=keychain_path(args),
    )
    service = args.service or args.name
    print(f"Stored {args.name} in macOS Keychain service={service!r} account={acct!r}.")


def get_secret(name: str, index: dict[str, dict[str, str]], args: argparse.Namespace) -> str:
    service = service_from_entry(name, index, args)
    acct = account_from_entry(name, index, args)
    keychain = keychain_from_entry(name, index, args)
    result = run_security(["find-generic-password", "-a", acct, "-s", service, "-w", keychain], capture=True)
    return result.stdout.rstrip("\n")


def cmd_get(args: argparse.Namespace) -> None:
    if not args.show:
        raise SystemExit("Refusing to print a secret by default. Re-run with --show to print locally.")
    index = load_index()
    print(get_secret(args.name, index, args))


def cmd_export(args: argparse.Namespace) -> None:
    index = load_index()
    secret = get_secret(args.name, index, args)
    env_name = args.env or index.get(args.name, {}).get("env") or args.name
    print(f"export {env_name}={shlex.quote(secret)}")


def cmd_run(args: argparse.Namespace) -> None:
    index = load_index()
    env = os.environ.copy()
    if "--" not in args.items:
        raise SystemExit("Use: run NAME [NAME ...] -- COMMAND [ARG ...]")
    separator = args.items.index("--")
    names = args.items[:separator]
    command = args.items[separator + 1 :]
    if not names or not command:
        raise SystemExit("Use: run NAME [NAME ...] -- COMMAND [ARG ...]")
    for name in names:
        entry = index.get(name, {})
        env_name = entry.get("env") or name
        env[env_name] = get_secret(name, index, args)
    completed = subprocess.run(command, env=env)
    raise SystemExit(completed.returncode)


def cmd_list(_: argparse.Namespace) -> None:
    index = load_index()
    if not index:
        print("No managed secrets.")
        return
    for name, entry in sorted(index.items()):
        note = entry.get("note", "")
        suffix = f" - {note}" if note else ""
        print(
            f"{name}\tenv={entry.get('env', name)}\tservice={entry.get('service', name)}"
            f"\taccount={entry.get('account', '')}\tkeychain={entry.get('keychain', keychain_path())}"
            f"\tupdated={entry.get('updated_at', '')}{suffix}"
        )


def cmd_info(args: argparse.Namespace) -> None:
    index = load_index()
    entry = index.get(args.name)
    if not entry:
        raise SystemExit(f"{args.name} is not in the managed metadata index.")
    print(json.dumps({args.name: entry}, indent=2, sort_keys=True))


def cmd_names(_: argparse.Namespace) -> None:
    for name in sorted(load_index()):
        print(name)


def cmd_field(args: argparse.Namespace) -> None:
    index = load_index()
    entry = index.get(args.name)
    if entry is None:
        raise SystemExit(f"{args.name} is not in the managed metadata index.")
    if args.field == "name":
        print(args.name)
        return
    print(entry.get(args.field, ""))


def cmd_update(args: argparse.Namespace) -> None:
    index = load_index()
    previous = index.get(args.name)
    if previous is None:
        raise SystemExit(f"{args.name} is not in the managed metadata index.")
    update_secret_metadata(
        name=args.name,
        service=args.service if args.service is not None else previous.get("service", args.name),
        acct=args.account if args.account is not None else previous.get("account", account(args)),
        env_name=args.env if args.env is not None else previous.get("env", args.name),
        note=args.note if args.note is not None else previous.get("note", ""),
        keychain=args.keychain if args.keychain is not None else previous.get("keychain", keychain_path(args)),
    )
    print(f"Updated {args.name}.")


def cmd_delete(args: argparse.Namespace) -> None:
    index = load_index()
    service = service_from_entry(args.name, index, args)
    acct = account_from_entry(args.name, index, args)
    keychain = keychain_from_entry(args.name, index, args)
    run_security(["delete-generic-password", "-a", acct, "-s", service, keychain], capture=True)
    index.pop(args.name, None)
    save_index(index)
    print(f"Deleted {args.name} from Keychain service={service!r} account={acct!r}.")


def html_escape(value: str) -> str:
    return html.escape(value, quote=True)


def command_for(name: str, entry: dict[str, str]) -> str:
    script = Path(__file__).resolve()
    return f"{shlex.quote(str(script))} run {shlex.quote(name)} -- <command>"


def render_page(message: str = "", edit_name: str | None = None) -> str:
    index = load_index()
    edit_entry = index.get(edit_name or "") if edit_name else None
    form_name = edit_name or ""
    form_env = edit_entry.get("env", edit_name) if edit_entry else ""
    form_service = edit_entry.get("service", edit_name) if edit_entry else ""
    form_account = edit_entry.get("account", "") if edit_entry else ""
    form_note = edit_entry.get("note", "") if edit_entry else ""
    editing = edit_entry is not None and edit_name is not None
    rows = []
    for name, entry in sorted(index.items()):
        rows.append(
            "<tr>"
            f"<td><code>{html_escape(name)}</code></td>"
            f"<td><code>{html_escape(entry.get('env', name))}</code></td>"
            f"<td>{html_escape(entry.get('service', name))}</td>"
            f"<td>{html_escape(entry.get('account', ''))}</td>"
            f"<td>{html_escape(entry.get('note', ''))}</td>"
            f"<td>{html_escape(entry.get('updated_at', ''))}</td>"
            "<td>"
            f"<code>{html_escape(command_for(name, entry))}</code>"
            "<div class='actions'>"
            f"<a class='button' href='/?edit={quote(name)}'>Edit</a>"
            f"<form method='post' action='/delete' onsubmit='return confirm(\"Delete {html_escape(name)}?\")'>"
            f"<input type='hidden' name='name' value='{html_escape(name)}'>"
            "<button type='submit'>Delete</button>"
            "</form>"
            "</div>"
            "</td>"
            "</tr>"
        )
    table_body = "\n".join(rows) or "<tr><td colspan='7'>No managed secrets.</td></tr>"
    escaped_message = html_escape(message)
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Keychain Secrets</title>
  <style>
    :root {{
      color-scheme: light dark;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      line-height: 1.4;
    }}
    body {{ margin: 0; background: Canvas; color: CanvasText; }}
    main {{ max-width: 1120px; margin: 0 auto; padding: 28px; }}
    h1 {{ font-size: 24px; margin: 0 0 18px; }}
    h2 {{ font-size: 18px; margin: 28px 0 12px; }}
    form.panel {{
      display: grid;
      grid-template-columns: repeat(2, minmax(240px, 1fr));
      gap: 14px 18px;
      padding: 18px;
      border: 1px solid color-mix(in srgb, CanvasText 18%, transparent);
      border-radius: 8px;
    }}
    label {{ display: grid; gap: 6px; font-weight: 600; font-size: 13px; }}
    input, textarea {{
      font: inherit;
      padding: 9px 10px;
      border: 1px solid color-mix(in srgb, CanvasText 22%, transparent);
      border-radius: 6px;
      background: Canvas;
      color: CanvasText;
    }}
    textarea {{ min-height: 72px; resize: vertical; }}
    .full {{ grid-column: 1 / -1; }}
    button {{
      width: fit-content;
      padding: 8px 12px;
      border: 1px solid color-mix(in srgb, CanvasText 26%, transparent);
      border-radius: 6px;
      background: ButtonFace;
      color: ButtonText;
      cursor: pointer;
    }}
    a.button {{
      display: inline-block;
      width: fit-content;
      padding: 8px 12px;
      border: 1px solid color-mix(in srgb, CanvasText 26%, transparent);
      border-radius: 6px;
      background: ButtonFace;
      color: ButtonText;
      text-decoration: none;
    }}
    .actions {{ display: flex; gap: 8px; align-items: center; margin-top: 8px; }}
    .actions form {{ margin: 0; }}
    table {{ width: 100%; border-collapse: collapse; font-size: 13px; }}
    th, td {{ text-align: left; vertical-align: top; border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent); padding: 10px 8px; }}
    th {{ font-weight: 700; }}
    code {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; overflow-wrap: anywhere; }}
    .message {{ margin: 0 0 16px; padding: 10px 12px; border-radius: 6px; background: color-mix(in srgb, CanvasText 8%, transparent); }}
    .hint {{ color: color-mix(in srgb, CanvasText 72%, transparent); font-size: 13px; }}
  </style>
</head>
<body>
  <main>
    <h1>Keychain Secrets</h1>
    {f"<p class='message'>{escaped_message}</p>" if message else ""}
    <form class="panel" method="post" action="/put" autocomplete="off">
      {f"<input type='hidden' name='editing' value='{html_escape(edit_name or '')}'>" if editing else ""}
      <label>Name
        <input name="name" placeholder="OPENAI_API_KEY" value="{html_escape(form_name)}" {"readonly" if editing else ""} required>
      </label>
      <label>Environment variable
        <input name="env" placeholder="OPENAI_API_KEY" value="{html_escape(form_env)}">
      </label>
      <label>Keychain service
        <input name="service" placeholder="Defaults to name" value="{html_escape(form_service)}">
      </label>
      <label>Keychain account
        <input name="account" placeholder="{html_escape(os.environ.get("USER") or getpass.getuser())}" value="{html_escape(form_account)}">
      </label>
      <label class="full">Secret value
        <input name="secret" type="password" {"placeholder='Leave blank to keep the existing secret'" if editing else "required"}>
      </label>
      <label class="full">Note
        <textarea name="note" placeholder="What this key is for">{html_escape(form_note)}</textarea>
      </label>
      <div class="full">
        <button type="submit">{"Update" if editing else "Store or Update"}</button>
        {f"<a class='button' href='/'>New</a>" if editing else ""}
        <p class="hint">Secret values are sent only to this localhost process, stored in macOS Keychain, and not written to the metadata index. Editing an existing entry can leave the secret blank unless service or account changes.</p>
      </div>
    </form>
    <h2>Managed Secrets</h2>
    <table>
      <thead>
        <tr><th>Name</th><th>Env</th><th>Service</th><th>Account</th><th>Note</th><th>Updated</th><th>Use</th></tr>
      </thead>
      <tbody>{table_body}</tbody>
    </table>
  </main>
</body>
</html>"""


def redirect(location: str) -> None:
    raise RuntimeError(location)


class SecretPageHandler(http.server.BaseHTTPRequestHandler):
    server_version = "KeychainSecrets/1.0"

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path != "/":
            self.send_error(404)
            return
        query = parse_qs(parsed.query)
        edit_name = query.get("edit", [None])[0]
        self.send_html(render_page(edit_name=edit_name))

    def do_POST(self) -> None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode()
            form = {key: values[0] for key, values in parse_qs(body, keep_blank_values=True).items()}
            if self.path == "/put":
                self.handle_put(form)
            elif self.path == "/delete":
                self.handle_delete(form)
            else:
                self.send_error(404)
        except Exception as exc:
            self.send_html(render_page(f"Error: {exc}"), status=500)

    def handle_put(self, form: dict[str, str]) -> None:
        name = form.get("name", "").strip()
        secret = form.get("secret", "")
        if not name:
            raise ValueError("name is required")
        acct = form.get("account", "").strip() or os.environ.get("USER") or getpass.getuser()
        service = form.get("service", "").strip() or None
        env_name = form.get("env", "").strip() or None
        note = form.get("note", "")
        if secret:
            store_secret(
                name=name,
                value=secret,
                service=service,
                acct=acct,
                env_name=env_name,
                note=note,
                keychain=keychain_path(),
            )
            self.send_html(render_page(f"Stored {name}.", edit_name=name))
            return
        update_secret_metadata(
            name=name,
            service=service,
            acct=acct,
            env_name=env_name,
            note=note,
            keychain=keychain_path(),
        )
        self.send_html(render_page(f"Updated {name}.", edit_name=name))

    def handle_delete(self, form: dict[str, str]) -> None:
        name = form.get("name", "").strip()
        if not name:
            raise ValueError("name is required")
        args = argparse.Namespace(name=name, account=None, service=None)
        cmd_delete(args)
        self.send_html(render_page(f"Deleted {name}."))

    def send_html(self, body: str, *, status: int = 200) -> None:
        encoded = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, format: str, *args: object) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))


def cmd_serve(args: argparse.Namespace) -> None:
    address = (args.host, args.port)
    httpd = http.server.ThreadingHTTPServer(address, SecretPageHandler)
    host, port = httpd.server_address
    print(f"Serving Keychain Secrets UI at http://{host}:{port}")
    httpd.serve_forever()


def cmd_launch(args: argparse.Namespace) -> None:
    subprocess.run(["/bin/launchctl", "remove", LAUNCH_LABEL], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(
        [
            "/bin/launchctl",
            "submit",
            "-l",
            LAUNCH_LABEL,
            "--",
            str(Path(__file__).resolve()),
            "serve",
            "--host",
            args.host,
            "--port",
            str(args.port),
        ],
        check=True,
    )
    print(f"Launched Keychain Secrets UI at http://{args.host}:{args.port}")


def ui_url(host: str, port: int) -> str:
    return f"http://{host}:{port}"


def ui_is_up(host: str, port: int) -> bool:
    try:
        with urlopen(ui_url(host, port), timeout=0.5) as response:
            return response.status == 200
    except Exception:
        return False


def ensure_ui(host: str, port: int) -> None:
    if ui_is_up(host, port):
        return
    cmd_launch(argparse.Namespace(host=host, port=port))
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if ui_is_up(host, port):
            return
        time.sleep(0.1)
    raise RuntimeError(f"UI did not become available at {ui_url(host, port)}")


def cmd_open(args: argparse.Namespace) -> None:
    ensure_ui(args.host, args.port)
    url = ui_url(args.host, args.port)
    subprocess.run(["/usr/bin/open", url], check=False)
    print(url)


def skill_root() -> Path:
    return Path(__file__).resolve().parents[1]


def cmd_install_app(_: argparse.Namespace) -> None:
    installer = skill_root() / "scripts" / "install_macos_app.sh"
    completed = subprocess.run([str(installer)], check=True, text=True, stdout=subprocess.PIPE)
    print(completed.stdout.strip())


def cmd_app(_: argparse.Namespace) -> None:
    candidates = [MACOS_APP_PATH, Path("/Applications/Clinklet.app"),
                  Path.home() / "Applications/KeychainSecrets.app", Path("/Applications/KeychainSecrets.app")]
    app_path = next((path for path in candidates if path.exists()), None)
    if app_path is None:
        cmd_install_app(argparse.Namespace())
        app_path = MACOS_APP_PATH
    subprocess.run(["/usr/bin/open", str(app_path)], check=False)
    print(str(app_path))


def cmd_stop(_: argparse.Namespace) -> None:
    subprocess.run(["/bin/launchctl", "remove", LAUNCH_LABEL], check=False)
    print("Stopped Keychain Secrets UI.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manage agent secrets in macOS Keychain.")
    subparsers = parser.add_subparsers(dest="command_name", required=True)

    put = subparsers.add_parser("put", help="Store or update a secret.")
    put.add_argument("name", help="Logical name, usually an env var such as OPENAI_API_KEY.")
    put.add_argument("--account", help="Keychain account. Defaults to $USER.")
    put.add_argument("--service", help="Keychain service. Defaults to name.")
    put.add_argument("--keychain", help="Keychain file. Defaults to login.keychain-db.")
    put.add_argument("--env", help="Environment variable to inject. Defaults to name.")
    put.add_argument("--note", help="Human-readable note stored only as metadata/comment.")
    source = put.add_mutually_exclusive_group(required=True)
    source.add_argument("--prompt", action="store_true", help="Prompt locally for the secret.")
    source.add_argument("--stdin", action="store_true", help="Read the secret from stdin.")
    source.add_argument("--value", help="Secret value. Avoid this because shells may log it.")
    put.set_defaults(func=cmd_put)

    get = subparsers.add_parser("get", help="Print a secret locally only when --show is present.")
    get.add_argument("name")
    get.add_argument("--account")
    get.add_argument("--service")
    get.add_argument("--keychain")
    get.add_argument("--show", action="store_true")
    get.set_defaults(func=cmd_get)

    export = subparsers.add_parser("export", help="Print a shell export command locally.")
    export.add_argument("name")
    export.add_argument("--account")
    export.add_argument("--service")
    export.add_argument("--keychain")
    export.add_argument("--env")
    export.set_defaults(func=cmd_export)

    run = subparsers.add_parser("run", help="Run a command with secrets injected into env.")
    run.add_argument("items", nargs=argparse.REMAINDER, help="NAME [NAME ...] -- COMMAND [ARG ...]")
    run.add_argument("--account")
    run.add_argument("--service")
    run.add_argument("--keychain")
    run.set_defaults(func=cmd_run)

    list_cmd = subparsers.add_parser("list", help="List managed secret metadata.")
    list_cmd.set_defaults(func=cmd_list)

    info = subparsers.add_parser("info", help="Show metadata for one secret.")
    info.add_argument("name")
    info.set_defaults(func=cmd_info)

    names = subparsers.add_parser("names", help="List managed secret names.")
    names.set_defaults(func=cmd_names)

    field = subparsers.add_parser("field", help="Print one metadata field for a secret.")
    field.add_argument("name")
    field.add_argument("field", choices=["name", "env", "service", "account", "keychain", "note", "updated_at"])
    field.set_defaults(func=cmd_field)

    update = subparsers.add_parser("update", help="Update metadata without changing the secret value.")
    update.add_argument("name")
    update.add_argument("--account")
    update.add_argument("--service")
    update.add_argument("--keychain")
    update.add_argument("--env")
    update.add_argument("--note")
    update.set_defaults(func=cmd_update)

    delete = subparsers.add_parser("delete", help="Delete a secret and its metadata.")
    delete.add_argument("name")
    delete.add_argument("--account")
    delete.add_argument("--service")
    delete.add_argument("--keychain")
    delete.set_defaults(func=cmd_delete)

    serve = subparsers.add_parser("serve", help="Start a localhost web UI.")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8765)
    serve.set_defaults(func=cmd_serve)

    launch = subparsers.add_parser("launch", help="Start the localhost web UI via launchctl.")
    launch.add_argument("--host", default="127.0.0.1")
    launch.add_argument("--port", type=int, default=8765)
    launch.set_defaults(func=cmd_launch)

    open_cmd = subparsers.add_parser("open", help="Start the web UI if needed and open it.")
    open_cmd.add_argument("--host", default="127.0.0.1")
    open_cmd.add_argument("--port", type=int, default=8765)
    open_cmd.set_defaults(func=cmd_open)

    install_app = subparsers.add_parser("install-app", help="Build and install the native macOS app.")
    install_app.set_defaults(func=cmd_install_app)

    app_cmd = subparsers.add_parser("app", help="Install if needed and open the native macOS app.")
    app_cmd.set_defaults(func=cmd_app)

    stop = subparsers.add_parser("stop", help="Stop the launchctl web UI job.")
    stop.set_defaults(func=cmd_stop)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
