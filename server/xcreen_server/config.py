"""Server configuration, token and local setup discovery.

Config is a small JSON file (default ``~/.config/xcreen/server.json``; override with
``XCREEN_SERVER_CONFIG``). The bearer token lives in its own 0600 file next to it.
"""
from __future__ import annotations

import ipaddress
import json
import os
import re
import secrets
import subprocess
import sys
import uuid
from dataclasses import asdict, dataclass, field, fields
from pathlib import Path

DEFAULT_PORT = 8765
REPO_RUNTIME = Path(__file__).resolve().parent.parent.parent / "runtime"


def default_config_path() -> Path:
    if os.environ.get("XCREEN_SERVER_CONFIG"):
        return Path(os.environ["XCREEN_SERVER_CONFIG"]).expanduser()
    base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return base / "xcreen" / "server.json"


def default_data_dir() -> Path:
    if sys.platform == "darwin":
        # Same store the 1.x app used, so a complete install upgrades in place.
        return Path.home() / "Library" / "Application Support" / "xCreen" / "Evidence"
    base = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    return base / "xcreen" / "evidence"


@dataclass
class ServerConfig:
    bind: str = "127.0.0.1"
    port: int = DEFAULT_PORT
    data_dir: str = field(default_factory=lambda: str(default_data_dir()))
    hermes_python: str = ""
    hermes_root: str = ""
    vault: str = ""
    timezone: str = "Europe/Stockholm"
    runtime_dir: str = field(default_factory=lambda: str(REPO_RUNTIME))
    log_dir: str = ""
    path: str = field(default="", repr=False, compare=False)

    EDITABLE = ("hermes_python", "hermes_root", "vault", "timezone")

    @classmethod
    def load(cls, path: str | Path | None = None) -> "ServerConfig":
        target = Path(path) if path else default_config_path()
        values = json.loads(target.read_text()) if target.exists() else {}
        known = {f.name for f in fields(cls)} - {"path"}
        config = cls(**{k: v for k, v in values.items() if k in known})
        config.path = str(target)
        return config

    def save(self) -> None:
        target = Path(self.path or default_config_path())
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        body = {k: v for k, v in asdict(self).items() if k != "path"}
        temporary = target.with_name(f".{target.name}.{uuid.uuid4().hex}")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(body, handle, indent=2)
            handle.write("\n")
        os.replace(temporary, target)
        self.path = str(target)

    @property
    def token_path(self) -> Path:
        return Path(self.path or default_config_path()).with_name("server.token")

    @property
    def state_path(self) -> Path:
        return Path(self.data_dir) / "server-state.json"

    def logs(self) -> Path:
        directory = Path(self.log_dir) if self.log_dir else Path(self.path or default_config_path()).parent / "logs"
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        return directory

    def public(self) -> dict:
        return {"hermes_python": self.hermes_python, "hermes_root": self.hermes_root, "vault": self.vault,
                "timezone": self.timezone, "data_dir": self.data_dir, "bind": self.bind, "port": self.port}

    def validate(self) -> list[str]:
        problems = []
        try:
            address = ipaddress.ip_address(self.bind)
            if address.is_unspecified:
                problems.append("bind must be a specific address (127.0.0.1, a Tailscale or LAN address), not 0.0.0.0/::")
        except ValueError:
            problems.append(f"bind is not an IP address: {self.bind}")
        if not 1 <= int(self.port) <= 65535:
            problems.append("port out of range")
        for name in ("hermes_python", "hermes_root", "vault", "data_dir"):
            value = getattr(self, name)
            if value and not os.path.isabs(value):
                problems.append(f"{name} must be an absolute path")
        return problems


def load_token(config: ServerConfig) -> str:
    path = config.token_path
    info = path.stat()
    if info.st_mode & 0o077:
        raise PermissionError(f"{path} must not be readable by group or others (chmod 600)")
    token = path.read_text().strip()
    if len(token) < 32:
        raise ValueError(f"{path} does not hold a valid token")
    return token


def create_token(config: ServerConfig, *, rotate: bool = False) -> str:
    path = config.token_path
    if path.exists() and not rotate:
        return load_token(config)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    token = secrets.token_urlsafe(32)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(token + "\n")
    os.replace(temporary, path)
    return token


# ── discovery (port of the 1.x Swift LocalSetupDetector) ──────────────────────

def parse_runtime_command(output: bytes | str) -> tuple[str, str] | None:
    """``hermes --print-runtime-command`` prints the exact argv (JSON) the launcher runs."""
    try:
        argv = json.loads(output)
    except ValueError:
        return None
    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
        return None
    python = argv[0]
    match = re.search(r"sys\.path\.insert\(0, '([^']+)'\)", argv[-1])
    if not python.startswith("/") or not match or not match.group(1).startswith("/"):
        return None
    return python, match.group(1)


def hermes_launchers(home: Path | None = None) -> list[str]:
    home = home or Path.home()
    return [str(home / ".local/bin/hermes"), "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes", "/usr/bin/hermes",
            str(home / ".hermes/hermes-agent/.hermes/bin/hermes")]


def detect_hermes(timeout: float = 15) -> tuple[str, str] | None:
    for launcher in hermes_launchers():
        if not os.access(launcher, os.X_OK):
            continue
        try:
            done = subprocess.run([launcher, "--print-runtime-command"], capture_output=True, timeout=timeout, check=False)
        except (OSError, subprocess.TimeoutExpired):
            continue
        found = parse_runtime_command(done.stdout) if done.returncode == 0 else None
        if found and os.access(found[0], os.X_OK) and os.path.isfile(os.path.join(found[1], "tui_gateway", "entry.py")):
            return found
    return None


def parse_obsidian_vaults(data: bytes | str) -> str | None:
    """A vault with a ``Daily/`` folder wins, then the open vault, then the most recent."""
    try:
        vaults = json.loads(data).get("vaults")
    except (ValueError, AttributeError):
        return None
    if not isinstance(vaults, dict):
        return None
    candidates = []
    for entry in vaults.values():
        path = entry.get("path") if isinstance(entry, dict) else None
        if isinstance(path, str) and path.startswith("/") and os.path.isdir(path):
            candidates.append(((os.path.isdir(os.path.join(path, "Daily")), bool(entry.get("open")), float(entry.get("ts") or 0)), path))
    return max(candidates)[1] if candidates else None


def detect_vault(home: Path | None = None) -> str | None:
    env = os.environ.get("OBSIDIAN_VAULT_PATH")
    if env and env.startswith("/") and os.path.isdir(env):
        return env
    home = home or Path.home()
    for listing in (home / "Library/Application Support/obsidian/obsidian.json", home / ".config/obsidian/obsidian.json"):
        try:
            if listing.stat().st_size < 1_000_000:
                found = parse_obsidian_vaults(listing.read_bytes())
                if found:
                    return found
        except OSError:
            continue
    return None


def import_mac_app_settings() -> dict:
    """Reads the 1.x app's preferences (macOS only) so a complete install upgrades in place:
    Hermes paths, vault, session identity, visibility and model default."""
    if sys.platform != "darwin":
        return {}

    def read(key: str) -> str | None:
        try:
            done = subprocess.run(["/usr/bin/defaults", "read", "dev.xcreen.app", key], capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return done.stdout.strip() if done.returncode == 0 else None

    out: dict = {}
    for key, name in (("xcreen.hermes.python", "hermes_python"), ("xcreen.hermes.root", "hermes_root"), ("xcreen.vault.path", "vault")):
        value = read(key)
        if value:
            out[name] = value
    try:
        done = subprocess.run(["/usr/bin/defaults", "export", "dev.xcreen.app", "-"], capture_output=True, timeout=10)
        import plistlib
        plist = plistlib.loads(done.stdout) if done.returncode == 0 else {}
    except Exception:  # noqa: BLE001 - best effort
        plist = {}
    record = plist.get("xcreen.hermes.session.record")
    if isinstance(record, bytes):
        try:
            decoded = json.loads(record)
            out["stored_session_id"] = decoded.get("storedSessionID")
        except ValueError:
            pass
    if "xcreen.hermes.sessionVisible" in plist:
        out["session_visible"] = bool(plist["xcreen.hermes.sessionVisible"])
    provider, model = plist.get("xcreen.hermes.model.provider"), plist.get("xcreen.hermes.model.id")
    if provider and model:
        out["model_default"] = {"provider": provider, "model": model}
    return out


# ── receipts journal migration ────────────────────────────────────────────────

def journal_key(vault_path: str) -> str:
    """Same derivation as runtime/xcreen_tools.py: sha256 of the resolved vault path."""
    import hashlib
    return hashlib.sha256(vault_path.encode()).hexdigest()[:20]


def journal_rows(path: Path) -> int:
    import sqlite3
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        return sum(connection.execute(f"SELECT count(*) FROM {table}").fetchone()[0] for table in ("entries", "batches") if table in tables)
    finally:
        connection.close()


def migrate_journal(hermes_home: Path, old_vault: str | None, new_vault: str, *, old_key: str | None = None) -> tuple[Path, Path]:
    """Copies the receipts journal written for ``old_vault`` (the resolved vault path on the
    machine that wrote it) to the key for ``new_vault`` on this machine. Refuses to replace a
    journal that already holds entries; an empty one is kept as a backup."""
    import shutil
    import time
    directory = hermes_home / "xcreen-receipts"
    source = directory / f"daily-{old_key or journal_key(old_vault or '')}.sqlite3"
    target = directory / f"daily-{journal_key(os.path.realpath(new_vault))}.sqlite3"
    if not source.is_file() or source.is_symlink():
        raise FileNotFoundError(f"no journal for the old vault at {source}")
    if source == target:
        return source, target
    if target.exists():
        if journal_rows(target):
            raise FileExistsError(f"{target} already holds receipts; not overwriting")
        target.rename(target.with_name(target.name + f".empty-{time.strftime('%Y%m%d-%H%M%S')}"))
    temporary = target.with_name(f".{target.name}.copy")
    shutil.copyfile(source, temporary)
    os.chmod(temporary, 0o600)
    os.replace(temporary, target)
    return source, target
