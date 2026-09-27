#!/usr/bin/env python3
"""Loopback-only lazy MLX proxy for OpenCode.

Set LAYA_LOCAL_MODEL_CONFIG to a JSON file with the fields documented in README.md.
This service owns only the model process that it starts.
"""
import http.client
import json
import os
import signal
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CONFIG = Path(os.environ.get("LAYA_LOCAL_MODEL_CONFIG", Path.home() / ".config/laya-opencode-router/local-model.json"))
ROOT = CONFIG.parent
lock = threading.RLock()
startup = threading.RLock()
process = None
active = 0
last_done = time.monotonic()
state = "stopped"


def settings():
    cfg = json.loads(CONFIG.read_text())
    for key in ("mlx_python", "model_path", "model_id", "gateway_port", "backend_port", "idle_timeout_seconds"):
        if key not in cfg:
            raise ValueError(f"Missing local model setting: {key}")
    if cfg["gateway_port"] == cfg["backend_port"]:
        raise ValueError("Gateway and backend ports must differ")
    return cfg


def alive():
    global process, state
    if process and process.poll() is not None:
        process = None
        state = "stopped"
    return process is not None


def backend_ready(cfg):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{cfg['backend_port']}/v1/models", timeout=2) as r:
            return r.status == 200
    except Exception:
        return False


def start_model():
    global process, state, last_done
    with startup:
        cfg = settings()
        with lock:
            if alive() and state == "running":
                return
            if not alive():
                if backend_ready(cfg):
                    raise RuntimeError("Backend port is already in use by a process this gateway does not own")
                log = open(ROOT / "local-model.log", "ab", buffering=0)
                cmd = [cfg["mlx_python"], "-m", cfg.get("server_module", "mlx_vlm.server"), "--model", cfg["model_path"], "--host", "127.0.0.1", "--port", str(cfg["backend_port"])]
                env = os.environ.copy()
                if cfg.get("mlx_extra_path"):
                    env["PYTHONPATH"] = cfg["mlx_extra_path"]
                process = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True, cwd=ROOT, env=env)
                log.close()
                state = "loading"
        deadline = time.monotonic() + cfg.get("startup_timeout", 300)
        while time.monotonic() < deadline:
            with lock:
                if not alive():
                    raise RuntimeError("MLX server exited during startup; see model.log")
            if backend_ready(cfg):
                with lock:
                    state = "running"
                    last_done = time.monotonic()
                return
            time.sleep(0.5)
        stop_model(force=True)
        raise TimeoutError("MLX server startup timed out; see model.log")


def stop_model(force=False):
    global process, state
    with startup:
        with lock:
            if active and not force:
                raise RuntimeError(f"{active} active request(s); model kept running")
            if not alive():
                return
            pid = process.pid
            state = "stopping"
        try:
            os.killpg(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
        with lock:
            process = None
            state = "stopped"


def memory_mb(pid):
    if not pid:
        return 0
    try:
        return round(int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], text=True).strip()) / 1024)
    except Exception:
        return 0


def status():
    cfg = settings()
    with lock:
        running = alive()
        pid = process.pid if running else None
        return {"gateway": "running", "model_state": state, "pid": pid, "model": cfg["model_id"], "gateway_port": cfg["gateway_port"], "backend_port": cfg["backend_port"], "active_requests": active, "idle_timeout_seconds": cfg["idle_timeout_seconds"], "approx_process_rss_mb": memory_mb(pid)}


def idle_watcher():
    while True:
        time.sleep(1)
        cfg = settings()
        with lock:
            should_stop = alive() and state == "running" and active == 0 and time.monotonic() - last_done >= cfg["idle_timeout_seconds"]
        if should_stop:
            try:
                stop_model()
            except RuntimeError:
                pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/status":
            return self.send_json(200, status())
        if self.path == "/v1/models":
            return self.send_json(200, {"object": "list", "data": [{"id": settings()["model_id"], "object": "model", "owned_by": "local"}]})
        return self.send_json(404, {"error": "not found"})

    def do_POST(self):
        global active, last_done
        if self.path == "/control/start":
            try:
                start_model()
                return self.send_json(200, status())
            except Exception as e:
                return self.send_json(503, {"error": str(e)})
        if self.path == "/control/stop":
            try:
                stop_model()
                return self.send_json(200, status())
            except Exception as e:
                return self.send_json(409, {"error": str(e)})
        if self.path.split("?")[0] not in ("/v1/chat/completions", "/v1/responses"):
            return self.send_json(404, {"error": "not found"})
        with lock:
            active += 1
        try:
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            data = json.loads(body)
            data["model"] = settings()["model_path"]
            body = json.dumps(data).encode()
            start_model()
            cfg = settings()
            conn = http.client.HTTPConnection("127.0.0.1", cfg["backend_port"], timeout=cfg.get("request_timeout", 3600))
            try:
                conn.request("POST", self.path, body=body, headers={"Content-Type": "application/json", "Content-Length": str(len(body)), "Connection": "close"})
                response = conn.getresponse()
                self.send_response(response.status)
                for key, val in response.getheaders():
                    if key.lower() not in ("connection", "transfer-encoding", "content-length", "content-encoding"):
                        self.send_header(key, val)
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                while chunk := response.read(65536):
                    self.wfile.write(chunk)
                    self.wfile.flush()
            finally:
                conn.close()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            if not self.wfile.closed:
                try:
                    self.send_json(503, {"error": str(e)})
                except Exception:
                    pass
        finally:
            with lock:
                active -= 1
                last_done = time.monotonic()


if __name__ == "__main__":
    cfg = settings()
    server = ThreadingHTTPServer(("127.0.0.1", cfg["gateway_port"]), Handler)
    threading.Thread(target=idle_watcher, daemon=True).start()
    def shutdown(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    try:
        server.serve_forever()
    finally:
        stop_model(force=True)
        server.server_close()
