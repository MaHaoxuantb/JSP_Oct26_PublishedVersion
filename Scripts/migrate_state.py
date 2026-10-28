#!/usr/bin/env python3
"""Copy stopped distributed state to a new local directory, then update its config.

Uses SQLite's backup API, preserves the source, and never overwrites a destination.
Run on every host separately; process locks cannot exclude a remote sync writer.
"""
import argparse
from contextlib import closing
import fcntl
import json
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile


def require_local(path):
    for part in path.resolve().parts:
        if part in {"Mobile Documents", "CloudStorage", "Dropbox", "OneDrive", "Google Drive"} or part.startswith("OneDrive - "):
            raise ValueError(f"Destination must be outside cloud-synced storage: {path}")


def copy_private(source, destination):
    if source.is_symlink():
        raise ValueError(f"Refusing to copy a state symlink: {source}")
    if source.is_dir():
        destination.mkdir(mode=0o700)
        for child in source.iterdir():
            copy_private(child, destination / child.name)
    else:
        with source.open("rb") as src, destination.open("xb") as dst:
            os.chmod(destination, 0o600)
            shutil.copyfileobj(src, dst)
            dst.flush()
            os.fsync(dst.fileno())


def migrate(config_path, destination, source_directory=None, client_database="client.sqlite"):
    config_path = config_path.resolve()
    destination = destination.expanduser().resolve()
    require_local(destination)
    original = config_path.read_bytes()
    config = json.loads(original)
    settings = config["distributed"]
    source = Path(source_directory or settings["stateDirectory"]).expanduser().resolve()
    if Path(client_database).name != client_database or client_database in {".", "..", "server.sqlite"}:
        raise ValueError("Client database must be a filename within the source directory")
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError("Source and destination must be separate directory trees")
    databases = [(source / name, target) for name, target in
                 ((client_database, "client.sqlite"), ("server.sqlite", "server.sqlite"))
                 if (source / name).is_file()]
    if not databases:
        raise ValueError(f"No client.sqlite or server.sqlite in {source}")
    # Acquire before making any destination or changing configuration.
    with (source / "process.lock").open("a+b") as source_lock:
        fcntl.flock(source_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        destination.mkdir(mode=0o700, parents=True, exist_ok=False)
        with (destination / "process.lock").open("xb") as destination_lock:
            os.chmod(destination / "process.lock", 0o600)
            fcntl.flock(destination_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for path, name in databases:
                target = destination / name
                with target.open("xb"):
                    os.chmod(target, 0o600)
                with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as src, closing(sqlite3.connect(target)) as dst:
                    src.backup(dst)
                    if dst.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                        raise ValueError(f"Migrated database failed integrity check: {target}")
            for path in source.iterdir():
                if path.name in {"workers", "join-token", "server-certificate.pem", "recovery.key", "latest-backup.encrypted"} or path.name.startswith(("replica-", "backup-")):
                    copy_private(path, destination / path.name)
            for field, filename in (("certificatePath", "server-certificate.pem"), ("tokenPath", "join-token")):
                if settings.get(field):
                    path = Path(settings[field]).resolve()
                    target = destination / filename
                    if path != source / filename:
                        if target.exists():
                            raise ValueError(f"Conflicting credential files for {field}; source preserved")
                        copy_private(path, target)
                    settings[field] = str(target)
            copy_private(config_path, destination / "config.before-migration.json")
            settings["stateDirectory"] = str(destination)
            # No configuration change until every database and credential is safe.
            if config_path.read_bytes() != original:
                raise ValueError("Config changed during migration; copied state retained, config untouched")
            descriptor, temporary = tempfile.mkstemp(prefix=".migrate-", dir=config_path.parent)
            try:
                with os.fdopen(descriptor, "w") as handle:
                    json.dump(config, handle, indent=2)
                    handle.write("\n")
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(temporary, config_path)
                directory_fd = os.open(config_path.parent, os.O_RDONLY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
    print(f"Migrated {', '.join(p.name for p, _ in databases)} to {destination}; updated {config_path}.")
    print("Original state preserved. Restart only with the updated config; do not run the old synced copy.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--source-directory", type=Path, help="Actual directory when the configured path was renamed")
    parser.add_argument("--client-database", default="client.sqlite", help="Explicitly select an inspected client conflict copy within the source directory")
    args = parser.parse_args()
    try:
        migrate(args.config, args.destination, args.source_directory, args.client_database)
    except (OSError, ValueError, sqlite3.Error) as error:
        parser.exit(1, f"Migration failed: {error}. Source state is preserved.\n")
