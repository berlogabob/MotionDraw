import 'package:flutter_soloud/flutter_soloud.dart';

import 'scale_mapper.dart';

const instruments = ['sine', 'triangle', 'saw', 'square', 'supersaw'];

/// Polyphonic note player on top of SoLoud.
///
/// One waveform source per (instrument, pitch): Basicwave derives its phase
/// step from the voice sample rate and play speed scales that same rate, so
/// the two cancel and setRelativePlaySpeed cannot change pitch. setWaveformFreq
/// can.
class Sampler {
  final _sources = <(int, int), AudioSource>{};
  bool _ready = false;
  int instrument = 1; // triangle

  String get instrumentName => instruments[instrument];
  void cycleInstrument() => instrument = (instrument + 1) % instruments.length;

  Future<void> init() async {
    await SoLoud.instance.init();
    _ready = true;
  }

  Future<AudioSource> _source(int midi) async {
    final key = (instrument, midi);
    final cached = _sources[key];
    if (cached != null) return cached;
    // ponytail: sample instruments later — same cache, loadAsset() instead of
    // loadWaveform(), pitch-shifted from the nearest sample.
    final s = await switch (instrument) {
      0 => SoLoud.instance.loadWaveform(WaveForm.sin, false, 1, 0),
      2 => SoLoud.instance.loadWaveform(WaveForm.saw, false, 1, 0),
      3 => SoLoud.instance.loadWaveform(WaveForm.square, false, 1, 0),
      4 => SoLoud.instance.loadWaveform(WaveForm.saw, true, 0.5, 0.15),
      _ => SoLoud.instance.loadWaveform(WaveForm.triangle, false, 1, 0),
    };
    SoLoud.instance.setWaveformFreq(s, midiToFreq(midi));
    return _sources[key] = s;
  }

  /// [velocity] 0..1.
  Future<void> playNote(int midi, double velocity) async {
    if (!_ready) return;
    final soloud = SoLoud.instance;
    final handle =
        soloud.play(await _source(midi), volume: 0.5 * velocity.clamp(0.0, 1.0));
    soloud.fadeVolume(handle, 0, const Duration(milliseconds: 600));
    soloud.scheduleStop(handle, const Duration(milliseconds: 650));
  }
}
