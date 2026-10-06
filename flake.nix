{
  description = "ChatGPT Desktop for Linux, pinned to OpenAI's signed apt repository";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  # Offered, not imposed. Nix applies these only for a trusted user, and
  # otherwise says it is ignoring them. See the README for setting the
  # substituter in a NixOS configuration instead, which is what most people
  # actually want.
  nixConfig = {
    extra-substituters = [ "https://danielbodart.cachix.org" ];
    extra-trusted-public-keys = [
      "danielbodart.cachix.org-1:751qv4GxLFJCThWMEw1WL6kUqY0DpF6oqPqsLKnnEwU="
    ];
  };

  outputs =
    { self, nixpkgs }:
    let
      # OpenAI publishes chatgpt for amd64 and arm64 Linux only.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      # The upstream binary is proprietary, so the flake enables unfree for its
      # own outputs. Consumers who take the overlay instead get their own
      # nixpkgs config, and will need allowUnfree set there.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

      overlay = final: prev: {
        chatgpt-desktop = final.callPackage ./package.nix { };
      };
    in
    {
      overlays.default = overlay;

      packages = forAllSystems (
        system:
        let
          chatgpt-desktop = (pkgsFor system).callPackage ./package.nix { };
        in
        {
          inherit chatgpt-desktop;
          default = chatgpt-desktop;
        }
      );

      apps = forAllSystems (system: {
        default = self.apps.${system}.chatgpt-desktop;
        chatgpt-desktop = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${system}.chatgpt-desktop;
          meta.description = "Launch ChatGPT Desktop";
        };
      });

      nixosModules.default = import ./nix/nixos-module.nix self;

      # `nix flake check` builds these. The package build is the real test:
      # autoPatchelfHook fails the build on any unresolved shared library, so
      # a green check means every dependency the app links is present.
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          chatgpt-desktop = self.packages.${system}.chatgpt-desktop;
        in
        {
          inherit chatgpt-desktop;

          # A dependency that quietly drags perl, python, full git or the
          # whole of systemd back in fails here. The budget covers everything
          # except the app's own store path: that is OpenAI's payload, and a
          # bigger upstream release must not be able to block the update.
          closure-is-slim =
            pkgs.runCommand "chatgpt-desktop-closure-is-slim"
              {
                closure = pkgs.closureInfo { rootPaths = [ chatgpt-desktop ]; };
                app = chatgpt-desktop;
                maxDepsMiB = 550;
              }
              ''
                bad=$(grep -E -- '-(perl-[0-9]|python3-[0-9]|systemd-[0-9]|xdg-utils-|git-[0-9])' \
                  "$closure/store-paths" || true)
                if [ -n "$bad" ]; then
                  echo "unwanted paths in the chatgpt-desktop closure:" >&2
                  echo "$bad" >&2
                  exit 1
                fi

                # registration is path, hash, size, deriver, reference count,
                # then that many references, for each path in the closure.
                appBytes=$(awk -v app="$app" '
                  state == 0 { path = $0; state = 1; next }
                  state == 1 { state = 2; next }
                  state == 2 { if (path == app) print $0; state = 3; next }
                  state == 3 { state = 4; next }
                  state == 4 { refs = $0; state = refs > 0 ? 5 : 0; next }
                  state == 5 { if (--refs == 0) state = 0 }
                ' "$closure/registration")

                total=$(( $(cat "$closure/total-nar-size") / 1048576 ))
                deps=$(( ($(cat "$closure/total-nar-size") - appBytes) / 1048576 ))
                echo "closure is $total MiB, of which dependencies are $deps MiB"
                if [ "$deps" -gt "$maxDepsMiB" ]; then
                  echo "dependencies are $deps MiB, over the $maxDepsMiB MiB budget" >&2
                  exit 1
                fi
                echo "$total MiB total, $deps MiB dependencies" >$out
              '';

          # The version in sources.json has to be the version inside the
          # archive, otherwise the flake is pinning a label rather than a
          # release. OpenAI's build writes the same version into this file as
          # into the .deb's control file.
          version-matches-package =
            pkgs.runCommand "chatgpt-desktop-version-matches-package" { nativeBuildInputs = [ pkgs.jq ]; }
              ''
                expected="${chatgpt-desktop.version}"
                actual="$(jq -r .version ${chatgpt-desktop}/lib/chatgpt/resources/linux-package-metadata.json)"
                if [ "$expected" != "$actual" ]; then
                  echo "sources.json says $expected, the packaged app is $actual" >&2
                  exit 1
                fi
                echo "chatgpt-desktop $actual" >$out
              '';

          # The build fails if an edit to app.asar does not apply, but that
          # proves only that nix/patch-asar.cjs believed it had written them.
          # This reads them back with asar itself, a parser that did not write
          # the archive, and checks that each edit is there and that the
          # files the app loads from app.asar.unpacked are still flagged so.
          asar-patches =
            pkgs.runCommand "chatgpt-desktop-asar-patches" { nativeBuildInputs = [ pkgs.asar ]; }
              ''
                archive=${chatgpt-desktop}/lib/chatgpt/resources/app.asar

                asar extract-file "$archive" .vite/build/early-bootstrap.js
                asar extract-file "$archive" .vite/build/worker.js
                asar extract-file "$archive" node_modules/@parcel/watcher/node_modules/detect-libc/lib/filesystem.js

                for entry in early-bootstrap.js worker.js; do
                  grep -q 'Prepended by the chatgpt-desktop Nix package' "$entry" ||
                    { echo "$entry is missing store-copies.js" >&2; exit 1; }
                done

                grep -q "LDD_PATH = '${builtins.storeDir}/.*/bin/ldd'" filesystem.js ||
                  { echo "detect-libc still looks for /usr/bin/ldd" >&2; exit 1; }

                asar list --is-pack "$archive" | grep -q '^unpack : /node_modules/better-sqlite3/build/Release/better_sqlite3.node$' ||
                  { echo "app.asar.unpacked flags were lost" >&2; exit 1; }

                touch $out
              '';

          store-copies =
            pkgs.runCommand "chatgpt-desktop-store-copies" { nativeBuildInputs = [ pkgs.nodejs ]; }
              ''
                node ${./nix/store-copies-test.js} ${./nix/store-copies.js}
                touch $out
              '';

          # Evaluation only, not a build: enough to catch an option this module
          # sets that nixpkgs has since renamed or removed, without standing up
          # a whole system.
          #
          # unsafeDiscardStringContext is what keeps it that way. Interpolating
          # a drvPath with its context intact makes the toplevel an input of
          # this derivation, and `nix flake check` would go and build a NixOS
          # system.
          nixos-module = pkgs.runCommand "chatgpt-desktop-nixos-module" { } ''
            echo ${
              builtins.unsafeDiscardStringContext
                (nixpkgs.lib.nixosSystem {
                  modules = [
                    self.nixosModules.default
                    {
                      nixpkgs.hostPlatform = system;
                      boot.loader.grub.devices = [ "/dev/null" ];
                      fileSystems."/" = {
                        device = "/dev/null";
                        fsType = "ext4";
                      };
                      system.stateVersion = "26.05";
                      programs.chatgpt-desktop = {
                        enable = true;
                        primaryRuntime.enable = true;
                      };
                    }
                  ];
                }).config.system.build.toplevel.drvPath
            } >$out
          '';

          shellcheck =
            pkgs.runCommand "chatgpt-desktop-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; }
              ''
                shellcheck ${./scripts/update.sh}
                touch $out
              '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              curl
              dpkg
              gnupg
              jq
              nixfmt
              shellcheck
            ];
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
