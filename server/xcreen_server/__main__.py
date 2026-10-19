"""``xcreen-server``: run and administer the xCreen server.

    xcreen-server init [--bind ADDR] [--port N] [--vault PATH] [--data-dir PATH] [--import-mac-app]
    xcreen-server serve
    xcreen-server token [--rotate]
    xcreen-server doctor
    xcreen-server config [KEY=VALUE ...]
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import sys
from pathlib import Path

from . import PROTOCOL, VERSION
from .config import ServerConfig, create_token, detect_hermes, detect_vault, import_mac_app_settings, load_token


def _configure_logging(config: ServerConfig, verbose: bool) -> None:
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stderr)]
    logging.basicConfig(level=logging.DEBUG if verbose else logging.INFO, handlers=handlers,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")


def cmd_init(args) -> int:
    config = ServerConfig.load(args.config)
    imported = import_mac_app_settings() if args.import_mac_app else {}
    for key in ("hermes_python", "hermes_root", "vault"):
        if imported.get(key) and not getattr(config, key):
            setattr(config, key, imported[key])
    if not (config.hermes_python and config.hermes_root) and not args.no_detect:
        found = detect_hermes()
        if found:
            config.hermes_python, config.hermes_root = found
    if args.vault is not None:
        config.vault = args.vault
    elif not config.vault and not args.no_detect:
        config.vault = detect_vault() or ""
    if args.bind:
        config.bind = args.bind
    if args.port:
        config.port = args.port
    if args.data_dir:
        config.data_dir = args.data_dir
    if args.runtime_dir:
        config.runtime_dir = args.runtime_dir
    if args.timezone:
        config.timezone = args.timezone
    problems = config.validate()
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 2
    config.save()
    Path(config.data_dir).mkdir(mode=0o700, parents=True, exist_ok=True)
    create_token(config)
    state = {k: imported[k] for k in ("stored_session_id", "session_visible", "model_default") if imported.get(k) is not None}
    if state:
        from .session import StateFile
        existing = StateFile(config.state_path)
        if not existing.get("stored_session_id"):
            existing.set(**state)
    print(json.dumps({"config": config.path, "token_file": str(config.token_path), **config.public()}, indent=2))
    if not (config.hermes_python and config.hermes_root):
        print("Hermes was not found; set it with: xcreen-server config hermes_python=... hermes_root=...", file=sys.stderr)
    return 0


def cmd_token(args) -> int:
    config = ServerConfig.load(args.config)
    print(create_token(config, rotate=args.rotate))
    return 0


def cmd_config(args) -> int:
    config = ServerConfig.load(args.config)
    for assignment in args.assignments:
        key, sep, value = assignment.partition("=")
        if not sep or key not in ("bind", "port", "data_dir", "runtime_dir", "log_dir") + ServerConfig.EDITABLE:
            print(f"unknown setting: {assignment}", file=sys.stderr)
            return 2
        setattr(config, key, int(value) if key == "port" else value)
    if args.assignments:
        problems = config.validate()
        if problems:
            print("\n".join(problems), file=sys.stderr)
            return 2
        config.save()
    print(json.dumps(config.public() | {"config": config.path}, indent=2))
    return 0


def cmd_doctor(args) -> int:
    config = ServerConfig.load(args.config)
    from .images import default_encoder, describe
    checks = []

    def check(name, ok, detail=""):
        checks.append(ok)
        print(f"{'ok  ' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}")

    check("config", Path(config.path).exists(), config.path)
    check("config valid", not config.validate(), "; ".join(config.validate()))
    try:
        load_token(config)
        check("token", True, str(config.token_path))
    except Exception as exc:  # noqa: BLE001
        check("token", False, str(exc))
    check("hermes python", bool(config.hermes_python) and os.access(config.hermes_python, os.X_OK), config.hermes_python or "unset")
    check("hermes root", bool(config.hermes_root) and os.path.isfile(os.path.join(config.hermes_root, "tui_gateway", "entry.py")), config.hermes_root or "unset")
    check("runtime", os.path.isfile(os.path.join(config.runtime_dir, "xcreen_gateway.py")), config.runtime_dir)
    check("vault", not config.vault or os.path.isdir(config.vault), config.vault or "none (note writing disabled)")
    check("data dir", os.path.isdir(config.data_dir) or not os.path.exists(config.data_dir), config.data_dir)
    print(f"info compression: {describe(default_encoder())}")
    print(f"info protocol {PROTOCOL}, server {VERSION}, listening on {config.bind}:{config.port}")
    return 0 if all(checks) else 1


def cmd_serve(args) -> int:
    config = ServerConfig.load(args.config)
    _configure_logging(config, args.verbose)
    problems = config.validate()
    if problems:
        logging.error("invalid config: %s", "; ".join(problems))
        return 2
    token = load_token(config)
    from .api import serve
    from .service import XCreenService

    async def main():
        loop = asyncio.get_running_loop()
        service = XCreenService(config)
        await service.start()
        server = serve(service, loop, token, config.bind, int(config.port))
        logging.info("xcreen-server %s (protocol %d) listening on %s:%s, data %s", VERSION, PROTOCOL, config.bind, config.port, config.data_dir)
        stop = asyncio.Event()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, stop.set)
        await stop.wait()
        logging.info("stopping")
        server.shutdown()
        await service.stop()

    asyncio.run(main())
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="xcreen-server", description="xCreen server")
    parser.add_argument("--config", help="config file (default ~/.config/xcreen/server.json or $XCREEN_SERVER_CONFIG)")
    parser.add_argument("--version", action="version", version=f"xcreen-server {VERSION} (protocol {PROTOCOL})")
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init", help="create or update the config and token")
    init.add_argument("--bind")
    init.add_argument("--port", type=int)
    init.add_argument("--vault")
    init.add_argument("--data-dir")
    init.add_argument("--runtime-dir")
    init.add_argument("--timezone")
    init.add_argument("--import-mac-app", action="store_true", help="import settings and session from the 1.x app (macOS)")
    init.add_argument("--no-detect", action="store_true", help="don't look for Hermes or an Obsidian vault")
    init.set_defaults(func=cmd_init)
    serve = sub.add_parser("serve", help="run the server")
    serve.add_argument("-v", "--verbose", action="store_true")
    serve.set_defaults(func=cmd_serve)
    token = sub.add_parser("token", help="print (or rotate) the bearer token")
    token.add_argument("--rotate", action="store_true")
    token.set_defaults(func=cmd_token)
    doctor = sub.add_parser("doctor", help="check the installation")
    doctor.set_defaults(func=cmd_doctor)
    config = sub.add_parser("config", help="show or change settings")
    config.add_argument("assignments", nargs="*", metavar="KEY=VALUE")
    config.set_defaults(func=cmd_config)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
