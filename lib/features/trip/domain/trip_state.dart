/// Trip computer values. All distances stored in metres (calibrated).
class TripState {
  const TripState({
    required this.tripA,
    required this.tripB,
    required this.odometer,
  });

  final double tripA;
  final double tripB;
  final double odometer;

  TripState copyWith({double? tripA, double? tripB, double? odometer}) {
    return TripState(
      tripA: tripA ?? this.tripA,
      tripB: tripB ?? this.tripB,
      odometer: odometer ?? this.odometer,
    );
  }

  static const TripState zero = TripState(tripA: 0, tripB: 0, odometer: 0);
}

/// Identifies which counter a control acts on.
enum TripCounter { a, b }
