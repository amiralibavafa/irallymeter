import 'package:irallymeter/features/account/data/secure_store.dart';

/// An in-memory [SecureStore]. Not a mock: it is the real contract, backed by a
/// map, so every account test runs on the Dart VM with no platform channels.
class FakeSecureStore implements SecureStore {
  FakeSecureStore([Map<String, String>? seed])
      : _values = <String, String>{...?seed};

  final Map<String, String> _values;

  /// Every call made, in order. Lets a test assert that a value was written
  /// ONCE rather than rewritten on every read.
  final List<String> writes = <String>[];

  Map<String, String> get snapshot => Map<String, String>.unmodifiable(_values);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    writes.add(key);
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}
