import fcntl
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from migrate_state import migrate


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "Mobile Documents" / "state"
        self.source.mkdir(parents=True)
        self.destination = self.root / "local-state"
        self.config = self.root / "client.json"
        self.config.write_text(json.dumps({"distributed": {"stateDirectory": str(self.source)}}))
        with closing(sqlite3.connect(self.source / "client.sqlite")) as db:
            db.execute("CREATE TABLE state(key TEXT PRIMARY KEY, value BLOB)")
            db.execute("INSERT INTO state VALUES ('state', ?)", (b'{"clientID":"saved","records":[1,2]}',))
            db.commit()

    def test_preserves_identity_checkpoints_credentials_and_source(self):
        credential = self.root / "original-token"
        credential.write_text("secret-test-token")
        config = json.loads(self.config.read_text())
        config["distributed"]["tokenPath"] = str(credential)
        self.config.write_text(json.dumps(config))
        original = self.config.read_bytes()
        migrate(self.config, self.destination)
        for directory in (self.source, self.destination):
            with closing(sqlite3.connect(directory / "client.sqlite")) as db:
                saved = json.loads(db.execute("SELECT value FROM state").fetchone()[0])
                self.assertEqual(saved, {"clientID": "saved", "records": [1, 2]})
        updated = json.loads(self.config.read_text())["distributed"]
        self.assertEqual(updated["stateDirectory"], str(self.destination))
        self.assertEqual(Path(updated["tokenPath"]).read_text(), "secret-test-token")
        self.assertEqual((self.destination / "client.sqlite").stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.destination / "config.before-migration.json").read_bytes(), original)

    def test_refuses_running_source_without_changing_config(self):
        original = self.config.read_bytes()
        with (self.source / "process.lock").open("wb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                migrate(self.config, self.destination)
        self.assertFalse(self.destination.exists())
        self.assertEqual(self.config.read_bytes(), original)

    def test_refuses_existing_destination_and_synced_alias(self):
        self.destination.mkdir()
        with self.assertRaises(FileExistsError):
            migrate(self.config, self.destination)
        alias = self.root / "cloud-alias"
        alias.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(ValueError):
            migrate(self.config, alias / "other")

    def test_missing_credential_leaves_config_unchanged(self):
        config = json.loads(self.config.read_text())
        config["distributed"]["tokenPath"] = str(self.root / "missing")
        self.config.write_text(json.dumps(config))
        original = self.config.read_bytes()
        with self.assertRaises(FileNotFoundError):
            migrate(self.config, self.destination)
        self.assertEqual(self.config.read_bytes(), original)
        self.assertTrue((self.source / "client.sqlite").exists())

    def test_explicit_recovery_of_moved_directory_and_conflict_copy(self):
        conflict = self.source / "client 2.sqlite"
        (self.source / "client.sqlite").rename(conflict)
        config = json.loads(self.config.read_text())
        config["distributed"]["stateDirectory"] = str(self.root / "old-moved-path")
        self.config.write_text(json.dumps(config))
        migrate(self.config, self.destination, self.source, "client 2.sqlite")
        with closing(sqlite3.connect(self.destination / "client.sqlite")) as db:
            self.assertEqual(json.loads(db.execute("SELECT value FROM state").fetchone()[0])["clientID"], "saved")
        self.assertTrue(conflict.exists())

    def test_client_database_cannot_escape_source_directory(self):
        with self.assertRaises(ValueError):
            migrate(self.config, self.destination, client_database="../other.sqlite")
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
