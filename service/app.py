import os
import socket

from flask import Flask, jsonify

app = Flask(__name__)

# In Kubernetes the ConfigMap is also mounted here. Env vars are fixed when the
# container starts, but the mounted files get refreshed by the kubelet, so a
# patched ConfigMap shows up without a restart.
CONFIG_DIR = os.environ.get("CONFIG_DIR", "/etc/demo-config")


def read_file(name):
    try:
        with open(os.path.join(CONFIG_DIR, name)) as f:
            return f.read().strip()
    except OSError:
        return None


# What the mounted files said when this process started.
STARTUP_FILES = {name: read_file(name) for name in ("APP_NAME", "VERSION")}


def setting(name):
    # Env var is the normal source. Only if the mounted file changed since
    # startup (ConfigMap edited in place) do we trust the file instead.
    current = read_file(name)
    if current is not None and current != STARTUP_FILES[name]:
        return current
    return os.environ.get(name, "unknown")


@app.get("/")
def index():
    return jsonify(app=setting("APP_NAME"), version=setting("VERSION"), pod=socket.gethostname())


@app.get("/healthz")
def healthz():
    return jsonify(status="ok")
