# Routing setup

The app routes with **OSRM** by default. That works, needs no key and costs
nothing — but it has two real limits, both confirmed against the live
service rather than assumed:

* It returns **exactly one route**. `alternatives=true` and `alternatives=3`
  both come back with a single route, so "another way" has to be produced by
  routing via an offset waypoint. Those are real roads, but chosen by
  geometry rather than by a router weighing options.
* It has **no traffic**. Its travel times are free-flow — what the road
  allows when clear, not what it is doing now.

Adding a **TomTom** key fixes both. It is optional; without it nothing
breaks and the app simply stays on OSRM.

## Getting a key

1. Sign up at <https://developer.tomtom.com> — **no credit card**.
2. The dashboard creates a default app with a key, or add one yourself.
3. Copy the key.

The free tier allows **2,500 routing requests a day**. Going over returns an
error rather than a bill, and the app falls back to OSRM when that happens.

For scale: the app recalculates at most every 45 seconds per active trip, so
one trip costs a few dozen requests at worst.

## Adding it to the project

Copy the template and paste the key in:

```
cp lib/config/api_keys.example.dart lib/config/api_keys.dart
```

```dart
static const String tomTom = 'your key here';
```

`lib/config/api_keys.dart` is gitignored, so the key is never committed. The
example file is committed as the template. Rebuild after adding it.

## What changes when the key is present

* **Real alternatives.** TomTom returns up to 5; the app asks for 2 and
  shows at most one, so the driver gets a recommendation and one option
  rather than a list.
* **Real traffic.** Travel times become measured rather than free-flow, and
  `trafficDelayInSeconds` says how much of the estimate is congestion.
* **The app stops double-counting.** Its own crowd-sourced *traffic* reports
  no longer add a penalty on a TomTom route, because that congestion is
  already in the number. Reported **incidents** — accidents, closures,
  flooding — still count, since a router knows a road is slow but not that
  there is a crash on it.
* Drivers' reports keep working exactly as before. They are the local
  knowledge TomTom does not have.

## Restrict the key before shipping

An unrestricted key in a released APK can be lifted out and used by anyone
against your quota. On the TomTom dashboard, restrict the key to the APIs it
actually needs (Routing) and, where offered, to your application.

## Verified against the live service

The parser was first written to TomTom's documented shape, then checked
against a real Baliwag response — which caught a genuine mistake.
`routeOffsetInMeters` is the distance from the **start of the route**, not
the length of one step. Read directly it would have told a driver to turn in
1851 m when the turn was 1851 m from where the trip began. Step distances
are now the gap between consecutive instructions, and the captured response
is committed as a test fixture so this cannot regress.

For the same Baliwag pair, OSRM returns one route and TomTom returns three.

**Expect longer ETAs.** TomTom is markedly more conservative: on one trip
OSRM gave 12 min over 7.7 km, about 38 km/h, while TomTom gave 26 min over
9.5 km, roughly 22 km/h. The second is far closer to what a tricycle
actually does on these roads, so estimates should now be more honest even
though they look worse.

**Traffic delay has not been seen non-zero yet.** Every route tested came
back with `trafficDelayInSeconds: 0`, which means no congestion was measured
at that moment rather than that the data is missing. Worth checking during a
busy hour before relying on it.

## If you ever want traffic tiles as well

This integration uses the Routing API only. TomTom also serves traffic flow
tiles that could colour the map directly, which would replace the app's own
congestion shading. That is separate work and is not wired up.
