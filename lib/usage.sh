# ------------------------------------------------------------
# lib/usage.sh - part of build-jetson-prebuilts.sh
# Sourced by the orchestrator; defines functions only, runs nothing.
# ------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 [BUILD FLAGS] [OPTIONS]

Build flags (combine freely):
  --llama              Build llama-server binary (~10 min)
  --pytorch            Build PyTorch wheel (~2-4 hours, RAM hungry)
                       Version: 2.1.0 on jp5/Xavier, 2.3.1 on jp6/Orin
                       (CUDA 12.6 broke 2.1.0's Thrust calls)
  --torchvision        Build torchvision wheel (~30 min, needs torch installed)
                       Version: 0.16.0 on jp5/Xavier, 0.18.1 on jp6/Orin
  --coral              Build Coral TPU kernel modules (gasket + apex, ~5 min)
  --python             Build the baseline Python from python.org source
                       (~30 min). EVERY platform, not just Xavier: "the distro
                       ships one" is a statement about today, and deadsnakes or
                       a distro dropping a series is exactly the failure this
                       archive exists to survive.
  --sqlite             Build the baseline SQLite from sqlite.org source (~5 min).
                       Every platform, same reasoning.
  --bitsandbytes       Build bitsandbytes wheel (Xavier-only, ~15 min)
                       Version 0.45.5 - the last one that accepts torch 2.1.0.
                       Skipped on Nano: the PyPI aarch64 wheel already covers
                       sm_87. Xavier is sm_72 and NOTHING on PyPI covers it,
                       at any version - see the phase comment for the proof.
  --wheelhouse         Build a wheel for EVERY dependency in the closure, on
                       this box, for this interpreter (~20 min). pip wheel, not
                       pip download: on aarch64 half of these have no published
                       wheel and would otherwise be archived as an sdist you
                       must compile on a future box that may have no compiler.
                       This is what makes the archive installable offline - a
                       torch wheel alone still phones PyPI for eight packages.
  --wheelhouse-reqs FILE
                       Also close over these requirements. POINT THIS AT YOUR
                       APP: the default only covers what this script built,
                       which is the part that was never going to disappear.
  --cuda-debs          Cache the CUDA / cuDNN / L4T .deb packages this box is
                       running (GIGABYTES). The deepest dependency here is not
                       on PyPI: every torch wheel links libcudart/libcublas/
                       libcudnn, those come from NVIDIA's apt repos, and
                       JetPack 5's will age out. Cached while it still serves.
  --cuda-debs-match RE Which package names count. Default covers cuda, cudnn,
                       cublas, tensorrt, nvidia-l4t and friends.
  --selftest           Install this archive into a throwaway venv WITH THE
                       INDEX OFF and launch real kernels on the real device:
                       torch's arch list contains sm_<arch>, the device
                       capability matches what was built, a matmul agrees with
                       the CPU, torchvision's cuda nms runs, bitsandbytes does
                       a 4-bit round trip. Fails the run if any of that is
                       untrue - a wheel for the wrong GPU imports fine.
  --all                Build everything this platform supports. ALL of it -
                       python, sqlite, llama, coral, pytorch, torchvision,
                       bitsandbytes, vllm, cuda-debs, wheelhouse, vendor, and
                       a selftest at the end. Phases the box cannot support
                       skip with a stated reason.

Verification (builds nothing):
  --verify-archive     The restore rehearsal. Checks SHA256SUMS, installs the
                       folder into a throwaway venv with --no-index, and runs
                       the same GPU assertions --selftest does. Use it on a
                       folder you pulled off a release tag, on the box you
                       would actually be restoring. An archive is only as good
                       as its last restore. Combine with --output-dir to point
                       at an archive somewhere other than the default.

Options:
  --build-dir DIR      Where source trees get cloned (~30GB for pytorch).
                       Default: /mnt/nvme if mounted, else \$HOME.
                       USE THIS on Xavier - eMMC is only 32GB and pytorch
                       source + objects will fill it.
  --output-dir DIR     Where finished artifacts get staged.
                       Default: /mnt/nvme/prebuilt if mounted, else ~/prebuilt.
  --platform NAME      Force the platform: xavier | orin | spark.
                       REQUIRED ON THE SPARK if detection misses it - there is
                       no /etc/nv_tegra_release on that box, and this script
                       now refuses to guess rather than defaulting to Xavier
                       and silently building sm_72 artifacts for an sm_121 GPU.
  --python-bin PATH    Interpreter that builds the wheels. Default: python3.10
                       on jp5/jp6, python3.12 on the Spark. The cpXX tag in
                       every wheel name comes from whichever one runs, so this
                       is what makes the filename honest.
  --bitsandbytes-version V
                       Override the pinned bitsandbytes. Defaults: 0.45.5 on
                       Xavier (last release accepting torch 2.1.0), 0.50.2
                       elsewhere.
  --vllm               Archive the vLLM synth-data backend as a TRIPLE: vllm
                       plus the exact torch it pins plus the matching
                       torchvision. ms-moe-maker drives either llama.cpp or
                       vLLM for synth data; install this into its OWN venv
                       (~/seren-venvs/vllm) so its torch pin never touches the
                       ms-moe-maker venv. Declines on Xavier - vLLM has no
                       kernels for sm_72 at any version, which is why llama.cpp
                       is not optional on that box.
  --vllm-version V     Override the pinned vLLM. Default 0.26.0 (torch 2.11.0).
  --vendor             Mirror wheels this box USES but does not build (torch,
                       torchvision) into vendor/, with checksums and the index
                       they came from. On the Spark that is the only way torch
                       ends up in the archive - and "NVIDIA ships it" is exactly
                       the assumption this repo exists to stop relying on.
                       The URL is never guessed: pip is asked for whatever is
                       installed, using the index this box already has set.
  --vendor-pkgs "A B"  Which ones. Default: "torch torchvision".
  --vendor-wheel PATH|URL
                       Archive a wheel outright - a file you already have, or a
                       direct download. Repeatable. No discovery, no index, no
                       assumption about where anything is installed: when
                       everything else here is wrong, this still puts the right
                       bits in the archive.
  --vendor-index URL   Extra index to pull vendor wheels from, e.g.
                       https://developer.download.nvidia.com/compute/redist/jp/
  --vendor-python PATH Interpreter to inspect first. Not usually needed - the
                       phase already searches ~/seren-venvs/*/bin/python and
                       /mnt/nvme/seren-venvs/*, because Seren gives every node
                       component its own venv and that is where torch actually
                       lives on a Spark.
  --vendor-torch-version X.Y.Z
  --vendor-torchvision-version X.Y.Z
                       HOLD a specific version rather than mirroring whatever
                       is installed. This is the "better safe than sorry" knob:
                       the archive gets the version you name, whether or not
                       this box happens to be running it.
  --vllm-wheel-only    Mirror vLLM's published aarch64 wheel instead of
                       building it. The escape hatch, not the default - a wheel
                       you fetched is a wheel somebody else has to keep serving.
                       Use it when the source build will not fit on the box.
  --wheelhouse-reqs, --cuda-debs-match: see the build flags above.
  --keep-sources       Also archive the exact source trees that were compiled,
                       as sources/<name>-<shortsha>.tar.gz. THE POINT OF THIS
                       REPO: if an upstream is renamed, rewritten or deleted,
                       a binary alone is a dead end - this is what lets someone
                       rebuild instead of only re-download. Not small.
  --llama-ref REF      Pin llama.cpp to a tag/branch/commit. Unpinned it takes
                       master HEAD; either way the resolved SHA is recorded.
  --gasket-ref REF     Same, for google/gasket-driver.
  --cuda-host-compiler PATH
                       Which g++ nvcc hands the C++ to. The distro default is
                       usually right and sometimes is not: nvcc runs its own
                       frontend over the headers before the host compiler sees
                       them, so a host g++ that is newer than the CUDA release
                       expects produces errors in ATen template code that look
                       like PyTorch bugs and are not. Applied via
                       NVCC_PREPEND_FLAGS, so it does NOT trigger a cmake
                       reconfigure - an interrupted build resumes with it.
                       e.g. --cuda-host-compiler /usr/bin/g++-12
  --max-jobs N         Cap parallel compile jobs (only affects pytorch/torchvision).
                       Default: \$(nproc). On 8GB Nano, set to 2 to avoid OOM.
                       On 16GB Xavier, 4 is safe; 32GB Xavier handles full nproc.
  -h, --help           Show this help

Examples:
  # Xavier 32GB, NVMe mounted, full send
  $0 --all

  # Xavier 16GB, explicit dirs, conservative parallelism
  $0 --pytorch --build-dir /mnt/nvme/build --max-jobs 4

  # Orin Nano 8GB, two cores per build, output to NVMe
  $0 --pytorch --max-jobs 2 --build-dir /mnt/nvme/build

  # Just the fast stuff
  $0 --llama --coral

  # Spark, spare bitsandbytes wheel, explicit platform
  $0 --bitsandbytes --platform spark

  # An archive-of-record build: everything this box supports, sources kept
  $0 --all --keep-sources

  # Spark: mirror the NVIDIA torch wheels this box runs, then build the rest
  $0 --all --keep-sources --platform spark

EVERY PLATFORM BUILDS EVERYTHING FROM SOURCE, against its own held baseline
(see the per-platform block in detect_platform, echoed into the provenance).
Nothing here depends on an index still serving a binary: python comes from
python.org, sqlite from sqlite.org, torch/torchvision/bitsandbytes/llama.cpp
and gasket from their git sources. --vendor is a belt-and-braces addition for
wheels you also want a vendor copy of - not the way anything gets built.

EVERY COMPILING PHASE GETS ITS OWN VENV, at <build-dir>/seren-build-venvs/<phase>.
Nothing one phase pip-installs can reach another: torchvision compiles against
the torch wheel THIS run produced, vLLM installs its own exactly-pinned torch
without touching it, and bitsandbytes gets a clean interpreter either way. The
venvs are created from --python-bin, so every wheel keeps the same cpXX tag.
Delete that directory to start the dependency graph over; it is disposable.

Artifacts land in <output-dir>/<platform>-<jp>/ alongside three records:

  PROVENANCE-<platform>-<jp>.txt   the machine, the toolchain, and the exact
                                   upstream commit behind every artifact
  SHA256SUMS                       verify offline with: sha256sum -c SHA256SUMS
  sources/                         (--keep-sources) the trees that were compiled

Upload one platform folder per release tag. A file that gets separated from its
folder can still be identified by its sha256 in any of the manifests.

NOTE ON MIXED OUTPUT DIRS: wheel filenames carry the Python tag but not the GPU
architecture, so a Xavier torch and a Spark torch can land on each other in one
--output-dir. Use a directory per platform when you are staging backups for more
than one box; the script warns if it spots artifacts from another platform.
EOF
}
