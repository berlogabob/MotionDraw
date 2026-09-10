/// A looping step sequence of (bin, intensity) notes. Detections fill empty
/// slots first; once full the oldest slot is overwritten, so the phrase keeps
/// following the scene.
class Sequence {
  Sequence(int steps) : slots = List.filled(steps, null);
  List<(int, double)?> slots;
  int step = 0;
  int _write = 0;

  int get steps => slots.length;

  void add(int bin, double intensity) {
    final empty = slots.indexOf(null);
    final i = empty >= 0 ? empty : _write++ % steps;
    slots[i] = (bin, intensity);
  }

  /// The note at the current step, then advance.
  (int, double)? tick() {
    final n = slots[step];
    step = (step + 1) % steps;
    return n;
  }

  void clear() {
    slots = List.filled(steps, null);
    step = 0;
    _write = 0;
  }

  void resize(int n) {
    slots = [
      for (var i = 0; i < n; i++) i < slots.length ? slots[i] : null,
    ];
    step %= n;
    _write %= n;
  }
}
