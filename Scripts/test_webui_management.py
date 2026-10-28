"""End-to-end management against disposable loopback processes and databases."""
from contextlib import closing
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request
import uuid

EXECUTABLE = Path(os.environ.get("PUZZLE_TEST_EXECUTABLE", Path(__file__).resolve().parents[1] / ".build/release/janestreet-puzzle"))


def free_port():
    with closing(socket.socket()) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


@unittest.skipUnless(EXECUTABLE.is_file(), "Build the release executable first")
class WebUIManagementTests(unittest.TestCase):
    def test_pause_restart_resize_offline_quit_relaunch_and_drain(self):
        with tempfile.TemporaryDirectory(prefix="webui-management-") as folder:
            root = Path(folder).resolve()
            server_dir, client_dir = root / "server", root / "client"
            server_dir.mkdir(); client_dir.mkdir()
            port, web_port = free_port(), free_port()
            settings = {"address": "127.0.0.1", "port": port, "webUIAddress": "127.0.0.1", "webUIPort": web_port,
                        "stateDirectory": str(server_dir), "clientWorkers": 2, "heartbeatSeconds": 0.1,
                        "checkpointSeconds": 0.05, "failureGraceSeconds": 1, "calibrationSeconds": 0.01,
                        "jobSeconds": 0.2, "machineName": "Management fixture"}
            config = {"rowNum": 1, "colNum": 1, "Target": {"Status": [[1]]}, "pathEvaluation": "cpu", "distributed": settings}
            (root / "server.json").write_text(json.dumps(config))
            config = dict(config, distributed=dict(settings, stateDirectory=str(client_dir),
                          certificatePath=str(server_dir / "server-certificate.pem"), tokenPath=str(server_dir / "join-token")))
            (root / "client.json").write_text(json.dumps(config))
            processes, handles = [], []
            base = f"http://127.0.0.1:{web_port}"

            def launch(role):
                handle = (root / f"{role}-{len(processes)}.log").open("wb")
                handles.append(handle)
                arguments = [str(EXECUTABLE), f"--{role}", "--config", str(root / f"{role}.json")]
                if role == "server" and not (server_dir / "server-private-key.pem").exists():
                    arguments.append("--init-credentials")
                process = subprocess.Popen(arguments, stdout=handle, stderr=subprocess.STDOUT)
                processes.append(process)
                return process

            def snapshot():
                with urllib.request.urlopen(base + "/api/status", timeout=3) as response:
                    return json.load(response)

            def wait(condition, seconds=20):
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    try:
                        value = condition()
                        if value:
                            return value
                    except (OSError, ValueError, KeyError, IndexError):
                        pass
                    time.sleep(0.05)
                logs = "\n".join(p.read_text()[-6000:] for p in root.glob("*.log"))
                self.fail("Management condition timed out:\n" + logs)

            def post(body, admin):
                request = urllib.request.Request(base + "/api/commands", data=json.dumps(body).encode(), method="POST",
                    headers={"Content-Type": "application/json", "Origin": base, "Authorization": "Bearer " + admin})
                with urllib.request.urlopen(request, timeout=5) as response:
                    self.assertEqual(response.status, 202)
                    return json.load(response)

            try:
                server = launch("server")
                wait(lambda: (server_dir / "web-admin-token").exists() and snapshot())
                admin = (server_dir / "web-admin-token").read_text().strip()
                worker = launch("client")
                state = wait(lambda: (s := snapshot())["clients"] and s["candidates"] and s["clients"][0].get("info", {}).get("telemetry") and s)
                client_id = state["clients"][0]["id"]

                def issue(action, workers=None):
                    state = snapshot()
                    body = {"id": str(uuid.uuid4()), "runID": state["runID"], "clientID": client_id, "action": action}
                    if workers is not None:
                        body["workers"] = workers
                    post(body, admin)
                    post(body, admin)  # Exact HTTP retry must be idempotent.
                    return body["id"].upper()

                def acknowledged(command_id, status):
                    return next((c for c in snapshot()["commands"] if c["request"]["id"] == command_id and c["status"] == status), None)

                pause = issue("pause")
                wait(lambda: acknowledged(pause, "paused"))
                wait(lambda: snapshot()["clients"][0]["info"]["telemetry"]["mode"] == "paused" and not snapshot()["clients"][0]["info"]["telemetry"]["workers"])
                worker.kill(); worker.wait(timeout=5)
                worker = launch("client")
                time.sleep(0.3)
                wait(lambda: snapshot()["clients"][0]["info"]["telemetry"]["mode"] == "paused")
                resume = issue("resume")
                wait(lambda: acknowledged(resume, "running"))
                resize = issue("workers", 1)
                wait(lambda: acknowledged(resize, "running"))
                wait(lambda: all(w["slot"] == 0 for w in snapshot()["clients"][0]["info"]["telemetry"]["workers"]))
                checkpoint = issue("checkpoint")
                wait(lambda: acknowledged(checkpoint, "checkpointed"))
                # An unreachable client must stay queued until it actually responds.
                worker.send_signal(signal.SIGSTOP)
                wait(lambda: not snapshot()["clients"][0]["connected"])
                quit_id = issue("quit")
                self.assertIsNotNone(acknowledged(quit_id, "queued"))
                worker.send_signal(signal.SIGCONT)
                self.assertEqual(worker.wait(timeout=20), 0)
                wait(lambda: acknowledged(quit_id, "released"))
                worker = launch("client")
                wait(lambda: snapshot()["clients"][0]["connected"] and snapshot()["clients"][0]["info"]["telemetry"]["mode"] == "running")
                drain = issue("drain")
                self.assertEqual(worker.wait(timeout=20), 0)
                wait(lambda: acknowledged(drain, "released"))
                worker = launch("client")
                wait(lambda: snapshot()["clients"][0]["connected"] and snapshot()["clients"][0]["info"]["telemetry"]["mode"] == "running")
                worker.terminate(); self.assertEqual(worker.wait(timeout=10), 0)
                state = snapshot()
                self.assertTrue(state["candidates"])
                self.assertTrue(state["insights"]["improvements"])
                self.assertGreater(state["insights"]["acceptedIterations"], 0)
                self.assertEqual(sum(c["request"]["id"] == quit_id for c in state["commands"]), 1)
                self.assertTrue(all(j["completed"] <= j["budget"] for j in state["jobs"]))
                # Restarts retain history and command outcomes; no production state is touched.
                server.terminate(); self.assertEqual(server.wait(timeout=10), 0)
                server = launch("server")
                wait(lambda: snapshot()["commands"][-1]["status"] == "released")
                self.assertEqual(snapshot()["insights"]["acceptedIterations"], state["insights"]["acceptedIterations"])
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.kill(); process.wait()
                for handle in handles:
                    handle.close()
            logs = "\n".join(p.read_text() for p in root.glob("*.log"))
            self.assertNotIn("outside the assigned budget", logs)
            self.assertNotIn("Invalid command acknowledgment", logs)


if __name__ == "__main__":
    unittest.main()
