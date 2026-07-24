# Bundled patch runtime

`scripts/build-macos.sh` replaces this development placeholder in the built
application with a self-contained runtime:

- `patch-chatgpt.sh`
- `codex-hid-shim.js`
- `asar-inspect.cjs`
- `node`
- `node_modules/@electron/asar/bin/asar.mjs` and its locked dependency tree

The generated runtime belongs in the application bundle, not in source
control. During development the patch manager can fall back to the repository
copies of the patch script and shim.
