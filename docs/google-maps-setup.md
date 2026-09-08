# Google Maps setup

The app's maps are Google Maps. Everything is wired up except the API key,
which has to come from your own Google Cloud project.

**Until the key is set the app builds and runs, but every map is a blank
grey grid.** That is the expected symptom of a missing key — nothing else is
broken.

## 1. Create the key

1. Go to <https://console.cloud.google.com/> and select (or create) a
   project. The existing Firebase project `toda-equeue-app` is also a Google
   Cloud project, so you can reuse it.
2. **Attach a billing account** (Billing → Link a billing account). This
   needs a real card. See the cost note below before worrying about it.
3. Enable **Maps SDK for Android**: APIs & Services → Library → search for
   it → Enable.
4. APIs & Services → Credentials → Create credentials → API key.

## 2. Restrict the key

Do this before shipping. An unrestricted key can be lifted out of the APK
and used by anyone, on your billing account.

- **Application restriction** → Android apps. Add the package name
  `com.example.toda_equeue_plus` and your signing certificate's SHA-1.
  Get the debug SHA-1 with:

  ```
  keytool -list -v -keystore ~/.android/debug.keystore \
    -alias androiddebugkey -storepass android -keypass android
  ```

  Add the release keystore's SHA-1 too when you have one.
- **API restriction** → restrict the key to **Maps SDK for Android** only.

## 3. Add it to the project

Append the key to `android/local.properties`:

```
MAPS_API_KEY=AIza...your key...
```

That file is gitignored, so the key is never committed. Gradle reads it and
substitutes it into the manifest at build time. Rebuild after adding it —
Gradle only reads the file at configuration time.

To check it landed:

```
grep -A2 geo.API_KEY \
  build/app/intermediates/merged_manifest/debug/processDebugMainManifest/AndroidManifest.xml
```

The value should be your key, not an empty string.

Note that `local.properties` may not end in a newline. Append with a leading
newline, or the key gets concatenated onto the last line and silently
ignored.

## What this costs

Displaying a map in an Android app is free and unlimited — the "Mobile
Native Dynamic Maps" SKU is billed at zero, and it stayed that way after
Google's March 2025 pricing change that removed the old $200 monthly credit.
Google's live traffic layer is part of the same SDK and also costs nothing.

A billing account is still required to hold a key at all, which is why the
card is needed even though this usage does not bill.

What *does* cost money are the web JavaScript Maps SDK and the service APIs
— Directions, Places, Geocoding, Distance Matrix. **The app deliberately
uses none of them:**

- routing is OSRM (`router.project-osrm.org`)
- geocoding is Nominatim (OpenStreetMap)

Keep it that way, or set a billing budget alert, if you want the bill to
stay at zero. Restricting the key to Maps SDK for Android (step 2) also
means the key cannot be used against a billable API even if it leaks.

## Where the map code lives

- `lib/widgets/app_google_map.dart` — the shared map widget, the light and
  dark styles, and the LatLng conversions between `latlong2` (used by the
  domain models) and the plugin's own type.
- `lib/widgets/route_polyline.dart` — the OSRM route line.
- `lib/features/shared/reports/report_map_layer.dart` — TODA's crowd-sourced
  incident markers, drawn on top of Google's traffic.
