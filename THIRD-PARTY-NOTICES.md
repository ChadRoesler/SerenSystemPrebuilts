# Third-party notices

The scripts in this repository are GPL-3.0-or-later (see `LICENSE`). The
release payloads they produce are **built from other people's work**, and a
folder pulled off a release tag has to carry those terms with it. Each
platform folder gets a generated `NOTICES` file saying the same thing; this is
the source of that text.

| Artifact in the folder | Built from | License | Notes |
|---|---|---|---|
| `torch-*.whl`, `torchvision-*.whl` | [pytorch/pytorch](https://github.com/pytorch/pytorch), [pytorch/vision](https://github.com/pytorch/vision) | BSD-3-Clause | Compiled here for one CUDA arch. The wheel bundles PyTorch's own third-party notices under `torch/` inside the wheel. |
| `llama-server-*` | [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) | MIT | Statically linked against ggml (MIT). Links the CUDA runtime, which is NVIDIA's and is **not** in the release. |
| `bitsandbytes-*.whl` | [bitsandbytes-foundation/bitsandbytes](https://github.com/bitsandbytes-foundation/bitsandbytes) | MIT | Version stamped `+sm<arch>` so `pip show` says which build it is. |
| `vllm/vllm-*.whl` | [vllm-project/vllm](https://github.com/vllm-project/vllm) | Apache-2.0 | Built from source where the GPU supports it; a mirrored wheel is noted as such in the provenance. |
| `gasket-*.ko`, `apex-*.ko` | [google/gasket-driver](https://github.com/google/gasket-driver) | GPL-2.0 | Linux kernel modules; GPL-2.0 is the kernel's term and theirs. Patched here for kernels 6.12+ and 6.13+ (see `phases/coral.sh`); the patches are in the provenance. |
| `python3.*-*.tar.gz` | [python.org](https://www.python.org/ftp/python/) source | PSF-2.0 | Built from the pinned tarball in `lib/sources.sha256`. |
| `sqlite3.45-*.tar.gz` | [sqlite.org](https://www.sqlite.org/) source | Public domain | Built from the pinned tarball in `lib/sources.sha256`. |
| `wheelhouse/*.whl`, `vendor/*.whl` | PyPI and NVIDIA's index, as recorded in the provenance | each package's own | Mirrored or compiled dependencies. Every wheel carries its own `METADATA` with its license field; `requirements-*.lock` names the set. |
| `apt-toolchain/*.deb` | Ubuntu | each package's own (GPL, LGPL, BSD, MIT) | Cached locally as the box's backup; not part of a release. Copyright files are inside each `.deb` at `usr/share/doc/<pkg>/copyright`. |
| `apt/*.deb` | NVIDIA | NVIDIA's own terms | **Never published.** CUDA, cuDNN, TensorRT and L4T packages carry redistribution terms that do not allow a public mirror; the build caches them for the box that built them and `INSTALL.sh` installs them only if they are present. A release carries neither apt folder. |

Nothing here relicenses anything. If you redistribute a platform folder, the
table above is the minimum you owe the people whose work is in it.
