# Rekonstruktion - Movie Watcher

## Quellen
- Web-Build: app/main.dart.js (2.7 MB), app/player.html, app/version.json, app/manifest.json, app/flutter_bootstrap.js
- Native: Movie_watcher-1.0.apk, Movie_Watcher-1.1.apk, Movie_Watcher-1.2.apk, Movie_Watcher-1.4.exe (enthält data/app.so + flutter_assets)

## Erkenntnisse

### Paket
- package: movie_player
- main.dart und player.dart als einzige Dart-Files (siehe strings in libapp.so: package:movie_player/main.dart, package:movie_player/player.dart)
- Pfad: file:///D:/movie_player/movie_player/.dart_tool/flutter_build/dart_plugin_registrant.dart -> Original lag auf D:/movie_player/movie_player
- Android package: com.example.movie_player
- Version: 1.0.0+1, versionCode 1, compileSdk 36, minSdk 24, targetSdk 36

### Dependencies (aus libapp.so package: prefix)
- flutter, cupertino_icons, http, shared_preferences, package_info_plus, path_provider, url_launcher, webview_flutter, webview_flutter_android, webview_windows, cached_network_image, flutter_cache_manager, flutter_riverpod, state_notifier, characters, collection, ffi, file, path, rxdart, uuid, octo_image, clock, synchronized, etc.

### Models (aus Symbolen @609478119 etc.)
- MediaKind enum (movie, series) -> B.dw, B.b_
- PlaybackTarget (uK): kind, id, season?, episode?, watched
  - aGl(a,b,c,d,e) = movie target
  - Bw() = series target mit season/episode
- WatchProgressRecord (dO): id, type, title, poster_path, backdrop_path, watched, duration, last_season_watched, last_episode_watched, last_updated
  - gBe() = progressPercent
  - gzt() = S02 · E05 Label
  - kP() = toJson
  - aVJ = fromJson
- TmdbMedia (ec): id, title, year, voteAverage, posterPath, backdropPath, kind
  - aVd = fromJson (media_type -> tv ? series : movie)
  - tmdbImageUrl = aC9 = https://image.tmdb.org/t/p/w500 + path
- ThemePreset (dM): id, name, description, brightness, primary, secondary, background, card, accent
  - a0l = parseHexColor
  - aYX = resolveThemePreset
- EpisodeOverviewData (px): episode_number, name, overview, air_date, still_path -> aQA fromJson
- SeasonOverviewData (iC): season_number, name, episodes -> a7c? actually constructor
- SeriesOverviewData (jz): name, overview, first_air_date, voteAverage, poster, backdrop, seasons -> aUa fromJson

### Providers (init:*)
- packageInfoProvider
- tmdbApiKeyProvider: liest lib/key.env via rootBundle, extractApiKey sucht nach API-Schluessel: / API-Schlüssel: / TMDB_API_KEY=
- trendingTrailersProvider: GET https://api.themoviedb.org/3/trending/movie/week?api_key=&language=de-DE
- tmdbSearchResultsProvider (Family<String>): GET /3/search/multi?api_key=&language=de-DE&query=&include_adult=false, filtert media_type != person
- seriesOverviewProvider (Family<int>): GET /3/tv/{id}?api_key=&language=de-DE, dann für jede season GET /3/tv/{id}/season/{n}?api_key=&language=de-DE
- remoteThemesProvider: hardcoded Liste B.Hh = 14 ThemeX.json, fetch von https://raw.githubusercontent.com/Ferdi087/BElAppThemes/main/{file}
- appThemeControllerProvider: StateNotifier<String> selectedThemePreset, SharedPreferences key selectedThemePreset, default standard
- progressControllerProvider: StateNotifier<List<WatchProgressRecord>> key dummyProgress, speichert JSON, Methoden filterPopular, filterRecent, addOrUpdate, addPlayback

### UI Strings (B.* Konstanten)
- B.Um: TMDB_API_KEY ist noch nicht gesetzt. Hinterlege den Key sicher per --dart-define, damit die Trending-Filme live geladen werden.
- B.Un: Alle Medien stammen aus fastvid.vc. (in 1.1+ aus dummy.com. als Platzhalter, aber web zeigt fastvid.vc)
- B.Uo: Version wird geladen...
- B.Uq: GitHub-Link öffnen
- B.Ur: Version: unbekannt
- B.Us: Direkt öffnen
- B.Ut: Filme/serien ansehen
- B.Uu: Hinweis zu Medienquellen
- B.Uj: Episode fortsetzen
- B.Uk: Ferdinand aus Deutschland
- B.Wi: Keine Treffer / Versuche einen anderen Titel oder kürze die Suche.
- B.Wj: TMDB API-Key fehlt / Die Trending-Liste wird geladen, sobald der Key in lib/key.env oder per --dart-define vorhanden ist.
- B.Wk: Noch kein Verlauf gespeichert / Sobald ein Player-Event Daten liefert, erscheint der Verlauf hier. (in bearbeitung)
- B.Wl: Keine Filme/serien gefunden / Versuche es später erneut.
- Streaming Frontend
- Suche, setze die Wiedergabe fort und öffne Filme/serien direkt im Player.
- Titel filtern ...
- Standard, Hell, Dunkel und die Theme-Dateien aus dem BElAppThemes-Repository.
- Externe Themes werden geladen...
- Externe Themes konnten nicht geladen werden: 
- {n} externe Themes aus BElAppThemes verfügbar.
- Themes
- Einstellungen
- Start / Settings (BottomNavigation)
- Beliebte Filme/serien
- Suchergebnisse / TMDB-Multi-Suche für Filme und Serien.
- Zuletzt gesehen / Fortsetzen aus deinem lokalen Fortschritt.
- Neue Episoden / Serienfortschritt mit S- und E-Labels zum direkten Fortsetzen.
- Weitersehen / % Fortschritt / % 
- Keine Beschreibung vorhanden.
- Staffel 
- Episoden
- Episoden: "{n} Episoden"
- Version {version}+{build}
- Serien-Details konnten nicht geladen werden.
- TMDB-Suche konnte nicht geladen werden.
- TMDB-Trending konnte nicht geladen werden.
- Aktuelle Trending-Filme/serien von TMDB.
- Lege den Key in lib/key.env ab oder setze TMDB_API_KEY via --dart-define.

### Icons (MaterialIcons subset)
- Aus f10.otf (1.0): 9 Icons: e092 arrow_back, e09d arrow_left, e09e arrow_right, e16a close, e246 expand_more, e404 more_vert, e4cb play_arrow, e4cd play_circle, e567 search
- Aus f12.otf (1.2): +7 Icons: e318 home filled, e33d info, e45a open_in_new, e4f0 language, e57f settings filled, f107 home outlined, f36e settings outlined
- Interpretation:
  - Start Tab: home / home_outlined
  - Settings Tab: settings / settings_outlined
  - Search: search
  - Back: arrow_back
  - Play: play_arrow, play_circle
  - More: more_vert
  - Close: close
  - Expand: expand_more
  - Info: info
  - Open external: open_in_new
  - Language/Web: language

### Player HTML (rekonstruiert)
- Aus libapp12.so bei 406253: <!DOCTYPE html><html lang="en"><head><meta viewport>...#shell fixed flex center bg #050505, .frame-16x9 relative width min(100vw, calc(100vh*16/9)) aspect 16/9 bg #000, iframe absolute inset 0 100% border 0
- body: #shell > .frame-16x9 > iframe id playerFrame src="..."
- iframe src dynamisch: https://vidfast.vc/movie/{id}?autoPlay=true&title=true&poster=true&theme=16A085&startAt=&nextButton&autoNext
- script:
  const allowedOrigins = ["vidfast.me","vidfast.pro","vidfast.in","vidfast.vc","vidfast.bz","vidfast.pm","vidfast.net","vidfast.xyz","vidfast.io"] (APK 1.2) bzw. nur ["vidfast.vc"] in WIN 1.4
  isAllowedOrigin prüft hostname === allowed || endsWith('.'+allowed)
  message listener -> PlaybackBridge.postMessage(JSON.stringify({origin, ...payload}))
  __sendPlayerCommand(command,value) -> frame.contentWindow.postMessage({command,value},'*')

- Web Version app/player.html (einfacher, ohne allowedOrigins check, mit Back Button und Play/Pause Buttons, Provider Params autoPlay, title, poster, theme=16A085, startAt, nextButton, autoNext, Pfad /movie/{id} oder /tv/{id}/{season}/{episode}, Domain https://vidfast.vc, sendPlayerCommand via postMessage)

### Player Dart (player.dart)
- PlayerPage ConsumerStatefulWidget mit PlaybackTarget
- _PlayerPageState: WebViewController + windows WebviewController?
- _buildHtml(target, themeHex)
- _extractPayload: jsonDecode
- _handleBridgeMessage: prüft origin gegen allowedOrigins, wenn PLAYER_EVENT dann watched/duration aus Keys Hv/Hc lesen, update progressController
- _sendCommand: ruft window.__sendPlayerCommand via runJavaScript
- _initializeWindowsPlayer (nur Windows): nutzt webview_windows, lädt HTML via loadStringContent, hört webMessage, prüft isAllowedPlaybackNavigation
- isAllowedPlaybackNavigation: enthält vidfast.vc

### Versionsunterschiede
- 1.0: 9 Icons, keine SettingsHeaderCard? Kein GitHub? Kein dummy.com? Nur fastvid.vc Hinweis
- 1.1: +6 Icons (home, info, open_in_new, language, settings filled/outlined), +SettingsPage mit Themes, GitHub-Link, Version, Hinweis dummy.com statt fastvid.vc (vermutlich Placeholder für Store Review), PackageInfo, url_launcher WebViewActivity hinzugekommen
- 1.2: +1 Icon e45a (open_in_new) war schon? Eigentlich e45a kam in 1.2 dazu (open_in_new), in 1.1 war e45a noch nicht? Laut otf diff: 1.0->1.1: e318,e33d,e4f0,e57f,f107,f36e ; 1.1->1.2: e45a . Also 1.2 fügt open_in_new hinzu. Ansonsten identisch zu 1.1, aber Strings jetzt "Filme/serien ansehen<" mit angehängtem < vermutlich Build-Artefakt
- 1.4 exe: nur 3 vidfast Domains (vc), statt 9, und "Nur Inhalte von https://vidfast.vc sind erlaubt." + "Player konnte nicht geladen werden" als neuer String. _initializeWindowsPlayer statt _controller direkt.

### Original Projekt Struktur (vermutet)
- D:/movie_player/movie_player/
  - lib/
    - main.dart (alle Models, Providers, Widgets, Pages außer Player)
    - player.dart (PlayerPage)
    - key.env (API Key)
  - pubspec.yaml
  - android/
  - web/
  - assets? aber key.env als asset

## Rekonstruktion
Diese Dateien wurden aus den obigen Erkenntnissen manuell rekonstruiert und sind funktional äquivalent zum Original, nicht Byte-identisch, aber mit gleichen Strings, gleichen Domains, gleichen Provider-Namen und gleicher UI-Struktur.
