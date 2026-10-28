#!/usr/bin/env python3
"""Exercise a running debug app in a private runtime. Never targets the normal app.

Build with scripts/build-app.sh --debug, then launch with TERN_RUNTIME_DIR=/tmp/...
and TERN_DEBUG=1. Pass that runtime below; the debug harness supplies its exact PID.
This adds test tabs/windows and leaves sessions alive for inspection.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parents[1] / "build/Tern.app/Contents/Helpers/tern")
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    if not runtime.is_relative_to(Path("/tmp").resolve()) or len(str(runtime)) > 80:
        parser.error("Use a short private runtime under /tmp.")
    pid = int((runtime / "debug/app.pid").read_text())
    os.kill(pid, 0)

    def wait(predicate, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                result = predicate()
                if result:
                    return result
            except (FileNotFoundError, ConnectionRefusedError, json.JSONDecodeError):
                pass
            time.sleep(0.02)
        raise AssertionError("Timed out waiting for private app state")

    def command(title):
        ack = runtime / "debug/last-command"
        ack.unlink(missing_ok=True)
        (runtime / "debug/command").write_text(title)
        os.kill(pid, signal.SIGUSR2)
        wait(lambda: ack.read_text() == title)

    def windows():
        return json.loads((runtime / "windows.json").read_text())

    def request(value):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(5)
            connection.connect(str(runtime / "ternd.sock"))
            connection.sendall(json.dumps(value).encode() + b"\n")
            return json.loads(connection.makefile("rb").readline())

    def launch(marker):
        subprocess.run([str(args.binary), "open", "/tmp", "--window", "--command", f"printf '%s\\n' '{marker}'"],
                       env=dict(os.environ, TERN_RUNTIME_DIR=str(runtime)), check=True, stdout=subprocess.DEVNULL)
        wait(lambda: len(windows()) == 2)
        target = next(window["id"] for window in windows() if window["id"] != "main")
        command("WindowID tern.window." + target)
        wait(lambda: any(window["id"] == target and window.get("active") for window in windows()))

    wait(lambda: (runtime / "windows.json").exists())
    if len(windows()) != 1:
        parser.error("Start with one private terminal window.")
    command("Button 2")  # Defer a daemon upgrade if a sheet is present.
    command("Escape")
    for index in range(3):
        marker = f"tern-move-{time.time_ns()}-{index}"
        launch(marker)
        command("Move Tab to Next Window")
        wait(lambda: len(windows()) == 1)
        sessions = wait(lambda: [s for s in request({"op": "list"}) if marker in (s.get("command") or "")])
        output = wait(lambda: request({"op": "read_output", "id": sessions[0]["id"], "last_command": True}).get("text", "").strip() == marker)
        assert output
        print(f"Startup command survived immediate window move: {sessions[0]['id']}", flush=True)

    marker = f"tern-detach-{time.time_ns()}"
    launch(marker)
    session = wait(lambda: next((s for s in request({"op": "list"}) if marker in (s.get("command") or "")), None))
    command("Detach Tab")
    assert len(windows()) == 2, "Detaching the last tab must keep the window available"
    wait(lambda: any(s["id"] == session["id"] and s["clients"] == 0 for s in request({"op": "list"})))
    command("Close Window")
    wait(lambda: len(windows()) == 1)
    command("Reopen Closed Tab")
    wait(lambda: any(s["id"] == session["id"] and s["clients"] == 1 for s in request({"op": "list"})))
    print(f"Detached session survived window closure and reattached: {session['id']}", flush=True)
    os.kill(pid, signal.SIGUSR1)
    print(f"Private screenshots and window state: {runtime / 'debug'}")


if __name__ == "__main__":
    main()
