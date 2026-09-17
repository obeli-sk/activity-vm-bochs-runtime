{
  stdenv,
  lib,
  fetchurl,
  rustPlatform,
  rustToolchain,
  bochsSrc,
  linuxSrc,
  wasiVfsSrc,
  wizerSrc,
  wizer,
  proxy,
  pkgsStatic,
  kernelStdenv,
  kernelNativeBuildInputs,
  bc,
  bison,
  flex,
  perl,
  openssl,
  elfutils,
  cdrtools,
  grub2,
  xorriso,
  mtools,
  gnumake,
  autoconf,
  automake,
  libtool,
  pkg-config,
  python3,
  autoPatchelfHook,
  zlib,
  libxml2,
  ncurses,
  libffi,
  wasm-tools,
}: let
  target = "x86_64-unknown-linux-musl";
  wasiSdk = stdenv.mkDerivation {
    pname = "wasi-sdk";
    version = "19.0";
    src = fetchurl {
      url = "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-19/wasi-sdk-19.0-linux.tar.gz";
      hash = "sha256-2QCryCbuwZVbmv0lDnzCSWM4q79sRA2GoxPAbkIIP6E=";
    };
    nativeBuildInputs = [autoPatchelfHook];
    buildInputs = [stdenv.cc.cc.lib zlib libxml2 ncurses libffi];
    dontStrip = true;
    installPhase = ''
      mkdir -p "$out"
      cp -a . "$out/"
    '';
  };
  binaryen114 = stdenv.mkDerivation {
    pname = "binaryen";
    version = "114";
    src = fetchurl {
      url = "https://github.com/WebAssembly/binaryen/releases/download/version_114/binaryen-version_114-x86_64-linux.tar.gz";
      hash = "sha256-Ciw8Ir200Bfwzyzvs2NbYWxIAubl3ITIL9/k3uQv57c=";
    };
    installPhase = ''
      mkdir -p "$out"
      cp -a . "$out/"
    '';
  };
  activity-vm-init = rustPlatform.buildRustPackage {
    pname = "activity-vm-init";
    version = "0.1.0";
    src = ../guest;
    cargoLock.lockFile = ../guest/Cargo.lock;
    nativeBuildInputs = [rustToolchain pkgsStatic.stdenv.cc];
    cargoBuildFlags = ["--target=${target}"];
    cargoTestFlags = ["--target=${target}"];
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER = "x86_64-unknown-linux-musl-gcc";
    installPhase = ''
      install -D -m 755 target/${target}/release/activity-vm-init "$out/bin/activity-vm-init"
    '';
  };
  linux = kernelStdenv.mkDerivation {
    pname = "activity-vm-linux";
    version = "6.1";
    src = linuxSrc;
    nativeBuildInputs = kernelNativeBuildInputs;
    postPatch = ''
      cp ${../config/linux_x86_config} .config
      patchShebangs scripts
    '';
    makeFlags = [
      "ARCH=x86"
      "KBUILD_BUILD_TIMESTAMP=@0"
    ];
    NIX_CFLAGS_COMPILE = "-std=gnu11";
    buildPhase = ''
      runHook preBuild
      make "''${makeFlagsArray[@]}" olddefconfig
      make "''${makeFlagsArray[@]}" -j"$NIX_BUILD_CORES" bzImage
      runHook postBuild
    '';
    installPhase = ''
      install -D -m 644 arch/x86/boot/bzImage "$out/bzImage"
    '';
  };
  rootfs = stdenv.mkDerivation {
    pname = "activity-vm-rootfs";
    version = "0.1.0";
    dontUnpack = true;
    nativeBuildInputs = [cdrtools];
    installPhase = ''
      root="$TMPDIR/rootfs"
      mkdir -p "$root"/{bin,sbin,usr/bin,usr/sbin,usr/local/libexec/obelisk,usr/share/obelisk,etc,proc,sys,dev,run,tmp,mnt/wasi0,mnt/wasi1,nix/store,obelisk-activity,obelisk-activity-vm-http}
      cp ${pkgsStatic.busybox}/bin/busybox "$root/bin/busybox"
      for applet in $(${pkgsStatic.busybox}/bin/busybox --list); do
        case "$applet" in
          init) ;;
          *) ln -s /bin/busybox "$root/bin/$applet" ;;
        esac
      done
      ln -s /bin/env "$root/usr/bin/env"
      cp ${activity-vm-init}/bin/activity-vm-init "$root/sbin/init"
      cp ${pkgsStatic.nftables}/bin/nft "$root/usr/sbin/nft"
      cp ${proxy}/bin/obelisk-activity-vm-http-proxy "$root/usr/local/libexec/obelisk/"
      cp ${../config/activity-vm-nftables.conf} "$root/usr/share/obelisk/activity-vm.nft"
      printf 'nameserver 127.0.0.1\n' > "$root/etc/resolv.conf"
      mkdir -p "$out"
      mkisofs -quiet -R -o "$out/rootfs.bin" "$root"
    '';
  };
  boot-iso = stdenv.mkDerivation {
    pname = "activity-vm-boot-iso";
    version = "0.1.0";
    dontUnpack = true;
    nativeBuildInputs = [grub2 xorriso mtools];
    installPhase = ''
      iso="$TMPDIR/iso"
      mkdir -p "$iso/boot/grub" "$out"
      cp ${linux}/bzImage "$iso/boot/bzImage"
      cp ${../config/grub.cfg} "$iso/boot/grub/grub.cfg"
      grub-mkrescue --locales="" --fonts="" --themes="" \
        -o "$out/boot.iso" "$iso"
    '';
  };
  bios = stdenv.mkDerivation {
    pname = "bochs-bios";
    version = "86964d7";
    src = "${bochsSrc}/bochs";
    nativeBuildInputs = [gnumake autoconf automake libtool];
    configurePhase = ''
      ./configure --enable-x86-64 --with-nogui
    '';
    buildPhase = ''
      make -j"$NIX_BUILD_CORES" bios/BIOS-bochs-latest bios/VGABIOS-lgpl-latest
    '';
    installPhase = ''
      install -D -m 644 bios/BIOS-bochs-latest "$out/BIOS-bochs-latest"
      install -D -m 644 bios/VGABIOS-lgpl-latest "$out/VGABIOS-lgpl-latest"
    '';
  };
  wasi-vfs = rustPlatform.buildRustPackage {
    pname = "wasi-vfs";
    version = "0.6.3";
    src = wasiVfsSrc;
    cargoLock.lockFile = "${wasiVfsSrc}/Cargo.lock";
    nativeBuildInputs = [rustToolchain wasiSdk];
    WASI_SDK_PATH = wasiSdk;
    doCheck = false;
    dontStrip = true;
    postPatch = ''
      substituteInPlace Cargo.toml \
        --replace-fail 'crate-type = ["staticlib", "cdylib"]' 'crate-type = ["staticlib"]'
    '';
    buildPhase = ''
      runHook preBuild
      cargo build --locked --offline --release --target=wasm32-unknown-unknown --package wasi-vfs
      cargo build --locked --offline --release --package wasi-vfs-cli
      runHook postBuild
    '';
    installPhase = ''
      mkdir -p "$out/bin" "$out/lib"
      cp target/release/wasi-vfs "$out/bin/"
      cp target/wasm32-unknown-unknown/release/libwasi_vfs.a "$out/lib/"
    '';
  };
  pack = stdenv.mkDerivation {
    pname = "activity-vm-pack";
    version = "0.1.0";
    dontUnpack = true;
    installPhase = ''
      mkdir -p "$out"
      cp ${bios}/BIOS-bochs-latest ${bios}/VGABIOS-lgpl-latest "$out/"
      cp ${boot-iso}/boot.iso ${rootfs}/rootfs.bin "$out/"
      cp ${../config/bochsrc} "$out/bochsrc"
    '';
  };
  bochs-wasm = stdenv.mkDerivation {
    pname = "bochs-wasm";
    version = "86964d7";
    src = "${bochsSrc}/bochs";
    nativeBuildInputs = [gnumake autoconf automake libtool python3];
    configurePhase = ''
      sdk=${wasiSdk}
      export CC="$sdk/bin/clang"
      export CXX="$sdk/bin/clang++"
      export RANLIB="$sdk/bin/ranlib"
      export CFLAGS="--sysroot=$sdk/share/wasi-sysroot -D_WASI_EMULATED_SIGNAL -DWASI -D__GNU__ -O2 -I${bochsSrc}/bochs/wasi_extra/jmp -I${wizerSrc}/include"
      export CXXFLAGS="$CFLAGS"
      ./configure --host wasm32-unknown-wasi --enable-x86-64 --with-nogui \
        --enable-usb --enable-usb-ehci --disable-large-ramfile --disable-show-ips \
        --disable-stats --disable-logging --enable-repeat-speedups \
        --enable-fast-function-calls --disable-trace-linking --enable-handlers-chaining --enable-avx
    '';
    buildPhase = ''
      sdk=${wasiSdk}
      mkdir -p jmp-objects vfs-objects
      "$sdk/bin/clang" --sysroot="$sdk/share/wasi-sysroot" -O2 --target=wasm32-unknown-wasi \
        -c wasi_extra/jmp/jmp.c -I wasi_extra/jmp -o jmp-objects/jmp.o
      "$sdk/bin/clang" --sysroot="$sdk/share/wasi-sysroot" -O2 --target=wasm32-unknown-wasi \
        -Wl,--export=wasm_setjmp -c wasi_extra/jmp/jmp.S -o jmp-objects/jmp-wrapper.o
      "$sdk/bin/wasm-ld" jmp-objects/jmp.o jmp-objects/jmp-wrapper.o \
        --export=wasm_setjmp --export=wasm_longjmp --export=handle_jmp --no-entry -r -o jmp-objects/jmp
      "$sdk/bin/clang" --sysroot="$sdk/share/wasi-sysroot" -O2 --target=wasm32-unknown-wasi \
        -c wasi_extra/vfs/vfs.c -I wasi_extra/vfs -o vfs-objects/vfs.o
      make -j"$NIX_BUILD_CORES" bochs \
        EMU_DEPS="${wasi-vfs}/lib/libwasi_vfs.a $PWD/jmp-objects/jmp $PWD/vfs-objects/vfs.o -lrt"
      ${binaryen114}/bin/wasm-opt bochs --asyncify -O2 -o bochs.async \
        --pass-arg=asyncify-ignore-imports
    '';
    installPhase = ''
      install -D -m 644 bochs.async "$out/bochs.wasm"
    '';
  };
  snapshotted = stdenv.mkDerivation {
    pname = "bochs-wasm-snapshotted";
    version = "0.1.0";
    dontUnpack = true;
    nativeBuildInputs = [wizer];
    buildPhase = ''
      export XDG_CACHE_HOME="$TMPDIR/cache"
      mkdir -p "$XDG_CACHE_HOME"
      mkdir pack
      cp -a ${pack}/. pack/
      wizer --allow-wasi --wasm-bulk-memory=true -f wizer.initialize \
        -r _start=wizer.resume \
        --mapdir /pack::"$PWD/pack" -o bochs.wasm ${bochs-wasm}/bochs.wasm
    '';
    installPhase = ''
      install -D -m 644 bochs.wasm "$out/bochs.wasm"
    '';
  };
  activity-vm-runtime = stdenv.mkDerivation {
    pname = "activity-vm-runtime";
    version = "0.1.0";
    dontUnpack = true;
    nativeBuildInputs = [wasi-vfs wasm-tools];
    buildPhase = ''
      export XDG_CACHE_HOME="$TMPDIR/cache"
      mkdir -p "$XDG_CACHE_HOME"
      mkdir minpack
      cp ${pack}/boot.iso ${pack}/rootfs.bin minpack/
      wasi-vfs pack ${snapshotted}/bochs.wasm --dir "$PWD/minpack"::/pack -o packed.wasm
      wasm-tools strip -d '.debug_*' packed.wasm -o activity-vm-runtime.wasm
    '';
    installPhase = ''
      install -D -m 644 activity-vm-runtime.wasm "$out/activity-vm-runtime.wasm"
    '';
    passthru = {inherit bochs-wasm snapshotted pack rootfs boot-iso linux bios;};
  };
in {
  inherit activity-vm-init linux rootfs boot-iso bios bochs-wasm snapshotted activity-vm-runtime;
}
