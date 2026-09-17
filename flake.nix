{
  description = "Minimal Bochs activity VM runtime for Obelisk";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-grub.url = "github:NixOS/nixpkgs/nixos-23.05";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    bochs = {
      url = "github:obeli-sk/activity-vm-bochs/86964d7dd68711afa075dcdb267106aef40f83b6";
      flake = false;
    };
    linux = {
      url = "github:torvalds/linux/v6.1";
      flake = false;
    };
    wasi-vfs = {
      url = "git+https://github.com/kateinoigakukun/wasi-vfs.git?ref=refs/tags/v0.6.3&submodules=1";
      flake = false;
    };
    wizer = {
      url = "github:bytecodealliance/wizer/04e49c989542f2bf3a112d60fbf88a62cce2d0d0";
      flake = false;
    };
    activity-vm-proxy.url = "github:obeli-sk/activity-vm-proxy";
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    rust-overlay,
    ...
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      overlays = [(import rust-overlay)];
    };
    legacyPkgs = import inputs.nixpkgs-grub {inherit system;};
    rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
    runtime = pkgs.callPackage ./nix/runtime.nix {
      inherit rustToolchain;
      bochsSrc = inputs.bochs;
      linuxSrc = inputs.linux;
      wasiVfsSrc = inputs.wasi-vfs;
      wizerSrc = inputs.wizer;
      proxy = inputs.activity-vm-proxy.packages.${system}.default;
      grub2 = legacyPkgs.grub2;
      kernelStdenv = legacyPkgs.gcc11Stdenv;
      kernelNativeBuildInputs = with legacyPkgs; [bc bison flex perl openssl elfutils pkg-config];
    };
  in {
    packages.${system} = {
      inherit
        (runtime)
        activity-vm-init
        activity-vm-runtime
        bios
        bochs-wasm
        boot-iso
        linux
        rootfs
        snapshotted
        ;
      default = runtime.activity-vm-runtime;
    };
    checks.${system} = {
      inherit (runtime) activity-vm-init;
      runtime = runtime.activity-vm-runtime;
    };
    devShells.${system}.default = pkgs.mkShell {
      packages = [rustToolchain pkgs.alejandra pkgs.actionlint pkgs.oras];
    };
    formatter.${system} = pkgs.alejandra;
  };
}
