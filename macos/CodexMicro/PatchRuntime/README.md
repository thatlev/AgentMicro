# PatchRuntime bundle layout

The DMG build stages this directory into `AgentMicro.app/Contents/Resources/PatchRuntime`.
It must contain:

```text
PatchRuntime/
├── patch-chatgpt.sh
├── asar-inspect.cjs
├── codex-hid-shim.js
├── node                         # Apple Silicon Node 22.12+ executable
└── node_modules/
    └── @electron/asar/
        └── bin/asar.mjs         # pinned @electron/asar 4.2.1
```

`node_modules` must include the complete production dependency tree for
`@electron/asar`, not only the package itself. Version 4.2.1 is intentionally
locked because it is the current supported release used by this patcher; update
the lock and test fixtures together. The build must preserve executable
permissions on `node` and `patch-chatgpt.sh`.

For development, `PatchManager` and `tools/patch-chatgpt.sh` also accept:

- `CODEX_MICRO_PATCH_RUNTIME`: directory containing the layout above
- `CODEX_MICRO_NODE`: explicit Node executable
- `CODEX_MICRO_ASAR_JS`: explicit `asar.mjs` (legacy `asar.js` also works)
- `CODEX_MICRO_SHIM`: explicit `codex-hid-shim.js`
- `CODEX_MICRO_INSPECTOR`: explicit `asar-inspect.cjs`
- `CODEX_MICRO_BACKUP_ROOT`: alternate versioned-backup directory
- `CODEX_MICRO_LEGACY_BACKUP_ROOT`: resource-only backups from the earlier helper
- `CODEX_MICRO_STATE_ROOT`: alternate operation-lock directory
- `CODEX_MICRO_DEVELOPER_FALLBACK=1`: allow system Node and `npx @electron/asar`

The distributed app sets `CODEX_MICRO_DEVELOPER_FALLBACK=0`, so patching never
downloads code at runtime.

## Backup retention

AgentMicro retains one complete pristine `ChatGPT.app` backup for every patched
ChatGPT version/build. Complete backups are intentionally never pruned
automatically because they are the only way to restore OpenAI's original
signature after local patching. Disk use therefore grows when several ChatGPT
versions are patched; users may remove obsolete version directories manually
only after confirming they no longer need to restore those builds.

A backup is labelled `complete-signed` only after deep signature validation,
confirmation that it is not ad-hoc signed, and an exact OpenAI TeamIdentifier
match (`2DC432GLL2`). The retained manifest records that signer identity.

Existing resource-only backups under `~/.codexbridge/backup/<version>` are
validated and kept in place. Restoring one produces pristine application
resources inside a complete app that is signed locally—not by OpenAI. The
patcher never overwrites or automatically deletes these earlier backups.
