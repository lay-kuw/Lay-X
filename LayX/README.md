# Lay X

Native, local-first AI for Apple Silicon — Swift 6 · SwiftUI · MLX Swift · SQLite · Hummingbird.
Chat, Mini Chat, Work (project edits with diff approval), model manager, benchmarks and an
OpenAI-compatible API server, all on one on-device inference engine.

## Requirements
- macOS 26+ on Apple Silicon, Xcode 26+ (tested: macOS 27.2, Xcode 27.2, Swift 6.4).
- One-time Xcode setup (admin):
  ```bash
  sudo xcodebuild -runFirstLaunch
  xcodebuild -downloadComponent MetalToolchain
  ```

## Build & run
```bash
cd LayX
scripts/build-app.sh            # release build → build/LayX.app (+ MLX GPU self-test)
scripts/build-app.sh debug      # debug build
open build/LayX.app
```

Disk image (drag-to-Applications): `scripts/make-dmg.sh` → `build/LayX-<version>.dmg`
(`--no-build` packages the existing `build/LayX.app`). The app is ad-hoc signed, not notarized.
First run: Models → Discover → download e.g. `mlx-community/Qwen3-4B-4bit`, or paste `owner/name`
into the field and press Add model.

## Tests
```bash
cd LayX
scripts/test-core.sh            # LayXCore + LayXServer suites (no Metal needed; preserves Package.resolved)
```

## Headless verification commands (real MLX, from the app bundle)
```bash
B=build/LayX.app/Contents/MacOS/LayX
$B --mlx-selftest
$B --download mlx-community/Qwen3-0.6B-4bit
$B --generate mlx-community/Qwen3-0.6B-4bit "Hello" 64
$B --engine-check mlx-community/Qwen3-0.6B-4bit     # cancel / queue / limits / unload / reload
$B --chat-check   mlx-community/Qwen3-0.6B-4bit     # memory-only vs pinned persistence (DB byte scan)
$B --work-check   mlx-community/Qwen3-4B-4bit       # propose → nothing written → apply
$B --benchmark    mlx-community/Qwen3-4B-4bit sweep # saved to the app database
$B --serve        mlx-community/Qwen3-4B-4bit 18234 # headless API server (add "lan" for LAN + key)
$B --soak         mlx-community/Qwen3-4B-4bit 80    # memory drift over repeated generations
$B --image-check  [image-model] [text-model]        # download if needed, generate, memory arbitration
#   env: LAYX_IMAGE_SIZE=1216x832 LAYX_IMAGE_STEPS=6 LAYX_IMAGE_CFG=2 LAYX_IMAGE_NEG="…" LAYX_IMAGE_LORA=/x.safetensors:0.8
#        LAYX_IMAGE_LORA_SWAP=1 (LoRA switched on for the 2nd image) LAYX_IMAGE_SOURCE=/x.png LAYX_IMAGE_STRENGTH=0.6
$B --search qwen3 ; $B --list-models ; $B --keychain-check
```

## App icon
Source: `Sources/LayXIcon/LX.png` (square, ≥ 1024 px). `scripts/build-app.sh` renders `AppIcon.icns`
(16–1024 px, @1x/@2x) with `sips` + `iconutil` into the bundle.

## Layout
| Target | Contents |
|---|---|
| `LayXCore` | persistence (SQLite), chat store, prompt building, inference coordinator, models (Hub, downloader, store), Work (workspace, diff, change sets), performance (benchmarks), shared |
| `LayXMLX` | `MLXEngine` (mlx-swift-lm 3.32.3), `MLXImageEngine` (SDXL via `StableDiffusionMLX`; FLUX.2 klein 4B via `Klein` from flux2-klein-swift; Qwen-Image via `QwenImageEdit` from qwen-image-edit-swift — only their engine-free core libraries are linked, weights read from the local folder) |
| `StableDiffusionMLX` | SDXL on MLX — vendored from ml-explore/mlx-swift-examples (MIT, notice in the folder); reads local weights only. Lay X additions: any SDXL diffusers checkpoint, size micro-conditioning, LoRA merging (`LoRA.swift`) |
| `LayXServer` | OpenAI-compatible server (Hummingbird 2.28.1), API keys (Keychain) |
| `LayXApp` | SwiftUI app — design system from `DesignPreview/`, screens, Mini Chat panel |

Data: pinned chats + benchmarks in `LayX.sqlite` (default `~/.config/lay-x/database/`, movable);
models in `~/.config/lay-x/models` (movable; both folders are created if missing); API key hashes in the
Keychain; preferences in UserDefaults. Temporary chats are never written anywhere.

