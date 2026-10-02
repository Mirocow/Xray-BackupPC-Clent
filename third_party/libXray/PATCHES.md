# Vendored fork: XTLS/libXray + backuppc protocol patches

Upstream: https://github.com/XTLS/libXray
(commit `3c694b23290f9849fe52284a345ebd4343bc90cd`, MIT, see LICENSE).
Upstream code is **untouched except the six files below** — everything
else in this tree is byte-identical to the upstream commit recorded in
[manifest.json](manifest.json).

Why vendored as patched source: the backuppc protocol is embedded here
so that local and CI builds compile exactly the committed tree (no
external checkout, no anchor-patching step), and the integration can be
extended by editing this directory like any other code of the repository.

All our edits are marked in the code with `backuppc-core` comments and
confined to:

| File | Change |
|---|---|
| `xray/xray.go` | imports `backuppc-core/preprocess`; `newXrayInstance` runs the JSON through `NormalizeJSON` → `LoadConfig` → `Apply` (covers `RunXray`, `TestXray` and the desktop OneXrayCore binary) |
| `share/parse_share.go` | `backuppc://` added to the share-link scheme list + a `case "backuppc"` branch in the parsing switch |
| `share/backuppc.go` | new file: share-link parsing → `conf.OutboundDetourConfig` + the settings validator (formerly injected from a template by the retired `patch.py`) |
| `share/validate_outbound.go` | backuppc outbounds are validated by their own validator inside `filterBuildableOutbounds` |
| `share/marshal_share.go` | projection of the protocol's settings fields in `projectShareOutbound` + backuppc validation in `validateProjectedShareOutbound` |
| `go.mod` | `require backuppc-core` + `replace backuppc-core => ../../core` and `replace backuppc => ../../backuppc` (this repository's modules, paths relative to this directory) |

`go.sum` is unchanged relative to upstream: the two replaced modules are
local directories and add no remote hashes.

To see the exact current diff against the upstream base commit:

```bash
git clone https://github.com/XTLS/libXray.git /tmp/libXray-upstream
git -C /tmp/libXray-upstream checkout 3c694b23290f9849fe52284a345ebd4343bc90cd
diff -ru --exclude=.git --exclude=manifest.json --exclude=UPSTREAM.md \
     --exclude=PATCHES.md /tmp/libXray-upstream third_party/libXray
```

Update procedure for a newer upstream: see [UPSTREAM.md](UPSTREAM.md).
