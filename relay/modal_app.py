"""Deploy the Muse relay on Modal: `modal deploy modal_app.py` from this folder.

Needs Modal secrets `deploy-secrets` (MUSE_API_KEY, optional GITHUB_API_TOKEN)
and `muse-relay` (MUSE_RELAY_TOKEN).
"""
import os
import subprocess
from pathlib import Path

import modal

here = Path(__file__).parent
image = modal.Image.from_dockerfile(here / "Dockerfile", context_dir=here, add_python="3.12")

workspaces = modal.Volume.from_name("muse-relay-workspaces", create_if_missing=True)
muse_home = modal.Volume.from_name("muse-relay-home", create_if_missing=True)

app = modal.App("muse-relay")


@app.function(
    image=image,
    secrets=[modal.Secret.from_name("deploy-secrets"), modal.Secret.from_name("muse-relay")],
    volumes={"/workspaces": workspaces, "/root/.local/share/muse": muse_home},
    # One container: live muse sessions are in-process, so every client must reach the same one.
    max_containers=1,
    scaledown_window=1200,
    timeout=86400,
)
@modal.concurrent(max_inputs=100)
@modal.web_server(8080, startup_timeout=60)
def relay():
    env = dict(os.environ, MUSE_WORKSPACES="/workspaces", PORT="8080")
    subprocess.Popen(["muse-relay"], env=env)
