import 'package:flutter_test/flutter_test.dart';
import 'package:motiondraw/sequence.dart';

void main() {
  test('fills empty slots in order and loops on tick', () {
    final s = Sequence(4);
    s.add(1, 0.5);
    s.add(2, 0.6);
    expect(s.tick(), (1, 0.5));
    expect(s.tick(), (2, 0.6));
    expect(s.tick(), isNull);
    expect(s.tick(), isNull);
    expect(s.tick(), (1, 0.5)); // wrapped
  });

  test('overwrites the oldest slot once full', () {
    final s = Sequence(2);
    s.add(1, 1);
    s.add(2, 1);
    s.add(3, 1);
    expect(s.slots, [(3, 1.0), (2, 1.0)]);
    s.add(4, 1);
    expect(s.slots, [(3, 1.0), (4, 1.0)]);
  });

  test('resize keeps the head, clear empties', () {
    final s = Sequence(4);
    for (var i = 0; i < 4; i++) {
      s.add(i, 1);
    }
    s.resize(2);
    expect(s.slots, [(0, 1.0), (1, 1.0)]);
    s.resize(3);
    expect(s.slots, [(0, 1.0), (1, 1.0), null]);
    s.clear();
    expect(s.slots, [null, null, null]);
    expect(s.step, 0);
  });
}
