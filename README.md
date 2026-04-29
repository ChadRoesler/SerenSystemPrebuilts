# Nvidia Jetson Prebuilt Packages (Xavier + Orin)

Building this shit from source on Jetson takes forever, so this repo is the shortcut: prebuilt artifacts for Xavier and Orin Nano.

Current targets:

- Jetson AGX Xavier (JetPack 5 / Volta)
- Jetson Orin Nano (JetPack 6 / Ampere)

## What This Builds

| Artifact | Notes |
|---|---|
| `llama-server-<platform>-aarch64` | llama.cpp server binary built with CUDA for the detected platform |
| `torch-2.1.0-cp310-*.whl` | PyTorch 2.1.0 wheel for Python 3.10 |
| `torchvision-0.16.0-cp310-*.whl` | torchvision 0.16.0 wheel (built against torch) |
| `gasket-<jp>-<platform>-aarch64.ko` | Coral TPU gasket kernel module |
| `apex-<jp>-<platform>-aarch64.ko` | Coral TPU apex kernel module |
| `coral-<jp>-<platform>.manifest` | Build manifest with kernel/version metadata for module validation |

## Platform Detection and Tags

The script reads `/etc/nv_tegra_release`, figures out what box it is on, and tags output names accordingly:

- `R35` -> `jp5`, `xavier`, CUDA arch `72`, torch arch list `7.2`
- `R36` -> `jp6`, `orin`, CUDA arch `87`, torch arch list `8.7`

Example output names:

- `llama-server-xavier-aarch64`
- `llama-server-orin-aarch64`
- `gasket-jp5-xavier-aarch64.ko`
- `apex-jp6-orin-aarch64.ko`

## Usage

Build everything:

```bash
bash build-prebuilts.sh --all
```

Build only what you want:

```bash
bash build-prebuilts.sh --llama --coral
bash build-prebuilts.sh --pytorch --torchvision
bash build-prebuilts.sh --coral
```

Useful options:

- `--build-dir DIR` to place large source/build trees (important for pytorch)
- `--output-dir DIR` to choose where artifacts are staged
- `--max-jobs N` to cap compile parallelism for memory-limited devices

## Runtime Targets

- **Jetson AGX Xavier:** JetPack 5.x / L4T R35, Volta (`sm_72`)
- **Jetson Orin Nano:** JetPack 6.x / L4T R36, Ampere (`sm_87`)

## Notes

- Coral modules are kernel-version-sensitive. Check the generated manifest before loading `gasket.ko` and `apex.ko` so you do not slam the wrong modules into the wrong kernel.
- The script writes build metadata to `BUILD_INFO_<platform>_<jp>.txt` in the output directory so you can see exactly what got built.
- If you want to build torchvision make sure you build pytorch first.
- Use tmux when running it on headless when doing pytorch.
