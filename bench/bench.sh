#!/usr/bin/env bash
# One-shot benchmark of a fresh RunPod ComfyUI pod against the two prompt
# graphs captured from the 4090 pod (chunk-prompt.json, still-prompt.json).
# Usage: bash bench.sh <pod1-proxy-url>      (runs provisioning first)
#        bash bench.sh --run                 (ComfyUI already provisioned)
set -uo pipefail
POD1=${1:-}
COMFY=/workspace/runpod-slim/ComfyUI
IMGS="refine-charref_00040_.png char-mila-a455d2b998.png char-mila-35fe2102f7.png char-mila-6a12631c32.png"

if [ "$POD1" != "--run" ]; then
  echo "== provision =="
  bash /workspace/setup.sh 2>&1 | grep -v "^  have" | tail -20
  echo "== inputs from pod 1 =="
  mkdir -p $COMFY/input $COMFY/models/loras
  for f in $IMGS; do curl -sf -o "$COMFY/input/$f" "$POD1/view?filename=$f&type=input" && echo "  got $f"; done
  [ -s $COMFY/models/loras/Mila.safetensors ] || { curl -sf -o $COMFY/models/loras/Mila.safetensors "$POD1/view?filename=Mila.safetensors&type=input"; ls -la $COMFY/models/loras/Mila.safetensors; }
  echo "--enable-triton-backend" > /workspace/runpod-slim/comfyui_args.txt
  echo "== restart ComfyUI with triton backend =="
  pkill -f "main.py --listen" ; sleep 3
  cd $COMFY && source .venv-cu128/bin/activate && nohup python main.py --listen 0.0.0.0 --port 8188 --enable-cors-header --enable-triton-backend > /workspace/comfyui.log 2>&1 < /dev/null &
  for i in $(seq 1 60); do curl -sf -o /dev/null http://127.0.0.1:8188/object_info && break; sleep 3; done
  grep -a "backend triton\|backend cuda\|attention\|Device:" /workspace/comfyui.log | cut -c1-110
  bash /workspace/setup.sh --verify | grep -v "^  ok"
fi

echo "== bench =="
LOG=/workspace/comfyui.log
run() {  # name file
  local start=$(wc -l < $LOG)
  local id=$(python3 - "$2" <<'EOF'
import json,sys,urllib.request
p=json.load(open(sys.argv[1]))
r=urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8188/prompt",data=json.dumps({"prompt":p}).encode(),headers={"content-type":"application/json"}))
print(json.load(r)["prompt_id"])
EOF
)
  local t0=$(date +%s)
  while ! curl -sf "http://127.0.0.1:8188/history/$id" | grep -q '"status_str"'; do sleep 5; done
  local t1=$(date +%s)
  echo "$1: wall $((t1-t0)) s  $(curl -sf "http://127.0.0.1:8188/history/$id" | grep -o '"status_str": *"[a-z]*"')"
  sed -n "$((start+1)),\$p" $LOG | grep -a "Prompt executed\|Error\|error" | cut -c1-140
  sed -n "$((start+1)),\$p" $LOG | tr "\r" "\n" | grep -o "[0-9]*/[0-9]* \[[0-9:]*<00:00, *[0-9.]*s\?/it\]" | tail -1
  nvidia-smi --query-gpu=name,utilization.gpu,memory.used,temperature.gpu,power.draw,clocks.sm --format=csv,noheader
}
run "chunk cold" /workspace/chunk-prompt.json
run "still cold" /workspace/still-prompt.json
# warm: same graphs again with a different seed so nothing is cached
python3 - <<'EOF'
import json
for n in ("chunk","still"):
    p=json.load(open(f"/workspace/{n}-prompt.json"))
    for node in p.values():
        for k in ("seed","noise_seed"):
            if k in node["inputs"] and isinstance(node["inputs"][k], int): node["inputs"][k]+=1
    json.dump(p,open(f"/workspace/{n}-prompt-warm.json","w"))
EOF
run "chunk warm" /workspace/chunk-prompt-warm.json
run "still warm" /workspace/still-prompt-warm.json
echo "== done =="
