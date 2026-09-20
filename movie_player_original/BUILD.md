# Build Anleitung (rekonstruiert)

## Setup
- Flutter SDK 3.16+ (Engine Revision 1527ae0ec577a4ef50e65f6fefcfc1326707d9bf aus flutter_bootstrap.js)
- Dart SDK >=3.2.0

## Key
lib/key.env enthält:
```
API-Schluessel: b5642418d08a64ce8c39c8f4e405157d
API-Token: eyJhbGciOiJIUzI1NiJ9...
```
Wird per rootBundle.loadString('lib/key.env') gelesen und via extractApiKey geparst (sucht nach "API-Schluessel:", "API-Schlüssel:", "TMDB_API_KEY=").

Alternativ via --dart-define:
```
flutter build apk --dart-define=TMDB_API_KEY=b5642418d08a64ce8c39c8f4e405157d
```

## Dependencies
Siehe pubspec.yaml - alle aus libapp.so extrahiert:
- flutter_riverpod für Provider
- http für TMDB API
- shared_preferences für selectedThemePreset (String) und dummyProgress (JSON Liste)
- package_info_plus für Version (liest version.json im Web)
- url_launcher für GitHub-Link
- webview_flutter + webview_flutter_android für Android Player
- webview_windows für Windows Player (ab 1.4)
- cached_network_image für Poster/Backdrop (https://image.tmdb.org/t/p/w500)

## Build Commands
```bash
flutter pub get

# Android APK (wie Movie_watcher-1.0.apk etc.)
flutter build apk --release

# Windows Portable (wie Movie_Watcher-1.4.exe - ist .NET Launcher mit embedded ZIP)
flutter build windows --release

# Web (wie app/ Ordner, base-href wichtig für GitHub Pages)
flutter build web --base-href /Movie_watcher/app/ --web-renderer canvaskit
```

Web Build Output entspricht app/:
- main.dart.js (2.7 MB)
- flutter.js, flutter_bootstrap.js (mit buildConfig engineRevision 1527ae0...)
- canvaskit/
- assets/lib/key.env
- player.html (eigene Datei, nicht Flutter Asset, aber per window.location.assign geöffnet)
- version.json, manifest.json, favicon.png, icons/

## Player Logik
Siehe lib/player.dart _buildHtml:
- iframe src = https://vidfast.vc/movie/{id}?autoPlay=true&title=true&poster=true&theme=16A085&startAt=&nextButton&autoNext
  bzw. /tv/{id}/{season}/{episode} für Serien
- allowedOrigins = 9 vidfast Domains (me, pro, in, vc, bz, pm, net, xyz, io) in Android 1.2, nur vc in Windows 1.4
- JS: isAllowedOrigin prüft hostname, leitet PLAYER_EVENT an PlaybackBridge.postMessage weiter
- Dart: _handleBridgeMessage liest watched (Hv: watched, current_time, currentTime, position) und duration (Hc: duration, total, totalDuration, runtime) und speichert via progressControllerProvider (dummyProgress)

## Themes
- Built-in: standard (Das aktuelle App-Theme, #16A085 primary), light (Hell, #0C8A6D), dark (Dunkel, #4CC9F0 etc.)
- Remote: 14 Dateien Theme1..14.json von https://raw.githubusercontent.com/Ferdi087/BElAppThemes/main/
- B.Hh Liste in main.dart.js: ["Theme1.json", ..., "Theme14.json"]
- Theme1.json Beispiel: {"name":"Neo Glass","primary":"#5EEBFF","secondary":"#7B61FF","background":"#0B0F19","card":"#151B2C","accent":"#FF4D8D"}

## Icons
- MaterialIcons subset tree-shaken: 9 in 1.0, 16 in 1.2
- Mapping: e092 arrow_back, e09d/e09e left/right, e16a close, e246 expand_more, e318 home filled, e33d info, e404 more_vert, e45a open_in_new, e4cb play_arrow, e4cd play_circle, e4f0 language, e567 search, e57f settings filled, f107 home outlined, f36e settings outlined

## Version History
- 1.0: Basis mit 9 Icons, nur Start Seite? (StreamingHomePage)
- 1.1: +6 Icons, SettingsPage mit Themes, GitHub-Link, Version, dummy.com Hinweis
- 1.2: +1 Icon open_in_new, ansonsten 1.1, kleine String-Fix
- 1.4 exe: Windows Player mit webview_windows, nur vidfast.vc erlaubt, neuer String "Player konnte nicht geladen werden"

## Original Pfad
D:/movie_player/movie_player/ (siehe libapp.so string file:///D:/movie_player/movie_player/.dart_tool/flutter_build/dart_plugin_registrant.dart)
