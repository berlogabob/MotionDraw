import 'dart:math';

/// Interval sets in semitones from the root.
const scales = <String, List<int>>{
  'pentatonic minor': [0, 3, 5, 7, 10],
  'pentatonic major': [0, 2, 4, 7, 9],
  'minor': [0, 2, 3, 5, 7, 8, 10],
  'major': [0, 2, 4, 5, 7, 9, 11],
  'blues': [0, 3, 5, 6, 7, 10],
  'chromatic': [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
};

/// Bin 0 = lowest note. [root] is a MIDI note number (57 = A3).
int binToMidi(
  int bin, {
  int root = 57,
  List<int> intervals = const [0, 3, 5, 7, 10],
}) =>
    root + 12 * (bin ~/ intervals.length) + intervals[bin % intervals.length];

double midiToFreq(int midi) => 440 * pow(2, (midi - 69) / 12).toDouble();
