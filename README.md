# Nvidia Jetson AGX Xavier Prebuilt Packages

A collection of prebuilt packages for the **Nvidia Jetson AGX Xavier** targeting the **Volta architecture** running **Ubuntu 20.04 with JetPack 5.1** (or whatever the latest v5 release is).

Building some of this shit from source on the Jetson takes forever, so here are the prebuilts so you don't have to waste your time.

## Prebuilt Packages

| Package | Notes |
|---|---|
| `torch-2.1.0-cp310-*.whl` | PyTorch 2.1.0 wheel for Python 3.10, built for Volta/Jetson |
| `torchvision-*.whl` | Matching torchvision wheel |
| `llama-server` | llama.cpp server binary |

## Target Platform

- **Device:** Nvidia Jetson AGX Xavier
- **Architecture:** Volta (sm_72)
- **OS:** Ubuntu 20.04
- **JetPack:** 5.1 (L4T)
