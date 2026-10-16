// SPDX-License-Identifier: LGPL-3.0-only
// Protocol adaptation of rany2/edge-tts, Copyright (c) 2025- rany.
// Dart implementation modified 2026-10-15. See assets/licenses/edge-tts.txt.
import 'dart:convert';
import 'dart:typed_data';

/// Edge read-aloud v2 proof. This is a wire-protocol checksum, not encryption.
abstract final class EdgeProtocol {
  static const version = '2-143.0.3650.75';
  static const clientIdentifier = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const _mask = 0xffffffff;
  static const _initial = [
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  static const _working = [
    0xfd9fbea2,
    0x91243ce7,
    0xbe499094,
    0xcd2e1e0a,
    0x6c006f49,
    0x04bd35ab,
    0xfeb0a7e4,
    0x03effbd2,
  ];
  static const _schedule = [
    0xeb24bf9e,
    0x1558691f,
    0xa0c09ee2,
    0x0cfa32ba,
    0xa622ee8c,
    0xd1dd9491,
    0xc0dd25a0,
    0xf9e70ab6,
    0xf0c31573,
    0x7058ce4e,
    0x7188e606,
    0x00e5ab33,
    0xd258b060,
    0x72766564,
  ];
  static const _roundConstants = [
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];
  static const _coefficients = [
    (0xe82e91b1, 0xb32700d0),
    (0x44de24c6, 0x88dff51d),
    (0x3beb65bc, 0x29514038),
    (0xc89c5933, 0xb328cbdf),
    (0x8d1ec211, 0xd405b4d5),
    (0x314ef5d5, 0x26e55f3c),
    (0xe92491b1, 0x607801c6),
    (0xf0a5b9d5, 0x82b2c1fb),
    (0x06064cf3, 0xfa51a3da),
    (0xda79fa60, 0x207cc464),
    (0xbed20560, 0x3c3c74f3),
    (0x89f9c9f8, 0xd2d14b61),
    (0x35fa38c6, 0xbb04a2c1),
    (0xcb49e3c6, 0xc5626167),
  ];
  static int? _cachedWindow;
  static String? _cachedProof;

  static String timeProof(DateTime now) {
    final seconds = now.toUtc().millisecondsSinceEpoch ~/ 1000 + 11644473600;
    final window = seconds - seconds % 300;
    if (_cachedWindow == window) return _cachedProof!;
    final data = Uint8List.fromList(
      ascii.encode('${window * 10000000}$clientIdentifier'),
    );
    final digest = _digest(data);
    final cs = _cs64(data, digest);
    final bytes = ByteData(8)
      ..setUint32(0, cs.$1, Endian.little)
      ..setUint32(4, cs.$2, Endian.little);
    _cachedWindow = window;
    return _cachedProof = '${_hex(bytes.buffer.asUint8List())}-${_hex(digest)}';
  }

  static String _hex(List<int> data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  static int _rotate(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask;
  static int _swap(int x) => ((x << 16) | ((x & _mask) >> 16)) & _mask;
  static int _sigma0(int x) => _rotate(x, 7) ^ _rotate(x, 18) ^ (x >> 3);
  static int _sigma1(int x) => _rotate(x, 17) ^ _rotate(x, 19) ^ (x >> 10);

  static void _expand(List<int> words) {
    for (var i = words.length; i < 64; i++) {
      words.add(
        (_sigma1(words[i - 2]) +
                words[i - 7] +
                _sigma0(words[i - 15]) +
                words[i - 16]) &
            _mask,
      );
    }
  }

  static List<int> _rounds(List<int> state, List<int> words, {int start = 0}) {
    var [a, b, c, d, e, f, g, h] = state;
    for (var i = start; i < 64; i++) {
      final constant = start == 14 && i == 14 ? 0xc9dc06a7 : _roundConstants[i];
      final t1 =
          h +
          (_rotate(e, 6) ^ _rotate(e, 11) ^ _rotate(e, 25)) +
          (g ^ (e & (f ^ g))) +
          constant +
          words[i];
      final t2 =
          (_rotate(a, 2) ^ _rotate(a, 13) ^ _rotate(a, 22)) +
          ((a & b) | (c & (a | b)));
      [a, b, c, d, e, f, g, h] = [
        (t1 + t2) & _mask,
        a,
        b,
        c,
        (d + t1) & _mask,
        e,
        f,
        g,
      ];
    }
    return [a, b, c, d, e, f, g, h];
  }

  static Uint8List _digest(Uint8List data) {
    final prefix = ByteData.sublistView(data);
    final words = [
      ...List.filled(14, 0),
      data[0] << 16 | data[1] << 8 | data[2],
      prefix.getUint32(3),
    ];
    for (var i = 16; i < 30; i++) {
      var value = _schedule[i - 16];
      if (i - 2 >= 14) {
        value += _sigma1(words[i - 2]) ^ (i == 16 ? 0x000b92c0 : 0);
      }
      if (i - 7 >= 14) value += words[i - 7];
      if (i - 15 >= 14) {
        value += _sigma0(words[i - 15]) ^ (i == 29 ? 0x059c0b80 : 0);
      }
      words.add(value & _mask);
    }
    words.add(
      (_sigma1(words[28]) +
              words[23] +
              _sigma0(words[15]) +
              words[14] +
              0xc9dc06a7 -
              _roundConstants[14]) &
          _mask,
    );
    _expand(words);
    final working = _rounds(_working, words, start: 14);
    var state = List.generate(8, (i) => (_initial[i] + working[i]) & _mask);
    final length = 57 + data.length;
    final padding = (55 - length) % 64;
    final tail = Uint8List(data.length - 7 + 1 + padding + 8);
    tail.setRange(0, data.length - 7, data, 7);
    tail[data.length - 7] = 0x80;
    final view = ByteData.sublistView(tail)
      ..setUint64(tail.length - 8, length * 8);
    for (var offset = 0; offset < tail.length; offset += 64) {
      final block = List.generate(16, (i) => view.getUint32(offset + i * 4));
      _expand(block);
      final result = _rounds(state, block);
      state = List.generate(8, (i) => (state[i] + result[i]) & _mask);
    }
    final result = ByteData(32);
    for (var i = 0; i < 8; i++) {
      result.setUint32(i * 4, state[i]);
    }
    return result.buffer.asUint8List();
  }

  static (int, int) _cs64(Uint8List data, Uint8List digest) {
    final key = ByteData.sublistView(digest);
    final keys = [
      key.getUint32(0, Endian.little) | 1,
      key.getUint32(4, Endian.little) | 1,
    ];
    final factors = keys.map((k) => (k * 0x82893933) & _mask).toList();
    final terms = List.generate(
      _coefficients.length,
      (i) => (_coefficients[i].$1 * factors[i % 2]) & _mask,
    );
    final offsets = _coefficients.map((c) => c.$2).toList();
    final padded = Uint8List(((data.length + 1 + 7) ~/ 8) * 8)
      ..setRange(1, data.length + 1, data);
    final view = ByteData.sublistView(padded);
    for (var i = 0; i < padded.length ~/ 4; i++) {
      final word = view.getUint32(i * 4, Endian.little);
      var term = word * keys[i % 2];
      var offset = _swap(word) * (i.isEven ? 0xef0569fb : 0xc31713db);
      if (i == 0) {
        term += 0xf2f90b1a * factors[0];
        offset += 0x0b1a0000;
      }
      terms.add(term & _mask);
      offsets.add(offset & _mask);
    }
    var swapAcc = 0, swapLast = 0, state = 0, acc = 0;
    for (var i = 0; i < terms.length; i += 2) {
      final x = terms[i], y = terms[i + 1];
      var q = (_swap((offsets[i] + x) & _mask) * 0x76f50f34) & _mask;
      swapAcc += (_swap(q) * 0xc3efea97 + q) & _mask;
      q = (_swap((offsets[i + 1] + y) & _mask) * 0x1881ce3c) & _mask;
      swapLast = (_swap(q) * 0x35bd1ec9 + q) & _mask;
      swapAcc = (swapAcc + swapLast) & _mask;
      state = (state * keys[0] + x) & _mask;
      for (final factor in [0xcf98b111, 0x87085b9f, 0x12ceb96d, 0x257e1d83]) {
        state = (_swap(state) * factor) & _mask;
      }
      acc += state;
      var t = (state * keys[1] + y) & _mask;
      for (final factor in [0xa27416f5, 0xd38396ff, 0x7c932b89, 0xbfa49f69]) {
        t = (_swap(t) * factor) & _mask;
      }
      state = t;
      acc = (acc + state) & _mask;
    }
    return (swapLast ^ state, swapAcc ^ acc);
  }
}
