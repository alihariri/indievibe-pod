# indievibe-pod

Boot scripts and the RunPod template spec for the IndieVibe ComfyUI render pod.
A mirror of the pipeline's `pod/` folder; the dashboard project is the source of
truth, this repo is what a pod fetches at boot.

- `setup.sh` — ComfyUI at the laptop's tag, the int8/fp8 model set, `--nvme`, `--verify`.
- `healthcheck.sh` — the two-minute host verdict (`--chunk` = the real 6 s render).
- `bench/` — the reference graphs and timing script.
- `image/entrypoint.sh` — the boot: scripts, triton flag, NVMe copy, background downloads, then RunPod's own `/start.sh`.
- `image/TEMPLATE.md` — the template, field by field. Variant A (no build) fetches these files from this repo's raw URL; variant B bakes them (`image/Dockerfile`, `image/build.yml`).

Raw base for the template's `IV_SCRIPTS_URL`:
`https://raw.githubusercontent.com/alihariri/indievibe-pod/main`

Nothing here is secret. The private LoRA URL and any token are RunPod Secrets.
