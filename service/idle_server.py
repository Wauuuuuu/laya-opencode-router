"""Local Laya HTTP server that releases model memory after an idle period."""

import os
import signal
import threading
import time

import uvicorn
from laya.serve import create_app

HOST = os.environ.get("LAYA_HOST", "127.0.0.1")
PORT = int(os.environ.get("LAYA_PORT", "8766"))
IDLE_SECONDS = int(os.environ.get("LAYA_IDLE_SECONDS", "90"))

app = create_app()
_lock = threading.Lock()
_last_request = time.monotonic()
_active_requests = 0


@app.middleware("http")
async def track_inference(request, call_next):
    global _last_request, _active_requests
    if request.url.path != "/v1/systemone":
        return await call_next(request)
    with _lock:
        _active_requests += 1
    try:
        return await call_next(request)
    finally:
        with _lock:
            _active_requests -= 1
            _last_request = time.monotonic()


def stop_when_idle():
    while True:
        time.sleep(5)
        with _lock:
            idle = _active_requests == 0 and time.monotonic() - _last_request >= IDLE_SECONDS
        if idle:
            os.kill(os.getpid(), signal.SIGTERM)
            return


threading.Thread(target=stop_when_idle, name="laya-idle-stop", daemon=True).start()
uvicorn.run(app, host=HOST, port=PORT, log_level="warning")
