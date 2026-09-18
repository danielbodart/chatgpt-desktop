// Edit files inside an asar archive without repacking it.
//
//   node patch-asar.cjs IN.asar OUT.asar \
//     --prepend  <path in archive> <file whose contents to prepend> \
//     --replace  <path in archive> <exact text> <replacement>
//
// Repacking with `asar pack` would mean reproducing upstream's choice of
// which files live outside the archive in app.asar.unpacked, and that choice
// is irregular -- whole packages in some places, a handful of .node files in
// others -- and free to change between releases. This leaves all of it alone.
//
// An asar is a JSON index followed by the concatenated file contents, and
// every offset in the index is relative to the end of the index. So a file
// can be replaced by appending its new contents after the existing data and
// pointing its index entry at them. Nothing else moves; the old bytes stay
// behind unreferenced.
//
// Every edit must apply exactly as written. A --replace whose text is not
// found exactly once is an error rather than a no-op, so an upstream change
// to the patched code fails the build instead of silently shipping the bug.
"use strict";

const fs = require("node:fs");
const crypto = require("node:crypto");

const BLOCK_SIZE = 4 * 1024 * 1024;

const align4 = (n) => (n + 3) & ~3;

function readIndex(fd) {
  // Two Chromium pickles: the first holds only the size of the second, and
  // the second holds the length-prefixed JSON string.
  const sizes = Buffer.alloc(8);
  fs.readSync(fd, sizes, 0, 8, 0);
  const pickleSize = sizes.readUInt32LE(4);
  const pickle = Buffer.alloc(pickleSize);
  fs.readSync(fd, pickle, 0, pickleSize, 8);
  const jsonLength = pickle.readInt32LE(4);
  return {
    index: JSON.parse(pickle.toString("utf8", 8, 8 + jsonLength)),
    dataStart: 8 + pickleSize,
  };
}

function encodeIndex(index) {
  const json = Buffer.from(JSON.stringify(index), "utf8");
  const payloadSize = 4 + align4(json.length);
  const out = Buffer.alloc(8 + 4 + payloadSize);
  out.writeUInt32LE(4, 0);
  out.writeUInt32LE(4 + payloadSize, 4);
  out.writeUInt32LE(payloadSize, 8);
  out.writeInt32LE(json.length, 12);
  json.copy(out, 16);
  return out;
}

function entryFor(index, archivePath) {
  let node = index;
  for (const part of archivePath.split("/").filter(Boolean)) {
    node = node.files && node.files[part];
    if (!node) throw new Error(`${archivePath}: not in the archive`);
  }
  if (node.files || node.link) throw new Error(`${archivePath}: not a regular file`);
  if (node.unpacked) throw new Error(`${archivePath}: lives in app.asar.unpacked, edit it there`);
  return node;
}

function integrity(content) {
  const blocks = [];
  for (let i = 0; i < content.length; i += BLOCK_SIZE) {
    blocks.push(crypto.createHash("sha256").update(content.subarray(i, i + BLOCK_SIZE)).digest("hex"));
  }
  return {
    algorithm: "SHA256",
    hash: crypto.createHash("sha256").update(content).digest("hex"),
    blockSize: BLOCK_SIZE,
    blocks,
  };
}

function parseEdits(args) {
  const edits = [];
  while (args.length) {
    const flag = args.shift();
    if (flag === "--prepend" && args.length >= 2) {
      const [target, file] = args.splice(0, 2);
      const prefix = fs.readFileSync(file, "utf8");
      edits.push({ target, apply: (text) => `${prefix}\n${text}` });
    } else if (flag === "--replace" && args.length >= 3) {
      const [target, from, to] = args.splice(0, 3);
      edits.push({
        target,
        apply: (text) => {
          const count = text.split(from).length - 1;
          if (count !== 1) throw new Error(`${target}: expected "${from}" once, found it ${count} times`);
          return text.replace(from, () => to);
        },
      });
    } else {
      throw new Error(`unrecognised or incomplete argument: ${flag}`);
    }
  }
  return edits;
}

function main([input, output, ...rest]) {
  if (!input || !output) throw new Error("usage: patch-asar.cjs IN.asar OUT.asar [--prepend|--replace ...]");
  const edits = parseEdits(rest);

  const fd = fs.openSync(input, "r");
  const { index, dataStart } = readIndex(fd);
  const dataSize = fs.fstatSync(fd).size - dataStart;

  // Grouped by file, so two edits to the same file compose.
  const appended = [];
  let nextOffset = dataSize;
  for (const target of new Set(edits.map((e) => e.target))) {
    const entry = entryFor(index, target);
    const original = Buffer.alloc(entry.size);
    fs.readSync(fd, original, 0, entry.size, dataStart + Number(entry.offset));

    let text = original.toString("utf8");
    for (const edit of edits.filter((e) => e.target === target)) text = edit.apply(text);
    const content = Buffer.from(text, "utf8");

    entry.offset = String(nextOffset);
    entry.size = content.length;
    entry.integrity = integrity(content);
    appended.push(content);
    nextOffset += content.length;
    console.log(`patched ${target} (${original.length} -> ${content.length} bytes)`);
  }

  const out = fs.openSync(output, "w");
  fs.writeSync(out, encodeIndex(index));
  const chunk = Buffer.alloc(BLOCK_SIZE);
  for (let position = dataStart, bytes; (bytes = fs.readSync(fd, chunk, 0, chunk.length, position)) > 0; position += bytes) {
    fs.writeSync(out, chunk, 0, bytes);
  }
  for (const content of appended) fs.writeSync(out, content);
  fs.closeSync(out);
  fs.closeSync(fd);
}

try {
  main(process.argv.slice(2));
} catch (error) {
  console.error(`patch-asar: ${error.message}`);
  process.exit(1);
}
