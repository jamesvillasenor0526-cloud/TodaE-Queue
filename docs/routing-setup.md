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

## Not yet verified

The parser was written to TomTom's documented response shape and is tested
against fixtures built from it, but no live call has been made — that needs
a key. The first real route is worth watching: check that a route comes back
at all, that the ETA moves with traffic, and that alternatives appear.

## If you ever want traffic tiles as well

This integration uses the Routing API only. TomTom also serves traffic flow
tiles that could colour the map directly, which would replace the app's own
congestion shading. That is separate work and is not wired up.
