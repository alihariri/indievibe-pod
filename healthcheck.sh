#!/usr/bin/env bash
# Two-minute verdict on a freshly started pod, BEFORE provisioning or renting
# it for the night. Every line is PASS / WARN / FAIL with the number behind it.
#
#   bash healthcheck.sh            # host checks (no ComfyUI needed)
#   bash healthcheck.sh --chunk    # + the real 6 s chunk through ComfyUI
#
# Reference (2026-09-06, healthy RTX 4090, EU-RO-1, triton backend, NVMe):
#   6 s chunk 66 s cold / 50 s warm at 3.64 s/step; still 235 s at 11.2 s/step.
set -uo pipefail
COMFY=${COMFY_DIR:-/workspace/runpod-slim/ComfyUI}
PY=$COMFY/.venv-cu128/bin/python; [ -x "$PY" ] || PY=python3
NET_URL="https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"   # 336 MB, public

# thresholds
NET_MIN=40      # MB/s single-stream pod-side download (setup.sh's 16-stream aria2c gets ~4×)
DISK_MIN=800    # MB/s direct-IO sequential read on the container disk (NVMe is 1000+)
PCIE_GEN=4; PCIE_W=8   # the 66 s reference host was Gen4 x8; x16 may do better, below x8 is a fail
CHUNK_REF=66    # s, cold, healthy 4090 — >20% over = bad host (per card below)
# bf16 dense matmul TFLOPS a healthy card reaches in a 5 s burst (≈75% of spec)
declare -A TF=( ["RTX 4090"]=120 ["RTX 5090"]=160 ["L40S"]=130 ["RTX 6000 Ada"]=120 ["L40"]=110 ["A100"]=200 )
declare -A CHUNK=( ["RTX 4090"]=66 ["RTX 5090"]=48 ["L40S"]=66 ["RTX 6000 Ada"]=70 )

fails=0; warns=0
pass() { printf "PASS  %-14s %s\n" "$1" "$2"; }
warn() { printf "WARN  %-14s %s\n" "$1" "$2"; warns=$((warns+1)); }
fail() { printf "FAIL  %-14s %s\n" "$1" "$2"; fails=$((fails+1)); }

# ── GPU identity, driver, CUDA ─────────────────────────────────────────────
Q() { nvidia-smi --query-gpu="$1" --format=csv,noheader,nounits | head -1 | sed 's/^ *//;s/ *$//'; }
NAME=$(Q name); VRAM=$(Q memory.total); DRV=$(Q driver_version)
CUDA=$(nvidia-smi | grep -o "CUDA Version: [0-9.]*" | cut -d' ' -f3)
SHORT=$(echo "$NAME" | sed 's/NVIDIA //;s/GeForce //')
echo "── $NAME · ${VRAM} MiB · driver $DRV · CUDA $CUDA · $(nproc) vCPU · $(free -g | awk '/Mem/{print $2}') GB RAM"
case "$SHORT" in *A100*|*A40*|*A6000*|*A5000*|*A4000*|*3090*) fail gpu "$SHORT is Ampere — no FP8 tensor cores (Ali's rule: Ada/Blackwell only)";; *) pass gpu "$SHORT has FP8 cores";; esac
if awk "BEGIN{exit !($CUDA >= 13.0)}"; then pass cuda "$CUDA — a cu130 torch enables the comfy_kitchen CUDA backend"
else warn cuda "$CUDA — cu128 only: kitchen CUDA backend stays OFF, run ComfyUI with --enable-triton-backend"; fi

# ── PCIe link ─────────────────────────────────────────────────────────────
# .max, not .current: an idle 4090 downclocks its link to Gen1 (2026-09-14, a
# Gen4 x16 host read "Gen1 x16" and failed) — the negotiated maximum is the link.
GEN=$(Q pcie.link.gen.max); W=$(Q pcie.link.width.max)
if [ "${GEN:-0}" -ge $PCIE_GEN ] && [ "${W:-0}" -ge 16 ]; then pass pcie "Gen$GEN x$W"
elif [ "${GEN:-0}" -ge $PCIE_GEN ] && [ "${W:-0}" -ge $PCIE_W ]; then warn pcie "Gen$GEN x$W — the reference 4090 was x8 too; x16 would stream FLUX faster"
else fail pcie "Gen$GEN x$W — below Gen$PCIE_GEN x$PCIE_W; FLUX streams 34 GB per step over this link"; fi

# ── Power cap / throttle ──────────────────────────────────────────────────
PL=$(Q power.limit); PMAX=$(Q power.max_limit)
if awk "BEGIN{exit !($PL >= 0.9*$PMAX)}"; then pass power "${PL} W of ${PMAX} W"
else warn power "capped at ${PL} W of ${PMAX} W — throttled host"; fi
UTIL=$(Q utilization.gpu)

# ── Network (pod-side download) ───────────────────────────────────────────
NET=$(curl -s -L -o /dev/null -m 10 -w "%{speed_download}" "$NET_URL" 2>/dev/null); NET=${NET%.*}; NET=$(( ${NET:-0} / 1000000 ))
if [ "$NET" -ge $NET_MIN ]; then pass network "${NET} MB/s single stream"
elif [ "$NET" -ge 15 ]; then warn network "${NET} MB/s single stream — 93 GB of models ≈ $((93000/NET/4/60)) min with aria2c"
else fail network "${NET} MB/s — provisioning would take hours (the stalled 5090 host looked like this)"; fi

# ── Disks ─────────────────────────────────────────────────────────────────
disk() {  # label dir
  local f="$2/.hc.$$" out
  out=$(dd if=/dev/zero of="$f" bs=1M count=1024 oflag=direct 2>&1 | tail -1); local wr=$(echo "$out" | grep -o "[0-9.]* [MG]B/s")
  out=$(dd if="$f" of=/dev/null bs=1M iflag=direct 2>&1 | tail -1); local rd=$(echo "$out" | grep -o "[0-9.]* [MG]B/s"); rm -f "$f"
  local rdm=$(echo "$rd" | awk '{v=$1; if ($2=="GB/s") v=v*1000; print int(v)}')
  if [ "${rdm:-0}" -ge $DISK_MIN ]; then pass "$1" "read $rd · write $wr"; else warn "$1" "read $rd · write $wr — slower than NVMe; copy models here anyway if it beats the volume"; fi
}
disk disk:/root /root
mountpoint -q /workspace && disk disk:/workspace /workspace

# ── GPU compute (bf16 matmul burst) ───────────────────────────────────────
if [ "${UTIL:-0}" -gt 20 ]; then warn compute "skipped — GPU is ${UTIL}% busy (a render is running)"
else
  TFLOPS=$("$PY" - <<'EOF' 2>/dev/null
import torch, time
a=torch.randn(8192,8192,device="cuda",dtype=torch.bfloat16); b=torch.randn_like(a)
for _ in range(3): a@b
torch.cuda.synchronize(); n=0; t=time.time()
while time.time()-t < 5: a@b; n+=1
torch.cuda.synchronize(); dt=time.time()-t
print(int(2*8192**3*n/dt/1e12))
EOF
)
  want=${TF[$SHORT]:-100}
  if [ "${TFLOPS:-0}" -ge "$want" ]; then pass compute "${TFLOPS} TFLOPS bf16 (want ≥ $want)"
  elif [ "${TFLOPS:-0}" -ge $((want*7/10)) ]; then warn compute "${TFLOPS} TFLOPS bf16 — below the ${want} a healthy $SHORT reaches (shared or hot?)"
  else fail compute "${TFLOPS:-0} TFLOPS bf16 — want ≥ $want; MIG slice, throttled or torch cannot see the card"; fi
fi

# ── ComfyUI + the real chunk ──────────────────────────────────────────────
if curl -sf -o /dev/null http://127.0.0.1:8188/object_info; then
  LOG=/workspace/comfyui.log
  if [ -f "$LOG" ]; then
    grep -aq "backend triton.*'disabled': False\|backend cuda.*'disabled': False" "$LOG" && pass kitchen "an optimized comfy_kitchen backend is enabled" || fail kitchen "cuda AND triton backends disabled — int8/fp8 run eager (add --enable-triton-backend)"
    grep -aq "sage\|flash" "$LOG" && pass attention "$(grep -ao 'Using .* attention' "$LOG" | head -1)" || warn attention "$(grep -ao 'Using .* attention' "$LOG" | head -1 || echo 'unknown') — no sage/flash kernel"
  fi
  if [ "${1:-}" = "--chunk" ] && [ -f /workspace/chunk-prompt.json ]; then
    t0=$(date +%s)
    id=$("$PY" - <<'EOF'
import json,urllib.request
p=json.load(open("/workspace/chunk-prompt.json"))
r=urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8188/prompt",data=json.dumps({"prompt":p}).encode(),headers={"content-type":"application/json"}))
print(json.load(r)["prompt_id"])
EOF
)
    while ! curl -sf "http://127.0.0.1:8188/history/$id" | grep -q '"status_str"'; do sleep 5; done
    T=$(( $(date +%s) - t0 )); ref=${CHUNK[$SHORT]:-$CHUNK_REF}
    if [ $T -le $((ref*12/10)) ]; then pass chunk "${T} s (healthy $SHORT: ~${ref} s)"; else fail chunk "${T} s — a healthy $SHORT does it in ~${ref} s"; fi
  fi
else
  warn comfyui "not answering on 8188 — kitchen/attention/chunk checks skipped"
fi

echo "── $fails FAIL · $warns WARN $( [ $fails -gt 0 ] && echo '→ terminate this host' || echo '→ keep it')"
exit $fails
