// Exercises store-copies.js against a stand-in store directory, run by the
// store-copies check in flake.nix. The real store cannot be used: a test has
// no business writing there, and inside the build sandbox it cannot.
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const shimSource = process.argv[2];
const root = fs.mkdtempSync(path.join(os.tmpdir(), "store-copies-"));
const store = path.join(root, "store");
const home = path.join(root, "home");

// A read-only tree, the way the store presents one: 0555 directories, 0444
// files, and a symlink pointing back inside.
const source = path.join(store, "plugins");
fs.mkdirSync(path.join(source, "nested"), { recursive: true });
fs.writeFileSync(path.join(source, "nested", "plugin.json"), "{}");
fs.symlinkSync("nested/plugin.json", path.join(source, "link"));
fs.chmodSync(path.join(source, "nested", "plugin.json"), 0o444);
fs.chmodSync(path.join(source, "nested"), 0o555);
fs.chmodSync(source, 0o555);

// The same content outside the store, whose modes must be left alone.
const elsewhere = path.join(root, "elsewhere.json");
fs.writeFileSync(elsewhere, "{}");
fs.chmodSync(elsewhere, 0o444);

const shim = fs.readFileSync(shimSource, "utf8").replace("@storeDir@", store);
new Function("require", shim)(require);

const writable = (p) => (fs.lstatSync(p).mode & 0o200) !== 0;

(async () => {
  fs.mkdirSync(home);

  const copied = path.join(home, "plugins");
  await fs.promises.cp(source, copied, { recursive: true, verbatimSymlinks: true });
  assert.ok(writable(copied), "copied directory is writable");
  assert.ok(writable(path.join(copied, "nested")), "nested directory is writable");
  assert.ok(writable(path.join(copied, "nested", "plugin.json")), "copied file is writable");
  assert.ok(fs.lstatSync(path.join(copied, "link")).isSymbolicLink(), "symlink preserved");
  fs.writeFileSync(path.join(copied, "nested", "plugin.json"), '{"edited":true}');
  fs.rmSync(copied, { recursive: true });

  const single = path.join(home, "single.json");
  await fs.promises.copyFile(path.join(source, "nested", "plugin.json"), single);
  assert.ok(writable(single), "copyFile out of the store is writable");

  const untouched = path.join(home, "untouched.json");
  await fs.promises.copyFile(elsewhere, untouched);
  assert.ok(!writable(untouched), "copies from outside the store keep their mode");

  console.log("store-copies: ok");
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
