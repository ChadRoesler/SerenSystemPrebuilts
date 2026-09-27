# Seren System Prebuilts (Xavier + Orin + Spark + Host)

Building this shit from source on Jetson takes forever, and DeadSnakes doesnt have a Python 3.10 for Ubunutu 20.04, which is required to flash a Xavier, so this repo is the shortcut: prebuilt artifacts for Xavier, Orin Nano, DGX Spark, and your Host.

Current targets:

- Jetson AGX Xavier (JetPack 5 / Volta, `sm_72`)
- Jetson Orin Nano Super (JetPack 6 / Ampere, `sm_87`)
- NVIDIA DGX Spark (GB10 / Blackwell, `sm_121`)
- Ubuntu 20.04 x86_64 (focal)

Same script, all three boxes: `build-jetson-prebuilts.sh` detects which one it is
on and builds that platform's baseline. The Spark is not a Tegra release and has
no `/etc/nv_tegra_release`, so if detection comes up empty the script **refuses
to guess** rather than defaulting to Xavier and quietly handing you `sm_72`
artifacts for an `sm_121` GPU. Pass `--platform spark` and it stops asking.

## What This Builds

### Jetson Builds

| Artifact | Notes |
|---|---|
| `llama-server-<jp>-<platform>-aarch64` | llama.cpp server binary built with CUDA for the detected platform |
| `whisper-server-<jp>-<platform>-aarch64` | whisper.cpp speech-to-text server, the same static CUDA build as llama-server (`--whisper`, pinned in `lib/pins.sh`) |
| `torch-<ver>-cp3XX-*.whl` | PyTorch wheel, built from source against this box's CUDA arch |
| `torchvision-<ver>-cp3XX-*.whl` | torchvision wheel (compiled against the torch above) |
| `gasket-<jp>-<platform>-aarch64.ko` | Coral TPU gasket kernel module |
| `apex-<jp>-<platform>-aarch64.ko` | Coral TPU apex kernel module |
| `coral-<jp>-<platform>.manifest` | Build manifest with kernel/version metadata for module validation |
| `python3.XX-<jp>-<platform>-aarch64.tar.gz` | Python, from python.org source |
| `sqlite3.45-<jp>-<platform>-aarch64.tar.gz` | SQLite for use for ChromaDB |
| `bitsandbytes-<ver>+sm<arch>-cp3XX-*.whl` | Required on Xavier, a spare everywhere else — see below |
| `vllm/` | vLLM wheel + the exact torch/torchvision it pins (not Xavier) |
| `vendor/` | wheels this box uses but does not build, mirrored with checksums |
| `wheelhouse/` | **every dependency in the closure**, compiled on this box for this interpreter |
| `requirements-<platform>-<jp>.lock` | produced by an actual offline install from `wheelhouse/` |
| `apt-toolchain/` | Ubuntu's build toolchain `.deb`s — the part of the base that ages out first. A local backup for the box; **not in a release** |
| `apt/` | the CUDA / cuDNN / L4T `.deb` packages this box runs — a local backup for the box, **never in a release** (NVIDIA's terms) |
| `INSTALL.sh` | generated per folder — installs whatever is actually in it |
| `NOTICES` | generated per folder — what each artifact was built from, and its license |
| `SELFTEST-<platform>-<jp>.txt` | what was asserted on the real GPU, and the result |
| `SYSTEM-PACKAGES-*.txt`, `SYSTEM-PIP-*.txt` | the box as it stood on build day |

### The wheelhouse is the point

A torch wheel is not installable on its own — pip still goes to PyPI for
`filelock`, `sympy`, `networkx`, `jinja2`, `fsspec`, `typing-extensions`,
`mpmath`. Every one of those is a live repository serving a file somebody else
has to keep serving, which is the exact dependency this repo exists to remove.
An archive that holds the four-hour build and none of the five-second downloads
fails on the day it is needed.

`--wheelhouse` uses `pip wheel`, not `pip download`, and on aarch64 that
distinction is the whole thing: plenty of these have no published wheel for this
arch and interpreter, so `pip download` would archive an sdist you have to
compile later on a box that may no longer have a compiler or the headers.
`pip wheel` compiles them **now**, here, into something that installs with
`--no-index` in four years.

The default closure only covers what this script built. **Point
`--wheelhouse-reqs` at your app's requirements** — that is the part which
actually disappears from PyPI.

### And the layer under all of it

`--cuda-debs` caches the CUDA / cuDNN / L4T `.deb`s the box is running. Every
torch wheel here links `libcudart`, `libcublas` and `libcudnn`; those come from
NVIDIA's apt repos, which are live repositories on a support clock, and
JetPack 5's will age out. The day it does, a reflashed Xavier cannot get the
toolkit back and every wheel in this archive is inert — correct, verified, and
unloadable. It is gigabytes. It is also the only part of the stack nobody
outside NVIDIA can rebuild.

### The held baseline, per platform

The versions are not "whatever the index serves today" — they are pinned per
platform in `detect_platform`, and each pin has a reason written next to it.

| | Xavier (jp5) | Orin (jp6) | Spark (jp7) |
|---|---|---|---|
| CUDA arch | `sm_72` | `sm_87` | `sm_121` |
| Python | 3.10.14 | 3.10.14 | 3.12.8 |
| PyTorch | 2.1.0 | 2.11.0 | 2.11.0 |
| torchvision | 0.16.0 | 0.26.0 | 0.26.0 |
| bitsandbytes | 0.45.5 | 0.50.2 | 0.50.2 |
| numpy (build) | 1.24.4 | 2.2.6 | 2.2.6 |
| vLLM | **none** — no sm_72 kernels | 0.26.0 | 0.26.0 |

Xavier is the one pinned backwards, and CUDA 12.2 is why: torch 2.1.0 is the
last that builds against it, 0.45.5 is the last bitsandbytes that accepts torch
2.1.0, and numpy 2 headers postdate torch 2.1 entirely. Everything else builds
against numpy 2.x on purpose — an extension compiled against the 2.x headers
runs under numpy 1.19+ *and* 2.x, while one compiled against 1.26 refuses to
import under numpy 2 at all.

vLLM is absent on Xavier as a hardware fact, not a packaging one: its
`CUDA_SUPPORTED_ARCHS` is a discrete list that starts at 7.0/7.5 and 7.2 is in
none of its branches. That is why llama.cpp is not optional on that box.

#### Why bitsandbytes matters most on Xavier

The PyPI aarch64 wheel ships cubins for **sm_75, sm_80 and sm_90** (and sm_100–121 in its
CUDA 13 libraries). CUDA cubins are binary-compatible *upward* within a major generation,
so:

- **Orin (sm_87)** — covered by the stock wheel's sm_80 cubin. Built anyway, as a spare.
- **Spark (sm_121)** — covered by the wheel's CUDA 13 libraries. Also just a spare.
- **Xavier (sm_72)** — *not* covered by anything, at any version. Same major as sm_75 but a
  lower minor, and the only PTX in the wheel targets sm_90, so there's no JIT escape either.
  This one is **required**.

The nasty part is that it fails **silently**: `pip install` works, `import bitsandbytes` works,
and it only dies when a kernel launches — hours into a fine-tune. Hence the `+sm72` stamp in the
version, so `pip show bitsandbytes` tells you which build you actually have, and hence the
`cuobjdump` check in the build phase that refuses to ship a wheel missing its own architecture.

Pinned to **0.45.5**: the last release that accepts `torch>=2.0`, and Xavier is on torch 2.1.0.
At sm_72 you get 4-bit (NF4/FP4) and the 8-bit optimizers; you do **not** get LLM.int8(), which
bitsandbytes gates on compute capability ≥ 7.5. That's Volta, not a build flag.

### Host Builds

`build-host-prebuilts.sh`, for the x86_64 focal box (the NUC). Its release
tag follows the same `YYYYMMDD_<platform>` rule as the Jetson folders, with
`host-focal-x86_64` as the platform.

| Artifact | Notes |
|---|---|
| `python-3.10.14-focal-x86_64.tar.gz` | Python 3.10 from python.org source, `altinstall` layout, extracts to `/usr/local` |
| `libsqlite3-3.45.1-focal-x86_64.tar.gz` | SQLite 3.45 (FTS5, JSON1) for ChromaDB; Python above is linked against it |
| `PROVENANCE-host-focal-x86_64.txt`, `SHA256SUMS` | the same records the Jetson folders carry |

## Platform Detection and Tags

The script reads `/etc/nv_tegra_release`, figures out what box it is on, and tags output names accordingly:

- `R35` -> `jp5`, `xavier`, CUDA arch `72`, torch arch list `7.2`
- `R36` -> `jp6`, `orin`, CUDA arch `87`, torch arch list `8.7`
- no tegra release, but `spark`/`GB10` in the device-tree model, `nvidia-smi` or
  DMI product name -> `jp7`, `spark`, CUDA arch `121`, torch arch list `12.1`
- none of the above -> **fails**, and tells you to pass `--platform`. It will not
  guess a GPU architecture.

`--platform xavier|orin|spark` overrides all of it, and is checked first: someone
standing in front of the machine beats a heuristic.

Example output names:

- `llama-server-jp7-spark-aarch64`
- `llama-server-jp5-xavier-aarch64`
- `whisper-server-jp6-orin-aarch64`
- `gasket-jp5-xavier-aarch64.ko`
- `apex-jp6-orin-aarch64.ko`

Artifacts land in `<output-dir>/<platform>-<jp>/`, one folder per box, because
wheel filenames carry the Python tag (`cp310`) but **not** the GPU arch — a
Xavier torch and a Spark torch are byte-different and identically named. Each
folder also gets:

- `PROVENANCE-<platform>-<jp>.txt` — the machine, the toolchain, and the exact
  upstream commit behind every artifact. **One stanza per run, appended**; a
  later run never rewrites what an earlier one recorded.
- `SHA256SUMS` — every file in the folder, one line per path, merged across
  runs. Verify offline with `sha256sum -c SHA256SUMS`.
- `sources/` — with `--keep-sources`, the exact trees that were compiled, so the
  thing can be *rebuilt* and not merely re-downloaded
- `INSTALL.sh` — generated from what is in the folder, so the folder can be
  consumed without this repo existing
- `NOTICES` — generated the same way: what each artifact was built from and
  under what license. The full table is `THIRD-PARTY-NOTICES.md`.

### If your folder predates 2026-09-23

Until then, every run truncated `PROVENANCE`, `SHA256SUMS` and `BUILD_INFO`
before it started, so the records described whichever phases the *last*
invocation ran. A one-minute `--cudadebs` pass on a finished archive left the
torch wheel, the llama binary, the Python tarball and the whole `wheelhouse/`
unlisted — and `sha256sum -c` passed on the debs that remained. The September
2026 archives are in exactly that state.

```bash
bash build-jetson-prebuilts.sh --reindex --output-dir /mnt/nvme/prebuilt
```

rebuilds `SHA256SUMS` from what is on disk, appends an `artifact` line to the
provenance for every file it never recorded, regenerates `INSTALL.sh` and
`NOTICES`, and keeps the old list beside the new one. It builds nothing and
deletes nothing. It cannot recover what the truncation destroyed — the source
commits behind those binaries, that day's selftest verdict — and its stanza
in the provenance says so. **Run it on the box you publish from.** A copy that
went through a tool which re-encoded the `%3a` in the deb filenames is a
different folder, and its checksums would describe files the Jetson does not
have.

`--verify-archive` now fails a folder that has *unlisted* files, not only one
whose listed files mismatch. Verification by omission was the failure this
repo exists to catch in other people's artifacts.

### Pinned sources

Python and SQLite are fetched from python.org and sqlite.org and **checked
against `lib/sources.sha256` before anything compiles**; a mismatch refuses,
an unlisted URL warns and writes the observed hash into the provenance so it
can be pinned on purpose. llama.cpp and gasket-driver default to the refs in
`lib/pins.sh`; `--llama-ref latest` / `--gasket-ref latest` chase HEAD, and the
resolved SHA lands in the provenance either way. Bumping a baseline means
adding its hash to the table first.

## Release tags

One platform folder per release, tagged **`YYYYMMDD_<platform>`** where the
date is the build date and the platform is the folder name: `20260916_orin-jp6`,
`20260916_xavier-jp5`, `20260916_spark-jp7`, `20260916_host-focal-x86_64`. The
date is the *build*, not the upload, so two tags for the same folder are two
different sets of bytes and never the same set re-uploaded. A release carries
the artifacts this repo BUILDS, flat, one asset per file, plus the records
(`SHA256SUMS`, provenance, selftest, `INSTALL.sh`, `NOTICES`). Neither `apt/`
nor `apt-toolchain/` is uploaded: the cached debs are the box's own backup,
not something to host. The driver prints the suggested tag at the
end of every run; `--reindex` before you upload, `--verify-archive` on what
you pulled back down.

## Usage

Build everything:

```bash
bash build-jetson-prebuilts.sh --all
bash build-host-prebuilts.sh --all
```

Build only what you want:

```bash
bash build-jetson-prebuilts.sh --llama --coral
bash build-jetson-prebuilts.sh --pytorch --torchvision
bash build-jetson-prebuilts.sh --coral
bash build-jetson-prebuilts.sh --bitsandbytes   # Xavier only; needs torch installed first
bash build-host-prebuilts.sh --python
```

Per box:

```bash
# Xavier 32GB, NVMe mounted, full send
bash build-jetson-prebuilts.sh --all --keep-sources

# Orin Nano 8GB - two jobs, or it OOMs building torch
bash build-jetson-prebuilts.sh --all --max-jobs 2 --build-dir /mnt/nvme/build

# DGX Spark - say which box it is if detection misses
bash build-jetson-prebuilts.sh --all --keep-sources --platform spark
```

Useful options:

- `--build-dir DIR` to place large source/build trees (important for pytorch)
- `--output-dir DIR` to choose where artifacts are staged
- `--max-jobs N` to cap compile parallelism for memory-limited devices
- `--platform NAME` to force `xavier` / `orin` / `spark`
- `--python-bin PATH` to choose the interpreter that builds the wheels (it is
  what puts the `cpXX` tag in the filename)
- `--keep-sources` to archive the source trees that were actually compiled
- `--vendor` to mirror wheels this box uses but does not build
- `--vllm` to archive vLLM plus the exact torch/torchvision it pins
- `--wheelhouse` / `--wheelhouse-reqs FILE` for the offline dependency closure
- `--cuda-debs` to cache the CUDA/cuDNN/L4T debs (gigabytes)
- `--selftest` to prove the artifacts on the real GPU before you publish them
- `--reindex` to bring a folder's records up to date with its contents
  without rebuilding anything (see above)

`--all` means **all** — every phase the platform supports, including `--python`,
`--sqlite`, `--bitsandbytes`, `--vllm`, `--cuda-debs`, `--wheelhouse`,
`--vendor` and a `--selftest` at the end. Phases the box cannot support skip
with a stated reason, and the run ends with a list of exactly what is *not* in
the archive.

## Verifying it actually works

Nothing in a build log proves an artifact runs. A torch wheel built for the
wrong architecture imports fine and dies at the first kernel launch — months
later, on the box you were relying on the backup for. That is the same silent
failure the `cuobjdump` check in the bitsandbytes phase exists to prevent, and
it is not a bitsandbytes property.

So `--selftest` installs the archive into a throwaway venv **with the index
switched off** and launches real kernels on the real device:

- `sm_<arch>` is in `torch.cuda.get_arch_list()`
- `torch.cuda.get_device_capability()` matches what the wheel was built for
- a GPU matmul agrees with the CPU
- `torchvision.ops.nms` runs on CUDA tensors (catches the classic
  torchvision/torch C-extension mismatch)
- bitsandbytes does a 4-bit round trip — which *launches a kernel*, the only way
  the sm_72 problem ever surfaces
- `llama-server` resolves its shared libraries, and the `.ko` vermagic matches
  the running kernel

It fails the run if any of that is untrue. The artifacts stay on disk; you just
do not get told the archive is good when it is not.

```bash
# after a build, on the same box
bash build-jetson-prebuilts.sh --selftest

# the restore rehearsal: on a folder pulled off a release tag, builds nothing
bash build-jetson-prebuilts.sh --verify-archive --output-dir /mnt/usb/prebuilt
```

`--verify-archive` checks `SHA256SUMS`, installs the folder with `--no-index`,
and runs the same assertions. An archive is only as good as its last restore.

## Build isolation

Every compiling phase gets its own venv under
`<build-dir>/seren-build-venvs/<phase>`. Nothing one phase pip-installs can
reach another: torchvision compiles against the torch wheel *this run* produced,
vLLM installs its own exactly-pinned torch without touching it, and bitsandbytes
gets a clean interpreter either way. The venvs are created from `--python-bin`,
so every wheel keeps the same `cpXX` tag it always had. That directory is
disposable — delete it to start the dependency graph over.

This is also what makes the script work on Ubuntu 24.04 (the Spark), where the
system interpreter is marked `EXTERNALLY-MANAGED` and every `pip install --user`
is refused outright.

## Licensing

The scripts are AGPL-3.0-or-later (`LICENSE`). The payloads are other people's
work under their own terms — PyTorch (BSD-3), llama.cpp (MIT), bitsandbytes
(MIT), vLLM (Apache-2.0), gasket-driver (GPL-2.0, it is a kernel module),
CPython (PSF), SQLite (public domain), Ubuntu's toolchain packages (each their
own). `THIRD-PARTY-NOTICES.md` has the table; every platform folder carries a
generated `NOTICES` saying the same. `apt/` — NVIDIA's CUDA, cuDNN, TensorRT
and L4T debs — is cached for the box that built it and is **never published**.

## Runtime Targets

- **Jetson AGX Xavier:** JetPack 5.x / L4T R35, Volta (`sm_72`)
- **Jetson Orin Nano Super:** JetPack 6.x / L4T R36, Ampere (`sm_87`)
- **NVIDIA DGX Spark:** DGX OS / Ubuntu 24.04, GB10 Blackwell (`sm_121`)
- **Ubuntu 20.04:** Focal x86_64

## Notes

- Coral modules are kernel-version-sensitive. Check the generated manifest before loading `gasket.ko` and `apex.ko` so you do not slam the wrong modules into the wrong kernel.
- The script writes build metadata to `BUILD_INFO_<platform>_<jp>.txt` in the output directory so you can see exactly what got built.
- Build order is enforced by the script now (sqlite before python, python before
  pytorch, pytorch before torchvision/bitsandbytes/vllm). You no longer have to
  remember it, but the dependency warnings will tell you when you asked for a
  phase without the thing it needs.
- Use tmux when running it on headless when doing pytorch. It is still hours.
- Coral `.ko` modules are for the **M.2/PCIe** Edge TPU, including one in a
  USB4/Thunderbolt enclosure on the Spark. The Coral **USB Accelerator** needs
  none of this — `apt install libedgetpu1-std`, a udev rule, and the plugdev
  group.
- Don't run the build script under `sudo`. It escalates for the parts that need
  root; running the whole thing as root breaks `nvcc` discovery and `pip
  --user`, and leaves root-owned artifacts behind.
- `--selftest` is never treated as "already done" by the resume state. Every
  other phase is expensive and resumable; a verification you skipped because you
  ran it last week is not a verification.
- Coral `.ko` files are welded to the exact running kernel. One `apt upgrade`
  that bumps the kernel and `insmod` will refuse them — rebuild `--coral`.
  Packaging them through DKMS would survive that, and has not been done yet.
