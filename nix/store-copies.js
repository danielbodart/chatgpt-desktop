// Prepended by the chatgpt-desktop Nix package to the app's main-process and
// worker entry points.
//
// The app seeds ~/.codex with plugins and skills by copying them out of its
// own resources directory with fs.promises.cp and copyFile, both of which
// carry the source's mode across. Out of /usr/lib that mode is writable by
// root, which on Debian is the owner, so nobody notices. Out of the Nix store
// it is read-only for everyone, and the app then fails to rewrite the
// copies' manifests or delete its own staging directories.
//
// Rather than patch each call site in the minified bundles -- fifteen of
// them, renamed on every release -- this wraps the two functions once, and
// gives the owner write access to anything copied out of the store.
(() => {
  const fs = require("node:fs");
  const path = require("node:path");
  const { fileURLToPath } = require("node:url");

  const storeDir = "@storeDir@/";

  const toPath = (p) => (p instanceof URL ? fileURLToPath(p) : String(p));

  const fromStore = (source) => {
    try {
      return path.resolve(toPath(source)).startsWith(storeDir);
    } catch {
      return false;
    }
  };

  // lstat, so that a symlink the copy preserved is never followed back into
  // the store or anywhere else.
  const makeWritable = async (target) => {
    const stat = await fs.promises.lstat(target);
    if (stat.isSymbolicLink()) return;
    await fs.promises.chmod(target, (stat.mode & 0o7777) | 0o200);
    if (stat.isDirectory()) {
      for (const name of await fs.promises.readdir(target)) {
        await makeWritable(path.join(target, name));
      }
    }
  };

  for (const name of ["cp", "copyFile"]) {
    const original = fs.promises[name];
    fs.promises[name] = async function (source, destination, ...rest) {
      await original.call(this, source, destination, ...rest);
      if (fromStore(source)) await makeWritable(toPath(destination));
    };
  }
})();
