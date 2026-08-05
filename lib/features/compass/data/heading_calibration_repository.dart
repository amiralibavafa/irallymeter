import '../../../core/storage/storage_service.dart';
import '../domain/heading_calibration.dart';

/// Persists the learned magnetic-to-true offset across launches.
///
/// Without this the calibration relearned from zero on every cold start, and
/// learning needs 20 observations taken above 18 km/h on a fix better than 8 m.
/// On a rally that is minutes of driving during which the "use true north"
/// switch appears to do nothing.
///
/// Only a LEARNED offset is written. Storing an unconfirmed one would mean the
/// next launch restores a number that nothing ever agreed on, which is worse
/// than storing nothing: it looks like history when it is a guess.
class HeadingCalibrationRepository {
  HeadingCalibrationRepository(this._storage);

  final StorageService _storage;

  /// The saved offset and the sample count behind it, or null if none.
  ///
  /// Both keys must be present. A half-written pair is treated as absent
  /// rather than defaulted, because an offset with a defaulted count would be
  /// restored at a confidence it never had.
  ({double offsetDeg, int samples})? load() {
    final offset = _storage.read<double>(StorageKeys.headingOffsetDeg, double.nan);
    final samples = _storage.read<int>(StorageKeys.headingSamples, 0);
    if (!offset.isFinite || samples <= 0) return null;
    return (offsetDeg: offset, samples: samples);
  }

  void save(HeadingCalibration cal) {
    _storage.write(StorageKeys.headingOffsetDeg, cal.offsetDeg);
    _storage.write(StorageKeys.headingSamples, cal.samples);
  }

  void clear() {
    _storage.delete(StorageKeys.headingOffsetDeg);
    _storage.delete(StorageKeys.headingSamples);
  }
}
