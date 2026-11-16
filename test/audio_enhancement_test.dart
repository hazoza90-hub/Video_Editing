import 'dart:math';
import 'package:flutter_test/flutter_test.dart';

String buildFilter({
  int noiseFloor = -42,
  double gateAmount = 50,
  double deesser = 0,
  double bass = 0,
  double mid = 0,
  double presence = 0,
  double treble = 5,
  double volume = 100,
}) {
  final parts = <String>[];
  parts.add('highpass=f=80');

  final t = (gateAmount / 100).clamp(0.0, 1.0);
  final nf = noiseFloor.clamp(-60, -20);
  final expIn = nf + 10 + (t * 8).round();
  final gain = 8 + t * 15;
  final expOut = (nf + gain).clamp(-55, 0).round();
  parts.add(
    'compand=attacks=0.01:decays=0.1:points='
    '-80/-80|$nf/$nf|$expIn/$expOut|0/0|20/-3',
  );

  if (deesser > 0) {
    final deessGain = -(deesser / 100 * 10);
    parts.add('equalizer=f=8000:t=q:w=1:g=${deessGain.toStringAsFixed(1)}');
  }
  if (bass != 0) {
    parts.add('equalizer=f=80:t=o:w=100:g=${bass.toStringAsFixed(1)}');
  }
  if (mid != 0) {
    parts.add('equalizer=f=1000:t=o:w=500:g=${mid.toStringAsFixed(1)}');
  }
  if (presence != 0) {
    parts.add('equalizer=f=3000:t=o:w=1000:g=${presence.toStringAsFixed(1)}');
  }
  if (treble != 0) {
    parts.add('equalizer=f=8000:t=o:w=2000:g=${treble.toStringAsFixed(1)}');
  }
  if (volume != 100) {
    final db = 20 * (log(volume / 100) / ln10);
    parts.add('volume=${db.toStringAsFixed(1)}dB');
  }
  return parts.join(',');
}

void main() {
  group('Audio enhancer filter command', () {
    test('always has highpass + compand', () {
      final r = buildFilter();
      expect(r, contains('highpass=f=80'));
      expect(r, contains('compand='));
    });

    test('no deesser when disabled', () {
      final r = buildFilter(deesser: 0);
      expect(r, isNot(contains('t=q')));
    });

    test('deesser appears when > 0', () {
      final r = buildFilter(deesser: 50);
      expect(r, contains('equalizer=f=8000'));
      expect(r, contains('g=-5.0'));
    });

    test('volume appears only when not 100', () {
      final r = buildFilter(volume: 150);
      expect(r, contains('volume='));

      final r2 = buildFilter(volume: 100);
      expect(r2, isNot(contains('volume=')));
    });

    test('all equalizer bands appear', () {
      final r = buildFilter(bass: 3, mid: 2, presence: 4, treble: 3);
      expect(r, contains('equalizer=f=80'));
      expect(r, contains('equalizer=f=1000'));
      expect(r, contains('equalizer=f=3000'));
      expect(r, contains('equalizer=f=8000'));
    });

    test('compand points respect noise floor', () {
      final r = buildFilter(noiseFloor: -40, gateAmount: 50);
      expect(r, contains('-40/-40'));
    });
  });
}
