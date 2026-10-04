/// MeshKeypair — Ed25519 keypair через package:cryptography (FlutterFire).
///
/// Реальная crypto (native через cryptography_flutter plugin). В отличие
/// от v1.4 placeholder, здесь настоящая подпись/проверка Ed25519.
///
/// См. docs/PROTOCOL.md §11.4 (Peer-Sig) и docs/mesh/MESH_PLAN-v2.1.md §1.4.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// MeshKeypair — holder для Ed25519 ключей.
class MeshKeypair {
  final SimpleKeyPair keyPair;
  final SimplePublicKey publicKey;

  MeshKeypair._(this.keyPair, this.publicKey);

  /// PublicKeyBase64 — base64-encoded публичный ключ (для регистрации в peers).
  Future<String> publicKeyBase64() async {
    final bytes = await publicKey.bytes;
    return base64.encode(bytes);
  }

  /// Sign — Ed25519 подпись challenge для X-Backup-Peer-Sig.
  ///
  /// Формат возвращаемой строки:
  ///   "<base64-signature>|<nonce-hex32>"
  ///
  /// challenge = sid + "|" + decimal(idx) + "|" + nonceHex (32 chars)
  /// nonce — 16 случайных байт, hex-encoded (32 chars).
  Future<String> sign(String sid, int idx) async {
    final algorithm = Ed25519();
    final nonce = _generateNonce(16);
    final nonceHex = _bytesToHex(nonce);
    final challenge = utf8.encode('$sid|$idx|$nonceHex');
    final sig = await algorithm.sign(challenge, keyPair: keyPair);
    final sigBytes = await sig.bytes;
    return '${base64.encode(sigBytes)}|$nonceHex';
  }

  /// VerifyPeerSig — проверка Ed25519 подписи входящего peer-chunk.
  ///
  /// sigHeader format: "<base64-sig>|<nonce-hex32>"
  /// peerPubKeyB64 — base64-encoded публичный ключ peer-а.
  static Future<bool> verifyPeerSig(
    String peerPubKeyB64,
    String sid,
    int idx,
    String sigHeader,
  ) async {
    if (sigHeader.isEmpty || peerPubKeyB64.isEmpty) return false;
    final parts = sigHeader.split('|');
    if (parts.length != 2) return false;
    final sigB64 = parts[0];
    final nonceHex = parts[1];
    try {
      final sigBytes = base64.decode(sigB64);
      final pubBytes = base64.decode(peerPubKeyB64);
      final algorithm = Ed25519();
      final challenge = utf8.encode('$sid|$idx|$nonceHex');
      final sig = Signature(sigBytes, publicKey: SimplePublicKey(pubBytes));
      return algorithm.verify(challenge, signature: sig);
    } catch (_) {
      return false;
    }
  }

  /// Generate — генерирует новый keypair (не сохраняет).
  static Future<MeshKeypair> generate() async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final pubKey = await keyPair.extractPublicKey();
    return MeshKeypair._(keyPair, pubKey);
  }

  /// LoadOrCreate — загружает keypair из path, иначе генерирует + сохраняет.
  ///
  /// path — путь к файлу .pem (приватный ключ в base64).
  static Future<MeshKeypair> loadOrCreate(String path) async {
    // Try load
    final file = File(path);
    if (await file.exists()) {
      try {
        final contents = await file.readAsString();
        final parts = contents.split('\n');
        if (parts.length >= 2) {
          final privB64 = parts[0];
          final pubB64 = parts[1];
          final privBytes = base64.decode(privB64);
          final pubBytes = base64.decode(pubB64);
          final keyPair = SimpleKeyPairData(privBytes,
              type: KeyPairType.ed25519);
          final pubKey = SimplePublicKey(pubBytes,
              type: KeyPairType.ed25519);
          return MeshKeypair._(keyPair, pubKey);
        }
      } catch (_) {
        // fallthrough — regenerate
      }
    }
    // Generate new
    final kp = await generate();
    // Persist
    final privBytes = await kp.keyPair.extractPrivateKey();
    final pubBytes = await kp.publicKey.bytes;
    final contents = '${base64.encode(privBytes)}\n${base64.encode(pubBytes)}';
    await File(path).parent.create(recursive: true);
    await file.writeAsString(contents, mode: FileMode.write);
    return kp;
  }
}

// ─── Helpers ───────────────────────────────────────────────────────────

List<int> _generateNonce(int length) {
  final rng = DateTime.now().microsecondsSinceEpoch;
  final out = <int>[];
  var x = rng;
  for (var i = 0; i < length; i++) {
    x = (x * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFF;
    out.add((x ^ (x >> 16)) & 0xFF);
  }
  return out;
}

String _bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// ignore_for_file: unused_element
Uint8List _unused() => Uint8List(0);
