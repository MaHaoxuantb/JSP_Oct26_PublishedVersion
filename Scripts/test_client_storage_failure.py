"""Exercise the built client so a local failure cannot regress into network retries."""
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import unittest
import uuid


EXECUTABLE = Path(os.environ.get("PUZZLE_TEST_EXECUTABLE", Path(__file__).resolve().parents[1] / ".build/release/janestreet-puzzle"))


@unittest.skipUnless(EXECUTABLE.is_file(), "Build the release executable first")
class ClientStorageFailureTests(unittest.TestCase):
    def test_live_database_move_stops_client(self):
        with tempfile.TemporaryDirectory(prefix="puzzle-runtime-failure-") as folder:
            root = Path(folder).resolve()
            settings = {
                "stateDirectory": str(root), "address": "127.0.0.1", "port": 65534,
                # A missing pin simulates an offline coordinator before any socket
                # is opened, keeping this regression independent of the network.
                "certificatePath": str(root / "missing-certificate.pem"),
                "tokenPath": str(root / "join-token"), "clientWorkers": 1,
                "checkpointSeconds": 1, "calibrationSeconds": 0.05,
            }
            config = {"distributed": settings, "pathEvaluation": "cpu",
                      "rowNum": 1, "colNum": 1, "Target": {"Status": [[1]]}}
            (root / "join-token").write_text("t" * 32)
            (root / "client.json").write_text(json.dumps(config))
            disk = {"clientID": str(uuid.uuid4()), "runID": str(uuid.uuid4()),
                    "config": config, "records": []}
            with closing(sqlite3.connect(root / "client.sqlite")) as db:
                db.execute("CREATE TABLE state(key TEXT PRIMARY KEY,value BLOB NOT NULL)")
                db.execute("INSERT INTO state VALUES (?,?)", ("state", json.dumps(disk).encode()))
                db.commit()
            output_path = root / "output.log"
            with output_path.open("wb") as output:
                process = subprocess.Popen([str(EXECUTABLE), "--client", "--config", str(root / "client.json")],
                                           stdout=output, stderr=subprocess.STDOUT)
                try:
                    until = time.monotonic() + 15
                    while "Coordinator unavailable:" not in output_path.read_text() and process.poll() is None and time.monotonic() < until:
                        time.sleep(0.02)
                    self.assertIn("Coordinator unavailable:", output_path.read_text())
                    (root / "client.sqlite").rename(root / "moved.sqlite")
                    self.assertEqual(process.wait(timeout=15), 1)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
            text = output_path.read_text()
            self.assertIn("Solver failed: State database", text)
            self.assertIn("moved or replaced", text)
            self.assertNotIn("Coordinator unavailable: State database", text)
            self.assertEqual(text.count("Coordinator unavailable:"), 1)


if __name__ == "__main__":
    unittest.main()
