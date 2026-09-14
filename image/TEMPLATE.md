# The `indievibe-comfy` RunPod template

One private template instead of the stock **ComfyUI – CUDA 12.8** plus twenty
minutes of SSH. The image (`image/Dockerfile`) bakes what `setup.sh` used to do
on every fresh pod; `image/entrypoint.sh` does the per-boot part (NVMe copy,
triton flag, scripts) before ComfyUI starts. Rationale and the measurements
behind it: `docs/pod-render-target.md`, 2026-09-12.

What it changes — and what it does not:

| | before | with the template |
|---|---|---|
| 4090 on the EU-RO-1 volume | pull → scp scripts → `--nvme` → args → relaunch → verify, by hand (~10 min hands-on) | pull → ready, unattended (~4–5 min) |
| any other card (no volume) | + git checkout + pip + 30 min download, by hand | pull → ComfyUI up; models download in the background (~30 min); `healthcheck.sh --chunk` gates readiness |
| render speed | 66 s chunk on a 4090 | **unchanged** — the sampler is the sampler |
| model upload from the laptop | never (0.6 MB/s) | never — the volume, the HF mirrors, or `MILA_LORA_URL` |

## Two ways to get the same boot

- **A — no build (do this first).** The template points at the stock RunPod image
  and its **Start command** fetches our five scripts from a URL and runs
  `entrypoint.sh`. Same boot, same result; the only differences: a fresh pod
  spends 1–3 extra minutes checking v0.34.0 out and relaunching ComfyUI once
  (the image would have it baked), and the boot needs the script host reachable.
  On the EU-RO-1 volume there is no difference at all — the volume's ComfyUI is
  already at the tag.
- **B — the image.** Everything baked; the start command stays blank. Worth it
  only if A's minute-or-three on fresh cards ever matters.

### A. The scripts are public, then set two fields

The `pod/` folder is mirrored in the public repo
**https://github.com/alihariri/indievibe-pod** (created 2026-09-12; it holds no
secrets — the LoRA URL and any token are RunPod Secrets, never in a script).
A file is served at `https://raw.githubusercontent.com/alihariri/indievibe-pod/main/<path>`
and always as the newest commit, so pushing a fix updates every future boot.
**When a pod script changes here, push the same file there** — the repo is a
mirror, the project is the source. Then in the template (everything else
exactly as in §2):

| Field | Value (variant A) |
|---|---|
| Container image | `runpod/comfyui:1.2.0-comfyuiv0.30.0-cuda12.8` (public — no registry auth) |
| Environment variable | `IV_SCRIPTS_URL` = `https://raw.githubusercontent.com/alihariri/indievibe-pod/main` |
| Start command | the JSON below, pasted as one line |

```
{"entrypoint":["bash","-c"],"cmd":["set -e; B=\"$IV_SCRIPTS_URL\"; D=/opt/indievibe; mkdir -p $D/bench; curl -fsSL \"$B/setup.sh\" -o $D/setup.sh; curl -fsSL \"$B/healthcheck.sh\" -o $D/healthcheck.sh; curl -fsSL \"$B/image/entrypoint.sh\" -o $D/entrypoint.sh; for f in bench.sh chunk-prompt.json still-prompt.json; do curl -fsSL \"$B/bench/$f\" -o $D/bench/$f; done; chmod +x $D/*.sh $D/bench/*.sh; exec $D/entrypoint.sh"]}
```

The JSON form replaces the image's entrypoint (`/start.sh`) with ours; a plain
bash line would have been handed to `/start.sh` as arguments instead.
`entrypoint.sh` ends with `exec /start.sh`, so RunPod's own boot (sshd, Jupyter,
FileBrowser, ComfyUI) still runs — after ours.

### B. Build and push (once per ComfyUI tag)

The laptop has no Docker. Two ways:

- **GitHub Actions** (recommended): a private repo holding `pod/`, plus
  `image/build.yml` copied to `.github/workflows/pod-image.yml` and the two
  Docker Hub secrets. Run the workflow → `<user>/indievibe-comfy:v0.34.0-cu128`.
- **Any machine with Docker**: `cd pod && docker build -f image/Dockerfile
  --build-arg COMFY_TAG=v0.34.0 -t <user>/indievibe-comfy:v0.34.0-cu128 . && docker push …`

Make the Docker Hub repository **private** (it carries nothing secret, but it
is ours). The base tag is pinned in the Dockerfile; bump it when RunPod ships a
newer cu128 image and re-run `healthcheck.sh --chunk` before trusting it.

## 2. The template — console → Templates

**Created 2026-09-12 from Ali's Chrome: `indievibe-comfy`, id `ayepypvg7p`, variant A**
(stock image, the JSON start command, `IV_SCRIPTS_URL` + `PUBLIC_KEY`, 150 GB container
disk, 0 GB volume disk, `/workspace`, HTTP 8188/8080/8888, TCP 22; GPU tab: the five
recommended cards, A100 ×3 + V100 ×2 incompatible, CUDA 12.8–13.3, min vRAM 24 GB —
every field read back after a page reload). Not set yet: `MILA_LORA_URL` and
`HF_TOKEN` (no RunPod Secrets exist; add them under Settings → Secrets, then the env
rows here). Field for field, as the console shows them, for a rebuild:

| Field | Value |
|---|---|
| Template name | `indievibe-comfy` |
| Template type | **Pods** |
| Compute type | **NVIDIA GPU** |
| Public template | **off** |
| Container image | A: `runpod/comfyui:1.2.0-comfyuiv0.30.0-cuda12.8` · B: `docker.io/<user>/indievibe-comfy:v0.34.0-cu128` |
| Registry authentication | A: none · B: the Docker Hub credential (Settings → Container registry auth: username + the same access token) |
| Start command | A: the JSON above · B: *blank* — the image's ENTRYPOINT is the boot |
| Container disk | **150 GB** (the NVMe copy of the models needs ≥ 100 GB) |
| Volume disk | **0 GB** when deploying onto the network volume (it mounts at `/workspace` and replaces this); **150 GB** for a card in another region, so a Stop keeps the downloaded models |
| Persistent storage mount path | `/workspace` |
| HTTP ports | `8188` (ComfyUI), `8080` (FileBrowser), `8888` (Jupyter) |
| TCP ports | `22` |
| Environment variables | A only: `IV_SCRIPTS_URL` = `https://raw.githubusercontent.com/alihariri/indievibe-pod/main`. Both: `PUBLIC_KEY` = the `~/.ssh/runpod_ed25519.pub` line (SSH works from the first boot, no console key injection — the migrated pod lost that once); `MILA_LORA_URL` = `{{ RUNPOD_SECRET_mila_lora_url }}` (optional; a private URL the LoRA can be fetched from when it is not on the volume); `HF_TOKEN` = `{{ RUNPOD_SECRET_hf_token }}` (optional, only if a mirror turns gated) |

**GPU compatibility tab** — encode the pod-selection rules so the wrong card
cannot be picked (docs/pod-render-target.md, "Lessons"):

- Compatible: **RTX 4090, RTX 5090, L40S, RTX 6000 Ada, RTX PRO 6000** (FP8 cards).
- Incompatible: A100 PCIe, A100 SXM, A100 SXM 40GB, Tesla V100, V100 SXM2
  (no FP8 — the A100 lost to the laptop on the same graph).
- Allowed CUDA versions: **12.8 and up**. Minimum vRAM: **24 GB**.

## 3. Deploy with it

`https://console.runpod.io/deploy` → template `indievibe-comfy` → region = the
EU-RO-1 volume for a 4090, "Any region" otherwise → the card → name
`indievibe-<card>` → Deploy. Then only the checks remain:

```bash
ssh -i ~/.ssh/runpod_ed25519 -p <port> root@<ip> 'tail -5 /workspace/indievibe-boot.log; bash /workspace/healthcheck.sh'
# volume pod: ready when the boot log says "handing over"; then
bash /workspace/setup.sh --verify && bash /workspace/healthcheck.sh --chunk
# fresh pod: poll `tail -3 /workspace/setup.log` until "done downloading", then the same two lines
```

`docs/pod-provision.md` step 4 is now those lines. Stop/Terminate rules are
unchanged: Stop wipes the container disk (the NVMe copy is redone by the next
boot, unattended), the network volume keeps the models.

## What the boot does, in order (`image/entrypoint.sh`)

1. Copies `setup.sh`, `healthcheck.sh`, `bench/*` to `/workspace/` (fresh from the image).
2. Appends `--enable-triton-backend` to `comfyui_args.txt` if missing.
3. Existing `/workspace/runpod-slim/ComfyUI`: `setup.sh --code` (checkout at the
   tag + pip, a no-op when current), then `setup.sh --nvme` if the models are on
   the volume.
4. Fresh pod, in the background after `/start.sh` has copied the baked tree
   (→ `/workspace/setup.log`): if that tree is not at the tag (variant A: v0.30.0),
   `setup.sh --code` and one ComfyUI relaunch with the args file; then
   `setup.sh --models` when there are no models.
5. `MILA_LORA_URL` set and no `models/loras/Mila.safetensors`: fetched in the
   background → `/workspace/lora.log`.
6. `exec /start.sh` — RunPod's own boot (sshd, Jupyter, FileBrowser, ComfyUI on 8188).

Never change `.runpod-bundle-version` in the image: a differing marker makes
`/start.sh` rsync `--delete` the baked tree over an existing volume copy, and
`models-vol/` (the volume's 90 GB) is not on its exclude list. **It happened on the
first boot (2026-09-14):** a hand-made volume tree has NO marker, which counts as
"differing" — the 90 GB went and were copied back from NVMe. Step 3 of the entrypoint
now writes the image's manifest into the tree so `/start.sh` finds the bundle
"current". First-boot record: `docs/pod-render-target.md`, 2026-09-14.
