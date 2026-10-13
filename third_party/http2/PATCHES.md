# Vendored fork: package:http2 3.1.0 + backuppc performance patches

Upstream: https://github.com/dart-lang/http/tree/master/pkgs/http2
(version 3.1.0, BSD-3-Clause, see LICENSE; upstream code is untouched
except the two patches below).

Why vendored: the client transport of xray-vless-backuppc streams
hundreds of GiB through a single HTTP/2 POST stream (chunked gRPC
carrier). Two upstream flow-control behaviours cap that at ~10 MiB/s
on a loopback where raw TLS runs at ~80 MiB/s, which is not enough
for 8K video with headroom. Both patches are protocol-legal (RFC 7540)
and additive for peers.

## Patch 1 — connection-level flow control window (`lib/src/connection.dart`)

`ClientConnection` now sends `WINDOW_UPDATE(stream 0, 32 MiB - 65535)`
right after the connection preface and adjusts the local accounting.
Upstream leaves the connection window at the 64 KiB default;
`SETTINGS_INITIAL_WINDOW_SIZE` does not affect it (RFC 7540 §6.9.1),
so a fast peer stalls every 64 KiB waiting for replenishment.

## Patch 2 — batched WINDOW_UPDATE (`lib/src/flowcontrol/window_handler.dart`)

`IncomingWindowHandler.dataProcessed` now accumulates consumed bytes
and sends one WINDOW_UPDATE per 256 KiB instead of one update per
DATA frame (replaces the upstream TODO at the same place). With the
1 MiB stream window the peer always keeps >= 768 KiB of send budget;
with the 32 MiB connection window >= 31.7 MiB.

## Measured effect (loopback, single POST stream, 256 MiB)

| Layer                          | upstream | patched |
| ------------------------------ | -------- | ------- |
| http2 package echo             | 10 MiB/s | 59 MiB/s |
| full backuppc tunnel (Dart)    |  7 MiB/s | ~54 MiB/s |

Both patches only affect the client side of the vendored copy; the
`ServerConnection` path is untouched.
