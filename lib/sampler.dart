import 'package:flutter_soloud/flutter_soloud.dart';

import 'scale_mapper.dart';

/// Polyphonic note player on top of SoLoud.
///
/// One waveform source per pitch: Basicwave derives its phase step from the
/// voice sample rate, and play speed scales that same rate, so the two cancel
/// and setRelativePlaySpeed cannot change pitch. setWaveformFreq can.
class Sampler {
  final _sources = <int, AudioSource>{};
  bool _ready = false;

  Future<void> init() async {
    await SoLoud.instance.init();
    _ready = true;
  }

  Future<AudioSource> _source(int midi) async {
    final cached = _sources[midi];
    if (cached != null) return cached;
    // ponytail: triangle waveform voice; swap in loadAsset() sampled
    // instrument notes when timbre matters.
    final s = await SoLoud.instance.loadWaveform(WaveForm.triangle, false, 1, 0);
    SoLoud.instance.setWaveformFreq(s, midiToFreq(midi));
    return _sources[midi] = s;
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
