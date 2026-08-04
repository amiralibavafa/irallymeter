import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the app is being fed a simulated drive instead of the receiver
/// (SPEC-v2 §20.1's debug-menu option).
///
/// Hard-wired to `false` outside debug builds. This swaps the GPS and motion
/// repositories under the whole app, so it must be impossible to reach in a
/// release build — a rally computer that can be talked into inventing its own
/// position is not a rally computer. `kDebugMode` is a const, so the release
/// compiler drops the simulated sources entirely rather than merely hiding the
/// switch.
final simulationEnabledProvider = StateProvider<bool>((ref) => false);

/// Read this rather than the raw provider at any decision point.
bool simulationActive(WidgetRef ref) =>
    kDebugMode && ref.watch(simulationEnabledProvider);

bool simulationActiveRef(Ref ref) =>
    kDebugMode && ref.watch(simulationEnabledProvider);
