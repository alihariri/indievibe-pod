#!/usr/bin/env bash
# indievibe-comfy boot. Runs BEFORE the image's /start.sh and then execs it, so
# ComfyUI comes up already pointed at NVMe models with the triton flag on —
# the three things docs/pod-provision.md step 4 used to do by hand over SSH.
# Works from either template: the built image (scripts baked at /opt/indievibe)
# or the stock runpod/comfyui image whose start command fetched them there.
#
# Situations, decided from what /workspace and the image hold:
#   volume with models  → copy them to the container disk (NVMe) first (~2 min),
#                         then start. Every render loads off local disk.
#   fresh /workspace    → /start.sh copies the image's baked tree; the models
#                         download in the background (~30 min at 50 MB/s) while
#                         ComfyUI is already up. healthcheck.sh --chunk is the
#                         readiness gate, as before.
#   baked tree ≠ tag    → (stock image: v0.30.0) after /start.sh has copied it,
#                         setup.sh --code checks v0.34.0 out and ComfyUI is
#                         relaunched once — a minute or three, unattended.
#   MILA_LORA_URL set   → the private LoRA is fetched into models/loras when it
#                         is not on the volume (a RunPod Secret, never baked).
set -uo pipefail
SLIM=/workspace/runpod-slim
COMFY=$SLIM/ComfyUI
ARGS=$SLIM/comfyui_args.txt
IV=/opt/indievibe
TAG=${COMFY_TAG:-v0.34.0}
LOG=/workspace/indievibe-boot.log
mkdir -p "$SLIM" /workspace
exec > >(tee -a "$LOG") 2>&1
echo "── indievibe boot $(date -u +%FT%TZ) ──"

# 1. The scripts where the docs expect them (setup.sh, healthcheck.sh,
#    chunk-prompt.json at /workspace) — refreshed every boot.
cp -f "$IV/setup.sh" "$IV/healthcheck.sh" /workspace/
cp -f "$IV"/bench/* /workspace/ 2>/dev/null || true
sed -i 's/\r$//' /workspace/*.sh

# 2. int8 fast path: ComfyUI 0.34 on torch cu128 disables the kitchen CUDA
#    backend; --enable-triton-backend restores it (chunk 246 s → 66 s).
grep -qs -- '--enable-triton-backend' "$ARGS" || echo '--enable-triton-backend' >> "$ARGS"

has_models() {
  [ -d "$COMFY/models-vol/diffusion_models" ] && return 0
  [ -d "$COMFY/models/diffusion_models" ] && [ ! -L "$COMFY/models" ] && [ -n "$(ls -A "$COMFY/models/diffusion_models" 2>/dev/null)" ]
}
# Is the tree the image will copy on a fresh pod already at the tag?
baked_at_tag() {
  grep -qs "\"${TAG#v}\"" /opt/comfyui-baked/comfyui_version.py 2>/dev/null
}
# The relaunch pod/README.md documents: /start.sh sleeps forever after ComfyUI
# exits, so killing main.py and starting it again with the args file is safe.
relaunch_comfy() {
  pkill -f "main.py --listen" || true
  sleep 3
  local py="$COMFY/.venv-cu128/bin/python"; [ -x "$py" ] || py=python3
  local extra; extra=$(grep -v '^[[:space:]]*#' "$ARGS" 2>/dev/null | tr -s '[:space:]' ' ')
  # shellcheck disable=SC2086
  (cd "$COMFY" && nohup "$py" main.py --listen 0.0.0.0 --port 8188 --enable-cors-header $extra > /workspace/comfyui.log 2>&1 < /dev/null &)
}

# 3. An existing volume copy: same checkout + pip setup.sh always did (a no-op
#    when current), then the models to NVMe BEFORE ComfyUI scans models/.
DOWNLOAD=1
if [ -d "$COMFY" ]; then
  bash "$IV/setup.sh" --code || echo "  (code step failed — ComfyUI starts as it is; see setup.sh --code)"
  if has_models; then
    bash "$IV/setup.sh" --nvme && DOWNLOAD=0
  fi
  FRESH=0
else
  FRESH=1
fi

# 4. A fresh pod: /start.sh copies the baked tree first. If that tree is older
#    than the tag (the stock image), bring it to the tag and relaunch once;
#    then the public models, in the background, logged for the docs' poll.
if [ "$FRESH" = 1 ] || [ "$DOWNLOAD" = 1 ]; then
  (
    until [ -f "$COMFY/main.py" ]; do sleep 5; done
    if [ "$FRESH" = 1 ] && ! baked_at_tag; then
      echo "── baked ComfyUI is not $TAG: checking out, then relaunching ──"
      bash "$IV/setup.sh" --code && relaunch_comfy
    fi
    [ "$DOWNLOAD" = 1 ] && bash "$IV/setup.sh" --models
    echo "── background setup finished $(date -u +%FT%TZ) ──"
  ) > /workspace/setup.log 2>&1 &
fi

# 5. The private LoRA, when a URL is given and the file is not there.
if [ -n "${MILA_LORA_URL:-}" ]; then
  (
    until [ -d "$COMFY" ]; do sleep 5; done
    dest="$COMFY/models/loras"; mkdir -p "$dest"
    command -v aria2c >/dev/null || { apt-get update -qq && apt-get install -y -qq aria2 >/dev/null; }
    [ -s "$dest/Mila.safetensors" ] || aria2c -q -c -x 8 -s 8 -d "$dest" -o Mila.safetensors "$MILA_LORA_URL"
  ) > /workspace/lora.log 2>&1 &
fi

echo "── handing over to /start.sh ──"
exec /start.sh "$@"
