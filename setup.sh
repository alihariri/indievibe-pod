#!/usr/bin/env bash
# Provision a RunPod "ComfyUI - CUDA 12.8" pod (runpod/comfyui image) for the
# IG pipeline. Run ONCE on a pod whose /workspace is a network volume; after
# that a pod start is minutes and `--verify` is all you need.
#
#   bash setup.sh                # update ComfyUI, download models, verify
#   bash setup.sh --verify       # only the object_info + file check
#   bash setup.sh --nvme         # copy models volume -> container disk (NVMe), relink
#   bash setup.sh --code         # only the checkout + pip (the image's boot runs it)
#   bash setup.sh --models       # only the downloads (the image's boot, fresh pod)
#
# On the indievibe-comfy image (pod/image/) the boot runs these itself —
# nothing here is typed over SSH any more; the modes are the same steps.
#
# Every model below is the SAME file the laptop renders with (int8 LTX-2.5,
# fp8mixed FLUX.2-dev), taken from public HF repos whose sha256 matches the
# gated Lightricks/LTX-2.5 originals (checked 2026-09-05). The gemma text
# encoder is saved under the laptop's filename so the workflows need no
# pod variant. The Mila LoRA is private: scp it (Ali: Mila only on pods).
set -euo pipefail

COMFY=${COMFY_DIR:-/workspace/runpod-slim/ComfyUI}
MODELS=$COMFY/models
PORT=${COMFY_PORT:-8188}
HF=${HF_TOKEN:-}          # only needed if a repo below turns gated

# repo | path-in-repo | dest under models/ | exact size (bytes)
MODEL_TABLE='
Comfy-Org/flux2-dev|split_files/diffusion_models/flux2_dev_fp8mixed.safetensors|diffusion_models/flux2_dev_fp8mixed.safetensors|35455599592
Comfy-Org/flux2-dev|split_files/text_encoders/mistral_3_small_flux2_fp8.safetensors|text_encoders/mistral_3_small_flux2_fp8.safetensors|18034640095
Comfy-Org/flux2-dev|split_files/vae/flux2-vae.safetensors|vae/flux2-vae.safetensors|336213556
Comfy-Org/flux2-dev|split_files/loras/Flux_2-Turbo-LoRA_comfyui.safetensors|loras/Flux_2-Turbo-LoRA_comfyui.safetensors|2760814880
comfyicu/LTX-2.5|diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors|diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors|21504034224
PulpCut/LTX-2.5-INT8-ConvRot-safetensors|text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors|text_encoders/gemma4-12b-with-proj-ltx-2.5-int8_lean_convrot.safetensors|15372969374
comfyicu/LTX-2.5|vae/ltx-2.5-video-vae-conv-bf16.safetensors|vae/ltx-2.5-video-vae-conv-bf16.safetensors|1452269922
comfyicu/LTX-2.5|vae/ltx-2.5-audio-vae-bf16.safetensors|vae/ltx-2.5-audio-vae-bf16.safetensors|364866540
'
LORAS="Mila.safetensors"

# Every class_type the dashboard's workflows use. All are ComfyUI core as of
# 2026-09 (LTXVDualCFGGuider arrived after the image's checkout — hence the
# git pull below); no custom node pack is required.
NEED="LTXVAddGuide LTXVAudioVAEDecode LTXVConcatAVLatent LTXVConditioning LTXVCropGuides LTXVDualCFGGuider LTXVEmptyLatentAudio LTXVImgToVideoInplace LTXVPreprocess LTXVSeparateAVLatent EmptyLTXVLatentVideo EmptyFlux2LatentImage FluxGuidance ReferenceLatent ComfyMathExpression ManualSigmas ResizeImageMaskNode ImageScaleToTotalPixels SamplerEulerAncestral CreateVideo SaveVideo"

verify() {
  local ok=0
  echo "── node classes (ComfyUI on :$PORT) ──"
  local have
  have=$(curl -sf "http://127.0.0.1:$PORT/object_info" | python3 -c 'import sys,json; print(" ".join(json.load(sys.stdin).keys()))') \
    || { echo "  ComfyUI is not answering on $PORT — start it first"; ok=1; have=""; }
  local missing=""
  for c in $NEED; do case " $have " in *" $c "*) ;; *) missing="$missing $c";; esac; done
  if [ -n "$missing" ]; then echo "  MISSING:$missing"; ok=1; else echo "  all present"; fi
  echo "── model files ──"
  while IFS='|' read -r repo path dest size; do
    [ -z "$repo" ] && continue
    local f="$MODELS/$dest"
    if [ -f "$f" ] && [ "$(stat -c %s "$f")" = "$size" ]; then echo "  ok      $dest"
    elif [ -f "$f" ]; then echo "  PARTIAL $dest ($(stat -c %s "$f") of $size)"; ok=1
    else echo "  MISSING $dest"; ok=1; fi
  done <<< "$MODEL_TABLE"
  for l in $LORAS; do [ -s "$MODELS/loras/$l" ] && echo "  ok      loras/$l" || { echo "  MISSING loras/$l (scp from the laptop)"; ok=1; }; done
  return $ok
}

if [ "${1:-}" = "--verify" ]; then verify; exit $?; fi

# The network volume reads at ~180 MB/s cold; every model swap paid 1-4 min.
# --nvme copies the whole models tree onto the pod's container disk (local
# NVMe, lost on stop) and points ComfyUI's models/ at it via a symlink. The
# volume keeps its copy under models-vol/. Run once per pod start (~93 GB).
NVME=${NVME_DIR:-/root/models-nvme}
if [ "${1:-}" = "--nvme" ]; then
  VOL=$COMFY/models-vol
  if [ -d "$MODELS" ] && [ ! -L "$MODELS" ]; then mv "$MODELS" "$VOL"; fi
  [ -d "$VOL" ] || { echo "no $VOL"; exit 1; }
  mkdir -p "$NVME"
  echo "── copying $(du -sh "$VOL" | cut -f1) → $NVME ──"
  time cp -a "$VOL/." "$NVME/"
  ln -sfn "$NVME" "$MODELS"
  echo "── models → $NVME; restart ComfyUI so it re-scans ──"
  exit 0
fi
# A pod that has not run --nvme yet: make sure models/ still resolves.
if [ -L "$COMFY/models" ] && [ ! -e "$COMFY/models" ]; then ln -sfn "$COMFY/models-vol" "$COMFY/models"; fi

# The image ships ComfyUI v0.26.2 on a branch with no upstream; the laptop
# runs v0.34.0. Same tag on both = same graph behaviour. The image's venv
# (.venv-cu128) is what start.sh launches, so its pip does the install.
COMFY_TAG=${COMFY_TAG:-v0.34.0}
if [ "${1:-}" != "--models" ]; then
  echo "── ComfyUI → $COMFY_TAG ($COMFY) ──"
  git -C "$COMFY" remote get-url origin >/dev/null 2>&1 || git -C "$COMFY" remote add origin https://github.com/comfyanonymous/ComfyUI.git
  git -C "$COMFY" fetch -q --force --tags origin   # the image's own tag differs from upstream's
  git -C "$COMFY" checkout -q -f --detach "$COMFY_TAG"
  PIP="$COMFY/.venv-cu128/bin/pip"; [ -x "$PIP" ] || PIP=pip
  PIP_CONSTRAINT=${PIP_CONSTRAINT:-/opt/comfyui-runtime-constraints.txt} "$PIP" install -q -r "$COMFY/requirements.txt"
  [ "${1:-}" = "--code" ] && exit 0
fi

echo "── models ──"
command -v aria2c >/dev/null || { apt-get update -qq && apt-get install -y -qq aria2 >/dev/null; }
while IFS='|' read -r repo path dest size; do
  [ -z "$repo" ] && continue
  f="$MODELS/$dest"; mkdir -p "$(dirname "$f")"
  if [ -f "$f" ] && [ "$(stat -c %s "$f")" = "$size" ]; then echo "  have $dest"; continue; fi
  echo "  get  $dest  ($((size / 1000000000)) GB from $repo)"
  aria2c -q -c -x 16 -s 16 --file-allocation=none ${HF:+--header="Authorization: Bearer $HF"} \
    -d "$(dirname "$f")" -o "$(basename "$f")" "https://huggingface.co/$repo/resolve/main/$path"
  [ "$(stat -c %s "$f")" = "$size" ] || { echo "  size mismatch on $dest"; exit 1; }
done <<< "$MODEL_TABLE"

echo "── done downloading. Restart the pod (console → ⋮ → Restart Pod) so the"
echo "   updated ComfyUI loads, then: bash setup.sh --verify"
verify || true
