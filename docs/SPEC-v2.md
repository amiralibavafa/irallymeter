**RALLY METER APPLICATION**

Product Vision, Functional Requirements, and Technical Notes

**Revision 2**

# CHANGE LOG — REVISION 2

Changes applied in this revision:

- Section 5 — dashboard now shows an explicit indicator when values are
  estimated rather than measured.

- Section 6 — added concrete noise-gating rules so a parked vehicle
  cannot accumulate distance.

- Section 7 — rewritten. Speed is now read from the GNSS Doppler speed
  field, not derived from position changes.

- Sections 12–14 — rewritten. GPS-loss estimation now uses speed-hold
  dead reckoning. The accelerometer is used only to correct speed, never
  to compute displacement directly.

- Section 15 — replaced. Manual "Tunnel Start" and "Tunnel End" buttons
  are removed. Detection is fully automatic.

- Section 16 — updated. The correction is invisible, but the estimated
  state itself is visible.

- Section 18 — rewritten as a Flutter/Dart-only implementation strategy
  with no custom native code.

- Section 19 — new. Measurable accuracy targets.

- Section 20 — updated. Testing now verifies against the targets in
  Section 19.

**Deliberately deferred to a later revision:**

- User calibration factor (see note in Section 19).

- Timing and regularity features (the timing question in Section 1 is
  not yet answered by any feature).

- Crash and restart state persistence.

# 1. OVERVIEW

Rally Meter is a mobile application that transforms a smartphone into a
rally navigation computer.

The purpose of Rally Meter is not to replace traditional navigation
applications like Google Maps. The application is designed for precision
driving, rally-style navigation, off-road driving, road trips, and
situations where accurate distance, speed, timing, and route information
are important.

A rally driver does not primarily need directions. They need accurate
information about their current driving situation:

- How fast am I going?

- How far have I traveled?

- How far until the next point?

- What is my average speed?

- Where am I on the route?

The core philosophy of Rally Meter is:

**Accuracy and reliability are more important than unnecessary features.
The user should trust the numbers displayed by the application.**

From Revision 2 onward, "accuracy" is a measurable requirement, not a
statement of intent. See Section 19.

# 2. WHAT IS A RALLY METER?

A rally meter is a specialized driving instrument commonly used in rally
racing.

In normal racing, drivers compete on a closed track and focus mainly on
speed. In rally racing, drivers follow a route through roads, forests,
mountains, gravel tracks, and other environments.

The driver and co-driver need to know exact distances because
instructions are usually based on distance. For example: "Turn left
after 2.5 km", "Checkpoint in 800 meters", "Maintain an average speed of
75 km/h".

A difference of a few hundred meters can cause the driver to miss
important points.

Traditional rally meters are dedicated hardware devices installed inside
rally cars. Rally Meter aims to recreate this experience using a
smartphone.

# 3. WHY BUILD THIS APPLICATION?

Modern smartphones already contain most of the components required for a
rally computer: a GNSS receiver, accelerometer, gyroscope, magnetometer,
a powerful processor, and a high-resolution display.

This allows a phone to provide rally-style information without expensive
dedicated hardware.

Target users: rally enthusiasts, amateur rally events, off-road drivers,
mountain driving, road trips, navigation challenges, and drivers who
want detailed driving statistics.

# 4. CORE IDEA

Rally Meter is a measurement system. It is not just displaying
information. The application continuously collects data from sensors and
transforms it into useful driving information.

Main data flow:

Sensors (GNSS / Motion)

\|

Processing Engine

\|

Distance, Speed, Time Calculations

\|

Dashboard Display

The most important values are current speed, distance traveled, average
speed, trip distance, route position, and time information.

# 5. MAIN DASHBOARD \[UPDATED\]

The main driving screen should act like a professional rally instrument.
The driver should immediately understand the current situation.

**Primary values:**

- CURRENT SPEED — e.g. 87 km/h

- TRIP 1 — e.g. 24.530 km, distance since the selected reset point

- TRIP 2 — independent secondary counter

- AVERAGE SPEED — e.g. 72.4 km/h

- COMPASS / HEADING — e.g. NW 315°

- MAP VIEW — current location, path traveled, waypoints, start point,
  progress

## 5.1 Measurement State Indicator (new requirement)

The dashboard must always show whether the numbers are measured or
estimated. This is a direct consequence of the core philosophy: an
instrument that hides when it is guessing cannot be trusted.

- MEASURED — normal digit colour. GNSS is valid and accurate.

- ESTIMATED — digits shown in amber, with an "EST" badge next to the
  affected values. Used whenever the application is in Estimation Mode
  (Section 12).

- RECONCILING — a brief "SYNC" indicator while a recovery correction is
  being applied (Section 16).

- LOW CONFIDENCE — after a long period without GNSS, the estimated
  values are additionally marked as unreliable (see Section 12.3).

**Only the correction itself is hidden from the user. The fact that the
application is estimating is never hidden.**

# 6. DISTANCE CALCULATION \[UPDATED\]

Distance is the most important feature of Rally Meter.

The GNSS receiver provides location updates. The application calculates
the distance between consecutive valid positions and accumulates the
result.

Example: 50 m + 120 m + 80 m = 250 m total.

## 6.1 Noise gating rules

A stationary vehicle must never accumulate distance, because GPS
position drifts slightly even when parked. The following rules apply
before any displacement is added:

- Reject the fix entirely if reported horizontal accuracy is worse than
  30 m.

- Ignore the displacement if the current valid speed is below 1.5 m/s
  (about 5.4 km/h).

- Ignore the displacement if it is smaller than the horizontal accuracy
  of the fix — the movement cannot be distinguished from noise.

- Reject a fix that implies a speed inconsistent with the previous
  reading (for example a jump of more than three times the expected
  displacement).

Target: zero accumulated distance over 10 minutes parked (Section 19).

# 7. SPEED CALCULATION \[REWRITTEN\]

**Speed is read directly from the GNSS receiver. It is not calculated by
dividing distance by time.**

Both Android and iOS expose a speed value derived from the Doppler shift
of the satellite signal. This value is measured independently of
position and is significantly more accurate than differentiating
consecutive positions, especially at low update rates.

In Flutter this is available on the location stream as Position.speed
(metres per second), together with Position.speedAccuracy.

## 7.1 Source rules

- Primary source: Position.speed from the location stream.

- Treat the value as invalid if it is negative, null, or if
  speedAccuracy is worse than 2 m/s.

- Fallback, only when invalid: derive speed from consecutive positions
  as originally described.

- Below 1.5 m/s, display 0 km/h so that noise is never shown as
  movement.

## 7.2 Smoothing

Raw values are used for calculation. Smoothing is applied to the display
only, using a light exponential moving average.

Raw GNSS: 70, 95, 40, 85 km/h

Smoothed display: 70, 74, 76, 78 km/h

Smoothing must not add more than approximately 1 second of latency. The
goal is a stable display, not a slow one.

# 8. AVERAGE SPEED

Average Speed = Total Distance / Total Driving Time.

Example: 200 km over 4 hours gives 50 km/h.

The system must correctly handle stops, breaks, traffic, slow movement,
and GNSS interruptions. The application should track both moving average
(excluding stops) and overall average (including stops), and make clear
which one is displayed.

Average speed is important in rally situations because drivers often
need to maintain a target pace.

# 9. TRIP 1 AND TRIP 2 SYSTEM

Professional rally meters commonly contain multiple trip counters. Rally
Meter includes Trip 1 and Trip 2 because drivers need different distance
references.

## Trip 1

The main distance counter: "How far have I traveled since the beginning
of this stage or trip?"

The driver resets Trip 1 at the start of a stage. After driving, Trip 1
might read 35.450 km, meaning the vehicle has traveled that distance
since the start.

## Trip 2

An independent secondary counter: "How far have I traveled since my last
important point?"

Example: Trip 1 reads 52.300 km when the driver reaches a checkpoint and
resets Trip 2. After driving further, Trip 1 reads 55.300 km and Trip 2
reads 3.000 km.

This allows the driver to measure a specific section — "after the
checkpoint, turn after 3 km" — while Trip 1 keeps running.

# 10. MAP SYSTEM

The map is not designed to replace navigation applications. It is a
visualization and tracking tool.

The map should display current vehicle location, driven path, starting
point, waypoints, checkpoints, and route progress.

Possible future map features: GPX route import, stage creation,
checkpoint editing, elevation display, and completed distance
percentage.

# 11. GNSS LIMITATIONS

GNSS is powerful but has limitations. Signal is degraded or lost in
tunnels, underground parking, dense forests, urban canyons between tall
buildings, and anywhere satellite visibility is poor.

A professional rally system cannot simply stop measuring when GNSS
disappears.

# 12. ESTIMATION MODE (TUNNEL MODE) \[REWRITTEN\]

When GNSS becomes unavailable or unreliable, the application enters
Estimation Mode and continues to estimate distance, speed, and average
speed.

## 12.1 Method: speed-hold dead reckoning

**The previous revision proposed estimating distance by integrating the
accelerometer. This does not work in practice and has been replaced.**

Why it does not work: obtaining displacement from an accelerometer
requires integrating twice, so error grows roughly with the square of
elapsed time. The phone sits at an unknown angle, and any error in
estimating that angle leaks gravity into the horizontal axis. A tilt
estimation error of only 0.5° produces about 0.086 m/s² of false
acceleration, which becomes roughly 43 metres of error over 100 seconds
— the exact duration of a typical tunnel.

**The method used instead:**

- When GNSS is lost, freeze the last valid speed value v₀.

- Accumulate distance as v₀ × Δt on every tick.

- Hold the last known heading; the gyroscope may be used to track
  heading changes, which is what it is actually good for.

This works because the situations that cause GNSS loss — tunnels,
underpasses, covered sections — are typically straight, and drivers hold
a steady speed through them.

## 12.2 Optional refinement: accelerometer as a speed correction

The accelerometer may be used, but only to adjust the held speed — never
to compute displacement directly. Integrating acceleration once to
correct speed produces error that grows linearly rather than
quadratically, and the result can be clamped to a safe range.

- Estimate the gravity vector with a low-pass filter and isolate the
  longitudinal (forward) axis.

- Integrate longitudinal acceleration over short windows to adjust v.

- Clamp the total adjustment to ±25% of v₀. If the correction wants to
  exceed this, ignore it and hold v₀.

- Disable the refinement entirely if device orientation is unstable —
  for example if the phone is being handled.

## 12.3 Confidence decay

- 0–60 seconds without GNSS: estimated, normal confidence.

- 60–180 seconds: estimated, reduced confidence — indicator becomes more
  prominent.

- Over 180 seconds: low confidence. The display warns that the distance
  may be significantly wrong.

# 13. ESTIMATION EXAMPLE \[REWRITTEN\]

Vehicle approaches a tunnel:

Trip 1 12.430 km

Last valid speed 85 km/h (23.61 m/s)

Time 10:30:00

GNSS is lost. The application holds 85 km/h and accumulates distance
from it.

Vehicle exits the tunnel 100 seconds later:

Estimated distance 23.61 m/s × 100 s = 2.361 km

Trip 1 (estimated) 14.791 km

Time 10:31:40

GNSS returns and reports the true position, giving an actual Trip 1 of
14.735 km.

Difference 56 m (2.4% of the estimated section)

The 56 m difference is then corrected smoothly, as described in Section
16. The estimated section is logged automatically in the trip history.

# 14. SENSOR USE AND SOURCE PRIORITY \[REWRITTEN\]

Data source priority, highest first:

- 1\. GNSS — always the primary source whenever it is valid.

- 2\. External vehicle data — OBD-II or an external Bluetooth GNSS
  receiver. Future capability.

- 3\. Speed-hold estimation, optionally refined by the accelerometer as
  described in Section 12.

**Manual correction has been removed from the priority list. All
estimation is automatic (see Section 15).**

Phone sensors drift over time and are never treated as an authoritative
source. They exist to make a GNSS gap survivable, not to replace GNSS.

# 15. AUTOMATIC GNSS LOSS DETECTION \[REPLACES MANUAL MARKERS\]

**The manual "Tunnel Start" and "Tunnel End" buttons are removed.
Requiring the driver or co-driver to press a button at the moment they
enter a tunnel is unrealistic in a moving car, and the resulting
measurement would depend on human reaction time. Detection is fully
automatic.**

## 15.1 Entering Estimation Mode

Enter Estimation Mode when any of the following is true:

- No location update received for more than 3 seconds, where updates are
  expected at 1 Hz.

- Reported horizontal accuracy is worse than 50 m.

- The speed field is invalid and accuracy is degrading across
  consecutive fixes.

- A position jump occurs that is inconsistent with the last known speed
  — more than three times the expected displacement.

## 15.2 Exiting Estimation Mode

Exit only when GNSS is genuinely reliable again:

- Three consecutive fixes with horizontal accuracy of 20 m or better.

- Those fixes are mutually consistent — each implies a plausible speed
  relative to the previous one.

Entry and exit must be debounced so the display does not flicker between
modes at the edge of coverage.

## 15.3 Automatic logging

Every estimated section is recorded automatically without user action:

- Start time, end time, and duration

- Estimated distance and the speed that was held

- The correction applied on recovery

This gives the user the same information the manual buttons would have
provided, but measured rather than hand-triggered, and it gives us the
data needed to tune the thresholds during testing.

# 16. GNSS RECOVERY AND CORRECTION \[UPDATED\]

Two separate principles apply here, and they must not be confused.

## 16.1 The correction is invisible

When GNSS returns, the displayed distance must not jump. The difference
between the estimated value and the true value is blended in gradually.

- Spread the correction linearly over 15 seconds.

- If the difference exceeds 200 m, spread it over 60 seconds instead and
  flag the event in the trip log.

- The trip counters must never move backwards, even if the estimate
  overshot. Slow the accumulation rate instead until the true value
  catches up.

The driver should never see 14.791 km change instantly to 14.735 km.

## 16.2 The estimated state is visible

While the application is estimating, this is shown clearly on the
dashboard (Section 5.1). Estimated numbers are not the same as measured
numbers, and presenting them identically would undermine the trust the
whole product depends on.

**Hide the correction. Never hide the estimation.**

# 17. SOFTWARE ARCHITECTURE DIRECTION

The application separates responsibilities into layers:

Presentation Layer (UI)

\|

Business Logic

\|

Distance Engine

\|

----------------------------------

GNSS Provider Sensor Provider

Map Provider Storage System

The UI must never calculate distances. The calculation engine is
independent.

**Additional requirement: the Distance Engine is written in pure Dart
with no plugin imports and no platform dependencies. It receives plain
data objects and returns plain data objects. This allows the entire
engine to run inside unit tests against recorded drive data, which is
how the accuracy targets in Section 19 will be verified without
repeating a road test for every code change.**

# 18. FLUTTER AND DART IMPLEMENTATION STRATEGY \[REWRITTEN\]

**Decision: all application code is written in Dart. No custom Kotlin or
Swift is written for this project.**

The previous revision asked to avoid platform-specific solutions while
also requiring reliable background operation, which appeared
contradictory. It is not, provided the platform differences are handled
through configuration and maintained plugins rather than custom native
code.

## 18.1 Plugins

- geolocator — location stream on both platforms, including the speed
  and accuracy fields required by Section 7.

- sensors_plus — accelerometer and gyroscope access for the Section 12.2
  refinement.

- wakelock_plus — keeps the screen awake while a trip is running.

- A mapping plugin for Section 10, selected separately.

## 18.2 Platform settings, expressed in Dart

Android (AndroidSettings):

- foregroundNotificationConfig — this is what creates the Android
  foreground service and keeps location running when the app is not in
  front. It is configured in Dart.

- intervalDuration of 1 second, high accuracy.

- Evaluate fused location versus the raw location manager during
  testing. Fused location applies its own smoothing and road snapping,
  which is helpful for navigation and wrong for measurement.

iOS (AppleSettings):

- activityType: ActivityType.automotiveNavigation

- accuracy: LocationAccuracy.bestForNavigation

- allowBackgroundLocationUpdates: true

- pauseLocationUpdatesAutomatically: false — otherwise iOS will pause
  updates when it thinks the vehicle has stopped.

- showBackgroundLocationIndicator: true

## 18.3 Configuration files (not code)

iOS Info.plist:

- NSLocationWhenInUseUsageDescription

- NSLocationAlwaysAndWhenInUseUsageDescription

- UIBackgroundModes including location

Android Manifest:

- ACCESS_FINE_LOCATION, ACCESS_COARSE_LOCATION

- FOREGROUND_SERVICE, and FOREGROUND_SERVICE_LOCATION on Android 14 and
  above

- WAKE_LOCK

## 18.4 The one remaining platform issue

Some Android manufacturers aggressively terminate background services
regardless of correct implementation. This cannot be solved in code on
any platform or framework. It is handled by prompting the user once,
inside the app, to exclude Rally Meter from battery optimisation — a
user action, not native code.

This is a known limitation to test explicitly on multiple devices, not a
reason to leave Dart.

# 19. ACCURACY TARGETS \[NEW\]

The product philosophy states that accuracy is the foundation. These are
the numbers that define it. A build that does not meet these targets is
not ready for release.

|  |  |  |
|----|----|----|
| **Measurement** | **Condition** | **Target** |
| Trip distance | Good reception, 50 km mixed roads | Error ≤ 1.0% |
| Trip distance | Vehicle parked for 10 minutes | 0.000 km accumulated |
| Displayed speed | Above 20 km/h, good reception | ±2 km/h, latency ≤ 1.0 s |
| Distance in Estimation Mode | 2 km GPS-free section at roughly steady speed | Error ≤ 3% |
| Recovery correction | Any reconciliation event | No visible jump, complete ≤ 15 s |
| Location update rate | Foreground and background | ≥ 1 Hz sustained |

**Note on curved roads:**

At a 1 Hz update rate, the application measures straight lines between
fixes. On tight mountain or gravel roads these straight lines cut across
curves, so measured distance will read slightly short. If road testing
shows this pushes the error beyond 1%, a user-adjustable calibration
factor should be added — this is the standard solution used by hardware
rally computers and is deferred from this revision rather than rejected.

# 20. TESTING REQUIREMENTS \[UPDATED\]

## 20.1 Method: record and replay

During real drives, log the raw location and sensor stream to a file.
These recordings are then replayed against the Distance Engine inside
unit tests.

This means noise gating, smoothing, loss detection thresholds, and
estimation logic can all be tuned and regression-tested without driving
the route again. It is the single highest-value piece of test
infrastructure in the project and should be built early.

## 20.2 Ground truth

- A measured route using highway distance markers, or a surveyed GPX
  track, to validate absolute distance error.

- At least one route with tunnels or covered sections for estimation
  testing.

- At least one tight, curved road to measure the chord-shortening effect
  described in Section 19.

## 20.3 Test list

GNSS:

- Normal driving, signal loss, signal recovery

- Speed field validity and fallback behaviour

Distance:

- Accuracy against the Section 19 targets

- Noise gating — 10 minutes parked accumulates zero distance

- Long trips without drift accumulation

Trip system:

- Trip 1 reset, Trip 2 reset, independent operation

Estimation Mode:

- Automatic entry thresholds — does it trigger when it should?

- Automatic exit thresholds — does it avoid flickering at the edge of
  coverage?

- Speed-hold accuracy over 2 km GPS-free sections

- Recovery correction produces no visible jump

- Estimated state indicator appears and clears correctly

- Automatic section logging

Application:

- Background operation on both platforms, screen off, over a long drive

- Android background survival with battery optimisation both enabled and
  disabled

- iOS background location without automatic pausing

- Permissions flow on both platforms

# 21. FUTURE DEVELOPMENT POSSIBILITIES

- External GNSS — high-frequency Bluetooth receivers, which would raise
  the update rate well above 1 Hz and remove most of the accuracy limits
  in Section 19.

- OBD-II integration — vehicle speed, RPM, and engine information.
  Vehicle speed from the wheels is the most accurate distance source
  available and would largely solve the tunnel problem.

- User calibration factor (deferred from this revision).

- Timing and regularity features — target times, time-vs-actual, and
  pace tracking.

- Advanced rally features — stage creation, GPX import, checkpoints,
  waypoints.

- Driver and co-driver mode — separate interfaces.

- Cloud features — saved trips, shared routes, driving history analysis.

# 22. FINAL PRODUCT VISION

Rally Meter should become a professional-quality rally computer
available on a smartphone.

The goal is not to create another navigation app. The goal is to create
a trusted measurement instrument.

Every number displayed should have meaning. Every feature should help
the driver answer: "Where am I, how far have I gone, how fast am I
going, and what happens next?"

**The foundation of Rally Meter is accuracy, reliability, and simplicity
— a professional rally experience inside a smartphone.**
