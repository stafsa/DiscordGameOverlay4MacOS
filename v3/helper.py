#!/usr/bin/env python3
"""Local receiver for DiscordGameOverlayActivityBridge.plugin.js."""

import ctypes
import json
import plistlib
import sys
import threading
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


HOST = "127.0.0.1"
PORT = 7999
MAX_BODY_BYTES = 1_048_576
MAX_GAMES = 10
STALE_AFTER_SECONDS = 10
DYLIB_PATH = Path("/Users/cbs/Documents/Projects/discordoverlay4mac/DiscordOverlay.dylib")
SIGNATURE_REPORT_PATH = Path.cwd() / "signatures.txt"
MISSING_ENTITLEMENT_PATH = Path.cwd() / "missing_get_task_allow.txt"
PLUGIN_PATH = Path(__file__).with_name("DiscordGameOverlayActivityBridge.plugin.js")
PLUGIN_SIGNATURE_PATH = Path(__file__).with_name("DiscordGameOverlayActivityBridge.plugin.js.sig")
PLUGIN_PUBLIC_KEY_PATH = Path(__file__).with_name("plugin-signing-public.pem")
INJECTION_LOCK = threading.Lock()
INJECTING_PIDS = set()
SIGNATURE_REPORT_LOCK = threading.Lock()
MISSING_ENTITLEMENT_LOCK = threading.Lock()
MISSING_ENTITLEMENT_EXECUTABLES = set()


class GameActivityState:
    def __init__(self):
        self._lock = threading.Lock()
        self._payload = {"games": [], "sent_at": 0}
        self._received_at = 0.0
        self._expiry_timer = None

    @staticmethod
    def validate(payload):
        if not isinstance(payload, dict) or not isinstance(payload.get("games"), list):
            raise ValueError("Expected an object containing a games array.")
        if len(payload["games"]) > MAX_GAMES:
            raise ValueError("Too many games.")

        games = []
        for game in payload["games"]:
            if not isinstance(game, dict):
                raise ValueError("Every game must be an object.")
            name = game.get("name")
            if not isinstance(name, str) or not name.strip():
                raise ValueError("Every game needs a name.")
            games.append({
                "id": str(game.get("id", "")),
                "name": name.strip(),
                "pid": int(game.get("pid", 0) or 0),
                "executable": str(game.get("executable", "")),
                "started_at": int(game.get("started_at", 0) or 0),
            })
        return {"games": games, "sent_at": int(payload.get("sent_at", 0) or 0)}

    def replace(self, payload):
        normalized = self.validate(payload)
        with self._lock:
            self._payload = normalized
            self._received_at = time.monotonic()
            if self._expiry_timer:
                self._expiry_timer.cancel()
            self._expiry_timer = threading.Timer(STALE_AFTER_SECONDS, self._expire, args=(self._received_at,))
            self._expiry_timer.daemon = True
            self._expiry_timer.start()

    def _expire(self, received_at):
        with self._lock:
            if self._received_at != received_at:
                return
            self._payload = {"games": [], "sent_at": 0}
            self._received_at = 0.0
            self._expiry_timer = None

    def snapshot(self):
        with self._lock:
            if self._received_at and time.monotonic() - self._received_at >= STALE_AFTER_SECONDS:
                self._payload = {"games": [], "sent_at": 0}
                self._received_at = 0.0
            return dict(self._payload, games=list(self._payload["games"]))


STATE = GameActivityState()


def verify_plugin_integrity(plugin_path=PLUGIN_PATH, signature_path=PLUGIN_SIGNATURE_PATH):
    if not plugin_path.is_file() or not signature_path.is_file() or not PLUGIN_PUBLIC_KEY_PATH.is_file():
        print("Plugin integrity verification files are missing.", file=sys.stderr)
        return False
    result = subprocess.run(
        [
            "openssl", "pkeyutl", "-verify", "-rawin", "-pubin",
            "-inkey", str(PLUGIN_PUBLIC_KEY_PATH),
            "-in", str(plugin_path),
            "-sigfile", str(signature_path),
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        print("Plugin integrity verification failed: %s" % result.stderr.strip(), file=sys.stderr)
        return False
    return True


def executable_path_for_pid(pid):
    """Return the actual macOS executable image, not a Wine command line."""
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        proc_pidpath = libproc.proc_pidpath
        proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        proc_pidpath.restype = ctypes.c_int
        buffer = ctypes.create_string_buffer(4096)
        length = proc_pidpath(pid, ctypes.cast(buffer, ctypes.c_void_p), ctypes.sizeof(buffer))
        if length > 0:
            executable = buffer.value.decode("utf-8")
            if executable:
                return executable
    except (OSError, UnicodeDecodeError):
        pass

    #Fallback for environments without libproc
    process = subprocess.run(
        ["ps", "-p", str(pid), "-o", "comm="],
        text=True,
        capture_output=True,
        check=False,
    )
    executable = process.stdout.strip()
    if process.returncode != 0 or not executable:
        print("Unable to resolve executable for PID %d" % pid, file=sys.stderr)
        return None
    if executable.lower().startswith(("c:\\", "z:\\")):
        print("PID %d resolved only to a Windows path; cannot inspect macOS entitlements." % pid, file=sys.stderr)
        return None
    return executable


def inspect_signature(executable):
    return subprocess.run(
        ["codesign", "-dvvv", "--entitlements", ":-", executable],
        text=True,
        capture_output=True,
        check=False,
    )


def save_signature_report(pid, executable, result):
    report = "\n[%s] PID %d\nExecutable: %s\n%s%s\n" % (
        time.strftime("%Y-%m-%d %H:%M:%S"),
        pid,
        executable,
        result.stdout,
        result.stderr,
    )
    with SIGNATURE_REPORT_LOCK:
        with SIGNATURE_REPORT_PATH.open("a", encoding="utf-8") as file:
            file.write(report)


def entitlements_from_signature_output(output):
    start = output.find("<?xml")
    end = output.find("</plist>", start)
    if start < 0 or end < 0:
        return {}
    return plistlib.loads(output[start:end + len("</plist>")].encode("utf-8"))


def is_windows_executable_path(path):
    return isinstance(path, str) and path.lower().startswith(("c:\\", "z:\\"))


def parent_executable_path_for_pid(pid):
    process = subprocess.run(
        ["ps", "-p", str(pid), "-o", "ppid="],
        text=True,
        capture_output=True,
        check=False,
    )
    try:
        parent_pid = int(process.stdout.strip())
    except ValueError:
        return None
    return executable_path_for_pid(parent_pid)


def record_missing_get_task_allow(executable, reported_executable="", parent_executable=None):
    recorded_path = executable
    if is_windows_executable_path(reported_executable) and parent_executable:
        recorded_path = "%s: %s" % (reported_executable, parent_executable)
    with MISSING_ENTITLEMENT_LOCK:
        if recorded_path in MISSING_ENTITLEMENT_EXECUTABLES:
            return
        MISSING_ENTITLEMENT_EXECUTABLES.add(recorded_path)
        with MISSING_ENTITLEMENT_PATH.open("a", encoding="utf-8") as file:
            file.write(recorded_path + "\n")


def ensure_get_task_allow(pid, reported_executable=""):
    try:
        executable = executable_path_for_pid(pid)
        if not executable:
            return False
        signature = inspect_signature(executable)
        save_signature_report(pid, executable, signature)
        output = signature.stdout + "\n" + signature.stderr
        entitlements = entitlements_from_signature_output(output)
        if entitlements.get("com.apple.security.get-task-allow") is True:
            return True
        parent_executable = parent_executable_path_for_pid(pid) if is_windows_executable_path(reported_executable) else None
        record_missing_get_task_allow(executable, reported_executable, parent_executable)
        print("Skipping PID %d: com.apple.security.get-task-allow is not enabled. Re-sign it manually before launching the app." % pid)
        return False
    except (OSError, plistlib.InvalidFileException) as error:
        print("Unable to inspect entitlements for PID %d: %s" % (pid, error), file=sys.stderr)
        return False


def inject_dylib(pid):
    try:
        if not DYLIB_PATH.is_file():
            print("Dylib does not exist: %s" % DYLIB_PATH, file=sys.stderr)
            return
        command = [
            "lldb", "--no-lldbinit", "-Q", "-b",
            "-o", "settings set symbols.auto-download off",
            "-o", "settings set symbols.load-on-demand true",
            "-o", "settings set target.memory-module-load-level partial",
            "-o", "process attach --pid %d" % pid,
            "-o", "process handle -s false -n false -p false SIGSTOP",
            "-o", "process handle -s false -n false -p true SIGUSR1",
            "-o", 'expr -l c -- (void *)dlopen("%s", 2)' % DYLIB_PATH,
            "-o", "process detach",
            "-o", "exit",
        ]
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        output = (result.stdout + result.stderr).strip()
        print("LLDB injection for PID %d exited with %d\n%s" % (pid, result.returncode, output))
    except FileNotFoundError:
        print("LLDB was not found.", file=sys.stderr)


def inject_scheduled_dylib(pid, reported_executable):
    try:
        if not ensure_get_task_allow(pid, reported_executable):
            return
        inject_dylib(pid)
    finally:
        with INJECTION_LOCK:
            INJECTING_PIDS.discard(pid)


def schedule_injections(games):
    for game in games:
        pid = game.get("pid", 0)
        if not isinstance(pid, int) or pid <= 0:
            continue
        with INJECTION_LOCK:
            if pid in INJECTING_PIDS:
                continue
            INJECTING_PIDS.add(pid)
        threading.Thread(
            target=inject_scheduled_dylib,
            args=(pid, game.get("executable", "")),
            daemon=True,
        ).start()


class GameActivityHandler(BaseHTTPRequestHandler):
    server_version = "DiscordGameOverlayHelper/1.0"

    def log_message(self, format_string, *args):
        sys.stdout.write("%s - %s\n" % (self.address_string(), format_string % args))

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        if self.path != "/discord-games":
            self.send_error(404, "Not found")
            return
        body = json.dumps(STATE.snapshot(), ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path == "/wine-rpc-client":
            self._handle_wine_rpc_client()
            return
        if self.path != "/discord-games":
            self.send_error(404, "Not found")
            return
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            if content_length < 1 or content_length > MAX_BODY_BYTES:
                raise ValueError("Invalid Content-Length.")
            payload = json.loads(self.rfile.read(content_length).decode("utf-8"))
            STATE.replace(payload)
            schedule_injections(STATE.snapshot()["games"])
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            self.send_error(400, str(error))
            return
        self.send_response(204)
        self.end_headers()

    def _handle_wine_rpc_client(self):
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            if content_length < 1 or content_length > MAX_BODY_BYTES:
                raise ValueError("Invalid Content-Length.")
            payload = json.loads(self.rfile.read(content_length).decode("utf-8"))
            game = GameActivityState.validate({"games": [payload]})["games"][0]
            if game["pid"] <= 0:
                raise ValueError("A positive PID is required.")
            print("Wine Discord RPC client: PID %d, %s" % (game["pid"], game["executable"] or game["name"]))
            schedule_injections([game])
        except (TypeError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            self.send_error(400, str(error))
            return
        self.send_response(204)
        self.end_headers()


def main():
    if "--verify-plugin" in sys.argv:
        sys.exit(0 if verify_plugin_integrity() else 1)
    if not verify_plugin_integrity():
        raise SystemExit("The bundled plugin signature is invalid or unavailable.")
    server = ThreadingHTTPServer((HOST, PORT), GameActivityHandler)
    print("Listening at http://%s:%d/discord-games" % (HOST, PORT))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
