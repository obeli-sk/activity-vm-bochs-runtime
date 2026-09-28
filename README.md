# Obelisk Bochs activity VM

This repository builds the minimal Bochs-based activity VM consumed by
Obelisk. `nix build` produces `result/activity-vm-runtime.wasm`, a WASI Preview
1 core module distributed as the `activity-vm-runtime.v1` OCI artifact.

The build deliberately excludes the generic container2wasm pipeline. There is
no OCI image conversion, container root filesystem, `runc`, containerd OCI
specification, vmtouch, tini, Go init, or browser runtime.

## Runtime contents

The appliance contains only:

- the pinned `obeli-sk/bochs-c2w` fork and its WASI 9p devices;
- Linux 6.1 with the proven c2w kernel configuration;
- static BusyBox and nftables;
- the static `activity-vm-init` PID 1;
- the pinned `obeli-sk/activity-vm-proxy` executable;
- GRUB and Bochs firmware needed to boot the guest;
- Wizer and wasi-vfs for the preinitialized, self-contained WASM artifact.

At runtime, PID 1 applies the transparent HTTP redirect rules and reaches the
Wizer handoff before mounting execution-specific WASI preopens. After resume it
reads Bochs' `pack/info` manifest, bind-mounts the Nix closures supplied by
Obelisk, applies the environment, and executes the command directly. The
existing Obelisk guest script handles HTTP startup and result files.

## Build

```sh
nix build
```

Useful intermediate outputs are available for debugging:

```sh
nix build .#activity-vm-init
nix build .#rootfs
nix build .#linux
nix build .#bochs-wasm
nix build .#snapshotted
```

Run all checks with:

```sh
nix flake check --print-build-logs
```

## Publication

The `runtime` GitHub Actions workflow builds the artifact with Nix and uploads
the WASM and its SHA-256 digest as workflow artifacts. Run it on `main` with a
new `YYYY-MM-DD` tag (or `YYYY-MM-DD-N`) to publish to `docker.io/getobelisk/activity-vm-runtime`, open an
Obelisk PR with the digest-pinned OCI reference, and create the release tag in
this repository. Publication requires `DOCKER_HUB_USERNAME`,
`DOCKER_HUB_TOKEN`, and `RUNTIME_TO_OBELISK_PR` repository secrets.

## Provenance

The extraction starts from `obeli-sk/container2wasm` commit `e83f3e0` and pins
the Bochs fork at `039b8a614b197d900306921f5dabbebe387c6b35`. The retained c2w
inputs are `config/bochs/linux_x86_config`, the Bochs build flags, WASI SDK 19,
Binaryen 114, wasi-vfs 0.6.3, the Wizer initialization header from `04e49c9`,
and the Wizer snapshot protocol. Snapshotting uses the current Wizer from the
pinned nixpkgs input because the historical Wizer hangs under current Wasmtime.
