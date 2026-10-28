"""Real CLI recovery against a temporary coordinator, never the production server."""
from contextlib import closing
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import time
import unittest
import uuid

EXECUTABLE = Path(os.environ.get("PUZZLE_TEST_EXECUTABLE", Path(__file__).resolve().parents[1] / ".build/release/janestreet-puzzle"))


@unittest.skipUnless(EXECUTABLE.is_file(), "Build the release executable first")
class ClientProgressProcessTests(unittest.TestCase):
    def exercise_recovery(self, budget, accepted, local):
        with tempfile.TemporaryDirectory(prefix="client-budget-") as folder:
            root = Path(folder).resolve()
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            server_dir = root / "server"
            client_dir = root / "client"
            server_dir.mkdir(); client_dir.mkdir()
            token = "t" * 32
            (server_dir / "join-token").write_text(token)
            settings = {"address": "127.0.0.1", "port": port, "webUIEnabled": False,
                        "machineName": "Test Coordinator",
                        "clientWorkers": 1, "heartbeatSeconds": 0.1, "checkpointSeconds": 0.01,
                        "jobSeconds": 0.000001, "calibrationSeconds": 0.01,
                        "stateDirectory": str(server_dir)}
            config = {"rowNum": 1, "colNum": 1, "Target": {"Status": [[1]]},
                      "pathEvaluation": "cpu", "distributed": settings}
            run = str(uuid.uuid4()); client = str(uuid.uuid4())
            progress = lambda count: {"current": [0], "best": [0], "iterations": count,
                                      "seconds": 1, "finished": False, "solved": False}
            job = {"id": str(uuid.uuid4()), "generation": 1, "ordinal": 1, "slot": 0,
                   "seed": 1, "objective": "matches", "budget": budget, "completed": 0,
                   "owner": client, "lastSeen": 0, "explorer": True, "progress": progress(accepted)}
            state = {"runID": run, "config": config, "serial": 1, "joinToken": token,
                     "reconciled": [], "jobs": [job], "elites": [], "solved": False,
                     "completedJobs": 0, "reassignments": 0}
            client_settings = dict(settings, stateDirectory=str(client_dir),
                                   machineName="Config Worker",
                                   certificatePath=str(server_dir / "server-certificate.pem"),
                                   tokenPath=str(server_dir / "join-token"))
            client_config = dict(config, distributed=client_settings)
            local_progress = dict(progress(local), finished=True)
            disk = {"clientID": client, "runID": run, "config": client_config,
                    "records": [{"job": job, "progress": local_progress}]}
            # Seed both fixtures while stopped. No live database is replaced.
            for path, value in [(server_dir / "server.sqlite", state), (client_dir / "client.sqlite", disk)]:
                with closing(sqlite3.connect(path)) as db:
                    db.execute("CREATE TABLE state(key TEXT PRIMARY KEY,value BLOB NOT NULL)")
                    db.execute("INSERT INTO state VALUES ('state',?)", (json.dumps(value).encode(),))
                    db.commit()
            for name, value in [("server.json", config), ("client.json", client_config)]:
                (root / name).write_text(json.dumps(value))
            processes = []

            def wait_for(condition, seconds=15):
                until = time.monotonic() + seconds
                while time.monotonic() < until:
                    if condition():
                        return
                    if any(p.poll() is not None for p in processes):
                        break
                    time.sleep(0.05)
                logs = "\n".join(p.read_text() for p in root.glob("*.log"))
                self.fail("Recovery did not complete:\n" + logs)

            def completed_jobs():
                try:
                    with closing(sqlite3.connect((server_dir / "server.sqlite").as_uri() + "?mode=ro", uri=True)) as db:
                        saved = json.loads(db.execute("SELECT value FROM state").fetchone()[0])
                    self.assertEqual(saved["runID"].upper(), run.upper())
                    if saved["completedJobs"] >= 3:
                        self.assertEqual(saved.get("clientNames", {}).get(client.upper()), "CLI Worker")
                    return saved["completedJobs"] >= 3
                except sqlite3.Error:
                    return False

            with (root / "server.log").open("wb") as server_log, (root / "client.log").open("wb") as client_log:
                try:
                    server = subprocess.Popen([str(EXECUTABLE), "--server", "--init-credentials", "--config", str(root / "server.json")],
                                              stdout=server_log, stderr=subprocess.STDOUT)
                    processes.append(server)
                    wait_for(lambda: (server_dir / "server-certificate.pem").exists())
                    worker = subprocess.Popen([str(EXECUTABLE), "--client", "--config", str(root / "client.json"), "--machine-name", "CLI Worker"],
                                              stdout=client_log, stderr=subprocess.STDOUT)
                    processes.append(worker)
                    wait_for(completed_jobs)
                    worker.terminate()
                    self.assertEqual(worker.wait(timeout=10), 0)
                    server.terminate()
                    self.assertEqual(server.wait(timeout=10), 0)
                finally:
                    for process in processes:
                        if process.poll() is None:
                            process.kill(); process.wait()
            text = (root / "client.log").read_text()
            self.assertIn("Connected to authenticated coordinator", text)
            self.assertIn("CLI Worker", text)
            self.assertIn("Test Coordinator", text)
            self.assertNotIn("outside the assigned budget", text)
            self.assertNotIn("Coordinator unavailable", text)
            if local > budget:
                self.assertIn("Recovered 1 over-budget checkpoints", text)

    def test_legacy_over_budget_checkpoint_recovers_and_completes_more_jobs(self):
        self.exercise_recovery(budget=1, accepted=0, local=2)

    def test_stale_local_checkpoint_reconciles_before_reporting(self):
        self.exercise_recovery(budget=10, accepted=5, local=1)

    def test_missing_machine_name_value_is_an_error(self):
        result = subprocess.run([str(EXECUTABLE), "--client", "--machine-name"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Pass a name after --machine-name", result.stderr)


if __name__ == "__main__":
    unittest.main()
