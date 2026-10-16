import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/listening/edge_protocol.dart';

void main() {
  test('v2 proof matches upstream protocol vectors', () {
    const vectors = {
      0: '52BC7A17B50DFEC9-28C4394775C8751CD2F6859C030C06DB1489ACAB3B3A7651831FC26895177ED6',
      1700000000:
          '2CD23A2CA0B2595A-F3C846C370E05F9CC83ACC5F995C5F5D87A4D0F14CE8936A0F902E64099E38A2',
      1792000000:
          '31DE969FFA38E06B-BD29DC903722D717D852F4F854F2386D98C8D3A93663E1A1AE89223A876AFDB4',
      1792000299:
          '5F8DA6933397AD95-A8B5CB1FF5822A33E4E3946887E383C696D6B8965DDAC945260125764E667EA8',
    };
    for (final entry in vectors.entries) {
      expect(
        EdgeProtocol.timeProof(
          DateTime.fromMillisecondsSinceEpoch(entry.key * 1000, isUtc: true),
        ),
        entry.value,
      );
    }
    expect(EdgeProtocol.version, '2-143.0.3650.75');
  });
  test('time proof reuses only the same five-minute window', () {
    final start = DateTime.utc(2026, 10, 15, 12);
    final proof = EdgeProtocol.timeProof(start);
    expect(
      EdgeProtocol.timeProof(
        start.add(const Duration(minutes: 4, seconds: 59)),
      ),
      proof,
    );
    expect(EdgeProtocol.timeProof(start.toLocal()), proof);
    expect(
      EdgeProtocol.timeProof(start.add(const Duration(minutes: 5))),
      isNot(proof),
    );
  });
}
