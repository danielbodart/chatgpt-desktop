# chatgpt-desktop

A Nix flake for the **official** ChatGPT desktop application on Linux.

OpenAI ships a real Linux build now: a signed `.deb` in an apt repository at
`persistent.oaistatic.com`, currently in preview, for amd64 and arm64. It is
ChatGPT, ChatGPT Work and Codex in one window. This flake repackages that
`.deb` for NixOS and Nix on other distributions, and keeps the pin current
automatically.

```nix
{
  inputs.chatgpt-desktop.url = "github:danielbodart/chatgpt-desktop";
}
```

## Why another one

There are several ChatGPT Desktop flakes. Most download
`.../linux/deb/latest/chatgpt_amd64.deb` -- a URL whose contents change with
every release -- and pin whatever hash it had when their updater last ran.
Between an upstream release and the next updater run those flakes fail to
build, and no earlier version can ever be rebuilt. Others pin versioned URLs
but read the repository's package index without checking its signature, so the
pinned hash is only as trustworthy as the connection it was fetched over.

This one:

- **Packages what OpenAI ships.** The upstream `.deb`, with its own Electron
  runtime, patched only where running out of the Nix store needs it.
- **Pins to a signature, not to a download.** The version and hashes in
  `sources.json` are read out of the repository's PGP-signed index, and the
  URLs are the versioned ones in its pool, so every pin stays buildable. See
  [Provenance](#provenance).
- **Updates itself hourly**, and only lands a version that has been built and
  launched on both x86\_64 and aarch64 first.
- **Tags every release**, so `github:danielbodart/chatgpt-desktop/v26.915.31945`
  pins one exactly.
- **Makes the document tools work.** The app downloads a second runtime on
  first launch for its document, PDF, spreadsheet and presentation features.
  See [The document runtime](#the-document-runtime).

## Install

### NixOS

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    chatgpt-desktop.url = "github:danielbodart/chatgpt-desktop";
  };

  outputs = { nixpkgs, chatgpt-desktop, ... }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      modules = [
        chatgpt-desktop.nixosModules.default
        {
          programs.chatgpt-desktop = {
            enable = true;
            primaryRuntime.enable = true;
          };
        }
      ];
    };
  };
}
```

### Home Manager, or any other profile

```nix
home.packages = [ inputs.chatgpt-desktop.packages.${pkgs.system}.default ];
```

The package is unfree, so `nixpkgs.config.allowUnfree` has to permit it. This
flake's own outputs set that for themselves; taking the overlay instead uses
your nixpkgs configuration.

### Try it without installing

```bash
nix run github:danielbodart/chatgpt-desktop
```

## Provenance

The chain from OpenAI's signing key to the hash Nix checks has no
unauthenticated link in it:

| Step | Verified by |
| --- | --- |
| `openai-archive-keyring.asc` in this repository | Fingerprint `3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4`, asserted by `scripts/update.sh` |
| `dists/stable/InRelease` | PGP signature, checked with `gpgv` against that key |
| `main/binary-$arch/Packages` | SHA256 listed in the signed `InRelease` |
| `pool/.../chatgpt_*.deb` | SHA256 listed in `Packages`, recorded in `sources.json` |
| The bytes Nix downloads | The hash in `sources.json`, checked by `fetchurl` |

`scripts/update.sh` never downloads the `.deb`. It reads the hash out of the
signed index and writes it down, and Nix checks the download against it at
build time. So the pin is a claim OpenAI signed, not a fingerprint of whatever
the updater happened to receive.

Continuous integration re-derives `sources.json` on every pull request and
fails if a hand-edited file disagrees with the signed index at the same
version.

### Where the key came from

OpenAI does not publish this key on its own anywhere: not at a URL beside the
repository, and not in its [install
instructions](https://learn.chatgpt.com/docs/linux/linux-app). The only copy is
inside the package, where `postinst` decodes a base64 `SIGNING_KEY_BASE64` into
`/usr/share/keyrings/chatgpt-archive-keyring.gpg` when it sets up the apt
source. The key here was taken from there without running the script, and
confirmed to be "Codex Linux Repository", RSA 4096, created 2026-08-05, and to
verify the repository's `InRelease`.

That makes it trust on first use: the first `.deb` it came out of was trusted
because it was downloaded over TLS from OpenAI's domain, the same basis on
which anyone installing from their instructions trusts it. To check it
yourself:

```bash
dpkg-deb -e chatgpt_*_amd64.deb control
sed -n "s/^SIGNING_KEY_BASE64='\(.*\)'$/\1/p" control/postinst | base64 -d |
  gpg --show-keys
```

## How updates work

An hourly job checks the repository index. When it finds a newer version it
regenerates `sources.json`, then builds the package and runs it on both
`x86_64-linux` and `aarch64-linux` runners. Only if both succeed does the
commit reach `trunk`, followed by a `v<version>` tag and a GitHub release.

This pushes to `trunk` rather than opening a pull request on purpose. A pull
request raised with the default token does not trigger workflows, so an
auto-merged one would land without ever having been built.

Nothing about this changes when you pin a tag. `nix flake update` is still the
only thing that moves your version.

## What is packaged

The `.deb` contents, at their original layout under `lib/chatgpt`, which the
app depends on to find its codex binary, bundled Node and native modules
relative to itself. On top of that:

- `autoPatchelfHook` over every ELF in the tree, including `codex`, the bundled
  Node and the native Node modules.
- No setuid `chrome-sandbox` to deal with: the `.deb` has none, and relies on
  the unprivileged user namespace sandbox, which NixOS enables by default. The
  AppArmor profile and apt source its `postinst` would install are left out.
- The desktop entry pointed at the wrapper's store path. It registers the
  `codex://` scheme, and also lists `http` and `https` among the types it can
  open, as the upstream entry does. That makes it a candidate, not the default:
  your browser stays the default unless you choose otherwise.
- `git` and `ssh` on the app's `PATH`, after your own, for Codex to use in
  repositories.
- Wayland enabled when `NIXOS_OZONE_WL` is set. OpenAI describes Wayland
  support as experimental.

### Patched inside app.asar

Two things go wrong only because the app runs from a read-only store instead
of `/usr/lib`. Both are fixed by editing files inside `app.asar`, which
`nix/patch-asar.cjs` does in place -- appending the new contents and
repointing the archive's index at them -- so that upstream's split between
`app.asar` and `app.asar.unpacked` is left exactly as built. Each edit must
apply exactly once or the build fails, so an upstream change to the patched
code stops the build instead of silently shipping the bug.

- **Copies out of the store are read-only.** The app seeds `~/.codex` with
  plugins and skills by copying them out of its resources, and the copies
  keep the store's read-only modes. It then fails to rewrite them, and cannot
  delete its own staging directories. `nix/store-copies.js`, prepended to the
  main-process and worker entry points, gives the owner write access to
  anything copied out of the store.
- **`@parcel/watcher` cannot tell which libc it is on.** It asks
  `detect-libc`, which looks for the ELF interpreter in the first 2 KiB of
  `/proc/self/exe`. patchelf moves the interpreter hundreds of megabytes
  further in. The next guess, `/usr/bin/ldd`, does not exist on NixOS, and the
  last resort is `process.report`, which does not belong in Electron's worker
  threads. The path is pointed at a real glibc `ldd`.

`nix flake check` reads both edits back out of the built archive with `asar`
itself, and tests the copy fix against a stand-in store.

## The document runtime

On first launch the app downloads about 400 MB into `~/.cache/codex-runtimes`:
Node, Python, poppler, a headless LibreOffice and a few image codecs. That is
what its document, PDF, spreadsheet and presentation tools run on. It is not in
the `.deb`, OpenAI updates it on its own schedule, and it is built for generic
Linux, so on NixOS it can only start through
[nix-ld](https://github.com/nix-community/nix-ld).

`programs.chatgpt-desktop.primaryRuntime.enable` turns nix-ld on. nix-ld's
default libraries cover everything in the runtime but LibreOffice, which also
needs NSS, NSPR, fontconfig, freetype and lcms2. The package's wrapper adds
those five to `NIX_LD_LIBRARY_PATH` for the app and whatever it starts, rather
than to every program on the system. Each was found by leaving it out and
watching a document conversion fail.

Because OpenAI ships that runtime and this flake does not, nothing here pins
or tests it. A later runtime that needs another library would break document
conversion without this repository noticing. The app logs its checks of the
runtime at startup under `primary_runtime`, which is the place to look.

Off NixOS, install nix-ld yourself or go without those tools.

## Things to know

- **The app shares `~/.codex` with the Codex CLI**, and writes into its
  `config.toml` a `node_repl` MCP server whose command is a path inside this
  package. It rewrites that path every time it starts, so it only goes stale
  if the old version is garbage-collected after an update and before the app
  is next opened. Until then the CLI will fail to start that one server.
- **Computer Use is not available** in the Linux preview, per OpenAI.

## Development

```bash
nix develop              # curl, gnupg, jq, dpkg, shellcheck, nixfmt
nix flake check          # builds the package, checks the patches and the pin
./scripts/update.sh      # regenerate sources.json
./scripts/update.sh --check   # exit non-zero if a newer version exists
./scripts/update.sh --force   # rewrite even when already current
```

## Binary cache

CI pushes both architectures to `https://danielbodart.cachix.org`, so you can
substitute the build instead of downloading a 400 MB `.deb` and patching it
yourself.

The flake offers the cache through `nixConfig`, which Nix applies only if you
are a trusted user and otherwise reports as ignored. On NixOS the reliable
place to put it is your own configuration:

```nix
nix.settings = {
  substituters = [ "https://danielbodart.cachix.org" ];
  trusted-public-keys = [
    "danielbodart.cachix.org-1:751qv4GxLFJCThWMEw1WL6kUqY0DpF6oqPqsLKnnEwU="
  ];
};
```

## License

The packaging in this repository is MIT. ChatGPT Desktop itself is proprietary
and covered by [OpenAI's Terms of Use](https://openai.com/policies/terms-of-use).
This repository redistributes no OpenAI binaries; it records where to fetch
them and what they should hash to.
