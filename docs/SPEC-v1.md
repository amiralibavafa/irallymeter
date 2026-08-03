RALLY METER APPLICATION
PRODUCT VISION, FUNCTIONAL REQUIREMENTS, AND TECHNICAL NOTES

==================================================
1. OVERVIEW
==================================================

Rally Meter is a mobile application that transforms a smartphone into a rally navigation computer.

The purpose of Rally Meter is not to replace traditional navigation applications like Google Maps. The application is designed for precision driving, rally-style navigation, off-road driving, road trips, and situations where accurate distance, speed, timing, and route information are important.

A rally driver does not primarily need directions. They need accurate information about their current driving situation:

- How fast am I going?
- How far have I traveled?
- How far until the next point?
- What is my average speed?
- Where am I on the route?
- Am I following the planned timing?

The core philosophy of Rally Meter is:

Accuracy and reliability are more important than unnecessary features.

The user should trust the numbers displayed by the application.


==================================================
2. WHAT IS A RALLY METER?
==================================================

A rally meter is a specialized driving instrument commonly used in rally racing.

In normal racing, drivers compete on a closed track and focus mainly on speed.

In rally racing, drivers follow a route through roads, forests, mountains, gravel tracks, and other environments.

The driver and co-driver need to know exact distances because instructions are usually based on distance.

Examples:

"Turn left after 2.5 km"

"Checkpoint in 800 meters"

"Maintain an average speed of 75 km/h"

A difference of a few hundred meters can cause the driver to miss important points.

Traditional rally meters are dedicated hardware devices installed inside rally cars.

Examples of information displayed:

Current Speed:
85 km/h

Trip Distance:
23.420 km

Average Speed:
72 km/h

Heading:
NW

Timer:
01:25:30


Rally Meter aims to recreate this experience using a smartphone.


==================================================
3. WHY BUILD THIS APPLICATION?
==================================================

Modern smartphones already contain many components required for a rally computer:

- GPS receiver
- Accelerometer
- Gyroscope
- Magnetometer
- Powerful processor
- High-resolution display

This allows a phone to provide rally-style information without expensive dedicated hardware.

The application can be used for:

- Rally enthusiasts
- Amateur rally events
- Off-road drivers
- Mountain driving
- Road trips
- Navigation challenges
- Driving statistics


==================================================
4. CORE IDEA
==================================================

Rally Meter is a measurement system.

It is not just displaying information.

The application continuously collects data from sensors and transforms it into useful driving information.

The main data flow:

Sensors
|
|
GPS / Motion Data
|
|
Processing Engine
|
|
Distance, Speed, Time Calculations
|
|
Dashboard Display


The most important values are:

1. Current speed
2. Distance traveled
3. Average speed
4. Trip distance
5. Route position
6. Time information


==================================================
5. MAIN DASHBOARD
==================================================

The main driving screen should act like a professional rally instrument.

The driver should immediately understand the current situation.

Important information:

--------------------------------------------------

CURRENT SPEED

Example:

87 km/h

This represents the current vehicle speed.

--------------------------------------------------

TRIP DISTANCE

Example:

Trip 1:

24.530 km

Distance since the selected reset point.

--------------------------------------------------

AVERAGE SPEED

Example:

72.4 km/h

Used to understand driving pace.

--------------------------------------------------

COMPASS / HEADING

Example:

NW 315°

Shows direction of travel.

--------------------------------------------------

MAP VIEW

Shows:

- Current location
- Route traveled
- Waypoints
- Start point
- Progress


==================================================
6. DISTANCE CALCULATION
==================================================

Distance is the most important feature of Rally Meter.

GPS provides location updates.

Example:

Location A:

Latitude:
49.2827

Longitude:
-123.1207


After movement:

Location B:

Latitude:
49.2835

Longitude:
-123.1215


The application calculates the distance between these points.

The distance is continuously accumulated.

Example:

Movement 1:
50 meters

Movement 2:
120 meters

Movement 3:
80 meters


Total:

250 meters


The system must handle GPS inaccuracies.

A stationary vehicle should not accumulate distance because GPS position moves slightly due to signal noise.


==================================================
7. SPEED CALCULATION
==================================================

Speed is calculated mainly from GPS data.

Example:

The vehicle moves 100 meters in 5 seconds.

The application calculates:

72 km/h


Speed values should be smoothed.

Raw GPS:

70 km/h
95 km/h
40 km/h
85 km/h


Smoothed output:

70 km/h
74 km/h
76 km/h
78 km/h


The goal is a stable and realistic driving display.


==================================================
8. AVERAGE SPEED
==================================================

Average speed is calculated using:

Average Speed = Total Distance / Total Driving Time


Example:

Distance:

200 km


Driving time:

4 hours


Average speed:

50 km/h


The system must correctly handle:

- Stops
- Breaks
- Traffic
- Slow movement
- GPS interruptions


Average speed is important in rally situations because drivers often need to maintain a target pace.


==================================================
9. TRIP 1 AND TRIP 2 SYSTEM
==================================================

Professional rally meters commonly contain multiple trip counters.

Rally Meter includes Trip 1 and Trip 2 because drivers need different distance references.


--------------------------------------------------
TRIP 1
--------------------------------------------------

Trip 1 is the main distance counter.

It represents:

"How far have I traveled since the beginning of this stage/trip?"

Example:

A rally stage starts.

The driver resets Trip 1.

Trip 1:

0.000 km


After driving:

Trip 1:

35.450 km


Meaning:

The vehicle has traveled 35.450 km since the start.


Common uses:

- Full rally stage distance
- Total trip distance
- Main navigation reference


--------------------------------------------------
TRIP 2
--------------------------------------------------

Trip 2 is an independent secondary distance counter.

It represents:

"How far have I traveled since my last important point?"


Example:

Trip 1:

52.300 km


The driver reaches a checkpoint.

They reset Trip 2.


Now:

Trip 1:

52.300 km

Trip 2:

0.000 km


After driving:

Trip 1:

55.300 km

Trip 2:

3.000 km


The driver knows they have traveled 3 km since the checkpoint.


Example instruction:

"After checkpoint, turn after 3 km."


Trip 2 allows the driver to measure that specific section while keeping Trip 1 running.


==================================================
10. MAP SYSTEM
==================================================

The map is not designed to replace navigation applications.

The map is used as a visualization and tracking tool.

The map should display:

- Current vehicle location
- Driven path
- Starting point
- Waypoints
- Checkpoints
- Route progress


Example rally route:


START

|

5 km

|

Checkpoint 1

|

10 km

|

Checkpoint 2

|

FINISH


The driver can visually understand where they are on the route.


Possible future map features:

- Import GPX routes
- Create stages
- Add checkpoints
- Display elevation
- Show completed distance percentage


==================================================
11. GPS LIMITATIONS
==================================================

GPS is powerful but has limitations.

Problems include:

- Tunnels
- Underground parking
- Dense forests
- Tall buildings
- Poor satellite visibility


A professional rally system cannot simply stop when GPS disappears.


==================================================
12. TUNNEL MODE
==================================================

Tunnel Mode allows Rally Meter to continue functioning when GPS becomes unavailable.

When GPS becomes unreliable:

The application switches from:

GPS Tracking Mode

to:

Tunnel Mode


Tunnel Mode continues estimating:

- Distance
- Speed
- Average speed


The system should detect:

- Poor GPS accuracy
- Missing location updates
- Signal loss


==================================================
13. TUNNEL DISTANCE EXAMPLE
==================================================

Vehicle enters tunnel:


Distance:

12.430 km

Time:

10:30:00


GPS becomes unavailable.


Vehicle exits tunnel:


Distance estimate:

14.020 km

Time:

10:31:40


Calculation:

Tunnel distance:

1.590 km


Tunnel duration:

100 seconds


Average tunnel speed:

57.2 km/h


==================================================
14. SENSOR ESTIMATION
==================================================

During GPS loss, the application can use phone sensors:

- Accelerometer
- Gyroscope
- Device motion


However, phone sensors are not perfect.

They can drift over time.

Therefore:

GPS should always be the primary source.

Sensor estimation should only be a fallback.


Priority:

1. GPS
2. External vehicle data (future)
3. Sensor estimation
4. Manual correction


==================================================
15. MANUAL TUNNEL MARKERS
==================================================

Users can manually mark tunnel sections.

Buttons:

Tunnel Start

Tunnel End


Example:

Driver enters tunnel.

Press:

Tunnel Start


The application saves:

- Timestamp
- Current distance
- Current GPS location


Driver exits tunnel.

Press:

Tunnel End


The application calculates:

- Tunnel length
- Tunnel duration
- Average speed


This gives the user accurate control when automatic detection is not enough.


==================================================
16. GPS RECOVERY
==================================================

When GPS returns after a tunnel:

The application should not suddenly jump.

Example:

Estimated distance:

15.200 km


GPS distance:

15.350 km


Difference:

150 meters


The system should smoothly correct the value over several seconds.

The driver should not see:

15.200 km

then instantly:

15.350 km


The correction should be invisible.


==================================================
17. SOFTWARE ARCHITECTURE DIRECTION
==================================================

The application should separate responsibilities.


Example architecture:


Presentation Layer

(User Interface)

        |

Business Logic

        |

Distance Engine

        |

--------------------------------

GPS Provider

Sensor Provider

Manual Provider

Map Provider

Storage System


The UI should not directly calculate distances.

The calculation engine should be independent.


==================================================
18. CROSS PLATFORM REQUIREMENTS
==================================================

Rally Meter supports:

- Android
- iOS


The implementation should avoid platform-specific solutions whenever possible.

Features should work consistently across both platforms.

Flutter architecture should be used with shared business logic.


==================================================
19. TESTING REQUIREMENTS
==================================================

Before release, the application must be tested for:


GPS:

- Normal driving
- GPS loss
- GPS recovery


Distance:

- Accurate calculations
- GPS noise handling
- Long trips


Trip System:

- Trip 1 reset
- Trip 2 reset
- Independent operation


Tunnel System:

- Automatic tunnel detection
- Manual tunnel markers
- Sensor estimation
- GPS recovery


Application:

- Background mode
- Permissions
- Android compatibility
- iOS compatibility


==================================================
20. FUTURE DEVELOPMENT POSSIBILITIES
==================================================

Possible future improvements:


External GPS:

Bluetooth high-frequency GPS receivers.


OBD-II Integration:

Read vehicle data:

- Speed
- RPM
- Engine information


Advanced Rally Features:

- Stage creation
- GPX import
- Checkpoints
- Waypoints
- Timing challenges


Driver / Co-driver Mode:

Separate interfaces for driver and navigator.


Cloud Features:

- Save trips
- Share routes
- Analyze driving history


==================================================
21. FINAL PRODUCT VISION
==================================================

Rally Meter should become a professional-quality rally computer available on a smartphone.

The goal is not to create another navigation app.

The goal is to create a trusted measurement instrument.

Every number displayed should have meaning.

Every feature should help the driver answer:

"Where am I, how far have I gone, how fast am I going, and what happens next?"


The foundation of Rally Meter is:

Accuracy.

Reliability.

Simplicity.

A professional rally experience inside a smartphone.
