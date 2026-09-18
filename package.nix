{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  dpkg,
  makeShellWrapper,
  nodejs,
  wrapGAppsHook3,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  gtk3,
  lcms2,
  libdrm,
  libgbm,
  libGL,
  libglvnd,
  libnotify,
  libpulseaudio,
  libsecret,
  libusb1,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  mesa,
  nspr,
  nss,
  openssl,
  pango,
  systemd,
  tpm2-tss,
  vulkan-loader,
  xdg-utils,
  git,
  openssh,
  sources ? lib.importJSON ./sources.json,
}:

let
  source =
    sources.sources.${stdenv.hostPlatform.system}
      or (throw "chatgpt-desktop has no Linux package for ${stdenv.hostPlatform.system}; OpenAI publishes amd64 and arm64 only");

  # Where the .deb puts everything, and where we keep it. The app resolves
  # its bundled node runtime, codex binary and native modules relative to
  # `process.resourcesPath`, so the layout under $out has to match.
  appDir = "lib/chatgpt";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "chatgpt-desktop";
  version = sources.version;

  src = fetchurl {
    inherit (source) url hash;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    dpkg
    makeShellWrapper
    nodejs
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    libdrm
    libgbm
    libGL
    libnotify
    libsecret
    libusb1
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    mesa
    nspr
    nss
    pango
    (lib.getLib systemd)

    # resources/native/remote-control-device-key.node keeps a device key in
    # the TPM when there is one, through tpm2-tss, and signs with OpenSSL.
    openssl
    tpm2-tss
  ];

  # Loaded with dlopen at runtime rather than linked, so autoPatchelfHook
  # cannot see the need for them from the ELF headers.
  runtimeDependencies = [
    (lib.getLib systemd)
    libglvnd
    libnotify
    libpulseaudio
    libsecret
    vulkan-loader
  ];

  autoPatchelfIgnoreMissingDeps = [
    # Chromium's optional Qt integration, chosen at runtime only under a Qt
    # desktop. The .deb does not depend on Qt either.
    "libQt5Core.so.5"
    "libQt5Gui.so.5"
    "libQt5Widgets.so.5"
    "libQt6Core.so.6"
    "libQt6Gui.so.6"
    "libQt6Widgets.so.6"
    # node-hid and serialport ship musl prebuilds beside the glibc ones and
    # pick between them at runtime; on NixOS it is always the glibc one.
    "libc.musl-x86_64.so.1"
    # serialport also ships Android prebuilds. Only the arm64 one shares an
    # architecture with a system this builds for, so it is only on aarch64
    # that autoPatchelfHook looks at it; Node never loads it on Linux.
    "liblog.so"
    "libc++_shared.so"
  ];

  # The .deb has no setuid chrome-sandbox to drop, unlike most Electron
  # packages: OpenAI relies on the unprivileged user namespace sandbox, and
  # its postinst installs an unconfined AppArmor profile so that Ubuntu lets
  # it have one. NixOS applies no such restriction, so that profile and the
  # apt source the postinst also writes are left behind with the rest of /etc.
  unpackPhase = ''
    runHook preUnpack

    dpkg-deb --fsys-tarfile "$src" |
      tar --extract --no-same-permissions --no-same-owner --wildcards './usr/*'

    runHook postUnpack
  '';

  # Electron ships a prebuilt Chromium whose asar archive and V8 snapshots are
  # checked against their own offsets; rewriting the binary breaks it.
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/${appDir}" "$out/bin" "$out/share"
    cp -r usr/${appDir}/. "$out/${appDir}/"
    cp -r usr/share/metainfo usr/share/pixmaps "$out/share/"

    # Two fixes inside app.asar, both for things that only go wrong when the
    # app runs out of the Nix store. See nix/patch-asar.cjs for how the
    # archive is edited without repacking it.
    #
    # store-copies.js makes the app's copies of its bundled plugins and
    # skills writable; the comment at its top has the detail.
    #
    # The LDD_PATH replacement is for @parcel/watcher, which asks detect-libc
    # whether to load its glibc or musl binary. detect-libc reads the ELF
    # interpreter out of the first 2KiB of /proc/self/exe, but patchelf moves
    # that interpreter hundreds of megabytes further in. Its next guess is
    # /usr/bin/ldd, which NixOS does not have, and after that it falls back to
    # process.report, which aborts inside Electron's worker threads. Pointing
    # it at a real glibc ldd makes the second guess succeed.
    substitute ${./nix/store-copies.js} store-copies.js \
      --replace-fail "@storeDir@" "${builtins.storeDir}"

    node ${./nix/patch-asar.cjs} \
      usr/${appDir}/resources/app.asar "$out/${appDir}/resources/app.asar" \
      --prepend .vite/build/early-bootstrap.js store-copies.js \
      --prepend .vite/build/worker.js store-copies.js \
      --replace node_modules/@parcel/watcher/node_modules/detect-libc/lib/filesystem.js \
        "const LDD_PATH = '/usr/bin/ldd';" \
        "const LDD_PATH = '${lib.getBin stdenv.cc.libc}/bin/ldd';"

    # The bare `chatgpt` in Exec= resolves against a Debian $PATH. Point it
    # at the wrapper instead, so a launcher finds the app without the profile
    # having to be on PATH.
    install -Dm644 usr/share/applications/chatgpt.desktop \
      "$out/share/applications/chatgpt.desktop"

    substituteInPlace "$out/share/applications/chatgpt.desktop" \
      --replace-fail "Exec=chatgpt" "Exec=$out/bin/chatgpt"

    runHook postInstall
  '';

  # Straight at the ChatGPT binary rather than through codex-launcher, which
  # is only `exec "$(dirname "$(readlink -f "$0")")/ChatGPT"` and would put a
  # second shell in front of every launch.
  #
  # git and ssh are what the Codex side of the app shells out to for
  # repositories, and the .deb recommends git for the same reason. Suffixed,
  # not prefixed, so the user's own versions win.
  #
  # NIX_LD_LIBRARY_PATH is for the runtime the app downloads on first launch
  # into ~/.cache/codex-runtimes: Node, Python, poppler and a headless
  # LibreOffice, behind its document, PDF, spreadsheet and presentation
  # tools. They are built for generic Linux and run here only through nix-ld
  # (see programs.chatgpt-desktop.primaryRuntime in the NixOS module).
  # nix-ld's default libraries cover everything but LibreOffice, which also
  # needs these five; each was found by leaving it out and watching a
  # conversion fail. Scoped to the app and what it starts, rather than added
  # to nix-ld system-wide. nix-ld has no fallback of its own when the
  # variable is set, so an unset one is first given the NixOS default.
  postFixup = ''
    makeShellWrapper "$out/${appDir}/ChatGPT" "$out/bin/chatgpt" \
      "''${gappsWrapperArgs[@]}" \
      --prefix PATH : ${lib.makeBinPath [ xdg-utils ]} \
      --suffix PATH : ${
        lib.makeBinPath [
          git
          openssh
        ]
      } \
      --prefix LD_LIBRARY_PATH : ${
        lib.makeLibraryPath [
          libglvnd
          vulkan-loader
        ]
      } \
      --run 'export NIX_LD_LIBRARY_PATH="''${NIX_LD_LIBRARY_PATH:-/run/current-system/sw/share/nix-ld/lib}"' \
      --suffix NIX_LD_LIBRARY_PATH : ${
        lib.makeLibraryPath [
          fontconfig
          freetype
          lcms2
          nspr
          nss
        ]
      } \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations}}"
  '';

  # wrapGAppsHook3 would otherwise wrap the Electron binary directly, and the
  # wrapper it writes replaces argv[0] with a path Chromium then re-execs for
  # its zygote processes.
  dontWrapGApps = true;

  passthru = {
    inherit (source) url;
    updateScript = ./scripts/update.sh;
  };

  meta = {
    description = "Desktop application for ChatGPT, packaged from OpenAI's apt repository";
    longDescription = ''
      The official ChatGPT desktop application for Linux, currently in
      preview. ChatGPT, ChatGPT Work and Codex in one window, with Codex
      working in local repositories.

      Repackaged from the .deb OpenAI publishes at persistent.oaistatic.com,
      pinned to a hash taken from that repository's PGP-signed index.
    '';
    homepage = "https://chatgpt.com/download";
    downloadPage = "https://learn.chatgpt.com/docs/linux/linux-app";
    license = {
      fullName = "OpenAI Terms of Use";
      url = "https://openai.com/policies/terms-of-use";
      free = false;
      redistributable = false;
    };
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "chatgpt";
  };
})
