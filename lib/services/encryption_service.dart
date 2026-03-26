import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:developer' as dev;
import 'package:pointycastle/export.dart';

/// RSA-OAEP encryption service.
/// Tries SHA-256 for both label hash and MGF1 first (pointycastle built-in),
/// which is the most standard configuration.
class EncryptionService {
  /// Encrypt using pointycastle's built-in OAEPEncoding with SHA-256
  static String encryptWithPublicKey(String data, String publicKeyPem) {
    try {
      dev.log('🔐 Encrypting: "${data.length}" chars');

      final publicKey = _parsePublicKeyFromPem(publicKeyPem);
      dev.log('🔑 Parsed key: modulus=${publicKey.modulus!.bitLength} bits, e=${publicKey.publicExponent}');

      final dataBytes = Uint8List.fromList(utf8.encode(data));

      // Use pointycastle's built-in OAEPEncoding with SHA-256
      // This uses SHA-256 for BOTH label hash AND MGF1
      final encryptor = OAEPEncoding.withSHA256(RSAEngine())
        ..init(true, PublicKeyParameter<RSAPublicKey>(publicKey));

      final encrypted = encryptor.process(dataBytes);
      final result = base64.encode(encrypted);

      dev.log('✅ Encrypted OK: ${encrypted.length} bytes → ${result.length} base64 chars');
      return result;
    } catch (e, stack) {
      dev.log('❌ SHA256-both encryption failed: $e');
      dev.log('📍 $stack');

      // Fallback: try manual SHA-256 label + SHA-1 MGF1 (matching node-forge config)
      try {
        dev.log('🔄 Trying fallback: SHA-256 label + SHA-1 MGF1...');
        return _encryptManualOaep(data, publicKeyPem);
      } catch (e2) {
        dev.log('❌ Fallback also failed: $e2');
        rethrow;
      }
    }
  }

  /// Fallback: Manual OAEP with SHA-256 label hash + SHA-1 MGF1
  static String _encryptManualOaep(String data, String publicKeyPem) {
    final publicKey = _parsePublicKeyFromPem(publicKeyPem);
    final k = (publicKey.modulus!.bitLength + 7) ~/ 8;
    final message = Uint8List.fromList(utf8.encode(data));

    const int hLen = 32; // SHA-256

    if (message.length > k - 2 * hLen - 2) {
      throw Exception('Message too long for RSA-OAEP');
    }

    // lHash = SHA-256("")
    final sha256 = SHA256Digest();
    final lHash = Uint8List(hLen);
    sha256.doFinal(lHash, 0);

    // DB = lHash || PS || 0x01 || M
    final dbLen = k - hLen - 1;
    final db = Uint8List(dbLen);
    db.setRange(0, hLen, lHash);
    db[dbLen - message.length - 1] = 0x01;
    db.setRange(dbLen - message.length, dbLen, message);

    // Random seed
    final rng = Random.secure();
    final seed = Uint8List.fromList(List.generate(hLen, (_) => rng.nextInt(256)));

    // MGF1 with SHA-1
    final dbMask = _mgf1(seed, dbLen, SHA1Digest());
    final maskedDB = _xor(db, dbMask);
    final seedMask = _mgf1(maskedDB, hLen, SHA1Digest());
    final maskedSeed = _xor(seed, seedMask);

    // EM = 0x00 || maskedSeed || maskedDB
    final em = Uint8List(k);
    em[0] = 0x00;
    em.setRange(1, 1 + hLen, maskedSeed);
    em.setRange(1 + hLen, k, maskedDB);

    // Raw RSA
    final m = _os2ip(em);
    final c = m.modPow(publicKey.publicExponent!, publicKey.modulus!);
    final cipherBytes = _i2osp(c, k);

    final result = base64.encode(cipherBytes);
    dev.log('✅ Manual OAEP encrypted: ${result.length} base64 chars');
    return result;
  }

  static Uint8List _mgf1(Uint8List seed, int length, Digest hash) {
    final hashLen = hash.digestSize;
    final result = Uint8List(length);
    int offset = 0;
    int counter = 0;
    while (offset < length) {
      final c = Uint8List(4);
      c[0] = (counter >> 24) & 0xFF;
      c[1] = (counter >> 16) & 0xFF;
      c[2] = (counter >> 8) & 0xFF;
      c[3] = counter & 0xFF;
      hash.reset();
      hash.update(seed, 0, seed.length);
      hash.update(c, 0, 4);
      final hashOut = Uint8List(hashLen);
      hash.doFinal(hashOut, 0);
      final toCopy = (length - offset < hashLen) ? length - offset : hashLen;
      result.setRange(offset, offset + toCopy, hashOut);
      offset += toCopy;
      counter++;
    }
    return result;
  }

  static Uint8List _xor(Uint8List a, Uint8List b) {
    final result = Uint8List(a.length);
    for (int i = 0; i < a.length; i++) result[i] = a[i] ^ b[i];
    return result;
  }

  static BigInt _os2ip(Uint8List bytes) {
    BigInt r = BigInt.zero;
    for (int i = 0; i < bytes.length; i++) r = (r << 8) | BigInt.from(bytes[i]);
    return r;
  }

  static Uint8List _i2osp(BigInt n, int len) {
    final result = Uint8List(len);
    var temp = n;
    for (int i = len - 1; i >= 0; i--) {
      result[i] = (temp & BigInt.from(0xFF)).toInt();
      temp = temp >> 8;
    }
    return result;
  }

  // ─── PEM → RSAPublicKey ────────────────────────────────
  static RSAPublicKey _parsePublicKeyFromPem(String pem) {
    final stripped = pem
        .replaceAll(RegExp(r'-----[^-]+-----'), '')
        .replaceAll(RegExp(r'\s+'), '');

    final bytes = Uint8List.fromList(base64.decode(stripped));
    dev.log('📦 PEM decoded: ${bytes.length} bytes, first bytes: ${bytes.sublist(0, min(10, bytes.length)).map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}');

    int pos = 0;

    // Outer SEQUENCE
    if (bytes[pos] != 0x30) throw Exception('Expected SEQUENCE at pos $pos, got 0x${bytes[pos].toRadixString(16)}');
    pos++;
    pos = _skipLen(bytes, pos);

    // AlgorithmIdentifier SEQUENCE — skip entirely
    if (bytes[pos] != 0x30) throw Exception('Expected AlgorithmIdentifier SEQUENCE at pos $pos');
    pos++;
    final algLen = _readLen(bytes, pos);
    pos = _skipLen(bytes, pos) + algLen;

    // BIT STRING
    if (bytes[pos] != 0x03) throw Exception('Expected BIT STRING at pos $pos, got 0x${bytes[pos].toRadixString(16)}');
    pos++;
    pos = _skipLen(bytes, pos);
    if (bytes[pos] != 0x00) dev.log('⚠️ BIT STRING unused bits = ${bytes[pos]}');
    pos++; // skip unused bits byte

    // Inner SEQUENCE (RSAPublicKey)
    if (bytes[pos] != 0x30) throw Exception('Expected inner SEQUENCE at pos $pos');
    pos++;
    pos = _skipLen(bytes, pos);

    // INTEGER: modulus
    if (bytes[pos] != 0x02) throw Exception('Expected INTEGER (modulus) at pos $pos');
    pos++;
    final modLen = _readLen(bytes, pos);
    pos = _skipLen(bytes, pos);
    final modBytes = bytes.sublist(pos, pos + modLen);
    pos += modLen;

    // INTEGER: exponent
    if (bytes[pos] != 0x02) throw Exception('Expected INTEGER (exponent) at pos $pos');
    pos++;
    final expLen = _readLen(bytes, pos);
    pos = _skipLen(bytes, pos);
    final expBytes = bytes.sublist(pos, pos + expLen);

    final modulus = _os2ip(modBytes);
    final exponent = _os2ip(expBytes);

    dev.log('📐 Modulus: ${modulus.bitLength} bits');
    dev.log('📐 Exponent: $exponent');
    dev.log('📐 Modulus first 4 bytes: ${modBytes.sublist(0, min(4, modBytes.length)).map((b) => b.toRadixString(16).padLeft(2, '0')).join('')}');

    if (modulus.bitLength < 1024) {
      throw Exception('Parsed modulus too small: ${modulus.bitLength} bits. Key parsing likely failed.');
    }

    return RSAPublicKey(modulus, exponent);
  }

  static int _readLen(Uint8List b, int o) {
    if (b[o] < 0x80) return b[o];
    final n = b[o] & 0x7F;
    int l = 0;
    for (int i = 0; i < n; i++) l = (l << 8) | b[o + 1 + i];
    return l;
  }

  static int _skipLen(Uint8List b, int o) {
    if (b[o] < 0x80) return o + 1;
    return o + 1 + (b[o] & 0x7F);
  }
}
