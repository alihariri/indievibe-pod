# indievibe-comfy — the IG pipeline's own RunPod image.
#
# Base: RunPod's official ComfyUI image (runpod/containers, official-templates/
# comfyui). It bakes ComfyUI at /opt/comfyui-baked and its /start.sh copies that
# tree to /workspace/runpod-slim/ComfyUI on a pod's FIRST boot (only when the
# directory is missing), reads /workspace/runpod-slim/comfyui_args.txt, launches
# ComfyUI on 8188 and sleeps. Everything pod/setup.sh used to do by hand over
# SSH on every fresh pod — checkout v0.34.0, pip, the triton flag, the scripts,
# the NVMe copy — is done here at build time or by entrypoint.sh at boot.
#
# Build context is `pod/` (see image/build.yml):  docker build -f image/Dockerfile .
# Pin the base by full tag — there is no floating cuda12.8 tag on Docker Hub.
FROM runpod/comfyui:1.2.0-comfyuiv0.30.0-cuda12.8

ARG COMFY_TAG=v0.34.0
# The image's own pins (torch 2.10.0+cu128 …) constrain every pip install.
ENV PIP_CONSTRAINT=/opt/comfyui-runtime-constraints.txt

# 1. ComfyUI → the laptop's tag, in place. The baked tree is a tarball with a
#    one-commit git history and no remote, so add upstream and check the tag
#    out detached; untracked files (.venv-cu128, custom_nodes, the bundle
#    marker) survive exactly as they do on a volume under setup.sh.
#    `.runpod-bundle-version` is deliberately LEFT ALONE: a changed marker makes
#    /start.sh rsync --delete the baked tree over an existing volume copy, and
#    that would remove models-vol/ (the 90 GB the volume keeps) — only
#    /models is excluded from the delete.
RUN set -e; cd /opt/comfyui-baked \
 && (git remote get-url origin >/dev/null 2>&1 || git remote add origin https://github.com/comfyanonymous/ComfyUI.git) \
 && git fetch -q --force --tags --depth 1 origin tag "${COMFY_TAG}" \
 && git checkout -q -f --detach "${COMFY_TAG}" \
 && PIP=/opt/comfyui-baked/.venv-cu128/bin/pip; [ -x "$PIP" ] || PIP=pip; "$PIP" install -q -r requirements.txt \
 && apt-get update -qq && apt-get install -y -qq --no-install-recommends aria2 rsync >/dev/null \
 && rm -rf /var/lib/apt/lists/*

# 2. The pod scripts, where entrypoint.sh copies them to /workspace on boot
#    (the docs and healthcheck.sh --chunk expect /workspace/setup.sh,
#    /workspace/healthcheck.sh and /workspace/chunk-prompt.json).
COPY setup.sh healthcheck.sh /opt/indievibe/
COPY bench/ /opt/indievibe/bench/
COPY image/entrypoint.sh /opt/indievibe/entrypoint.sh
RUN sed -i 's/\r$//' /opt/indievibe/*.sh /opt/indievibe/bench/*.sh && chmod +x /opt/indievibe/*.sh /opt/indievibe/bench/*.sh

# 3. Boot: prepare, then hand over to the image's own /start.sh (never replaced).
ENTRYPOINT ["/opt/indievibe/entrypoint.sh"]
