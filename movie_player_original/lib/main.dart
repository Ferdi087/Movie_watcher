import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'player.dart';

// ============================================================
// MODELS - rekonstruiert aus main.dart.js / libapp.so
// ============================================================

enum MediaKind { movie, series }

MediaKind parseKind(String raw) {
  final s = raw.toLowerCase();
  if (s.contains('series') || s.contains('tv')) return MediaKind.series;
  return MediaKind.movie;
}

String tmdbImageUrl(String? path) {
  if (path == null || path.isEmpty) return '';
  if (path.startsWith('http')) return path;
  return 'https://image.tmdb.org/t/p/w500$path';
}

String extractApiKey(String raw) {
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    final l = line.trim();
    if (l.isEmpty || l.startsWith('#')) continue;
    if (l.startsWith('API-Schluessel:')) return l.substring(15).trim();
    if (l.startsWith('API-Schlüssel:')) return l.substring(14).trim();
    if (l.startsWith('TMDB_API_KEY=')) return l.substring(13).trim();
  }
  return '';
}

Color parseHexColor(String hex) {
  var s = hex.trim().replaceAll('#', '');
  if (s.length == 6) s = 'FF$s';
  return Color(int.parse(s, radix: 16));
}

bool idealOnColorIsDark(Color c) {
  // luminance > 0.5 => dark text, else light
  return c.computeLuminance() > 0.5;
}

// WatchProgressRecord -> dO
class WatchProgressRecord {
  final int id;
  final MediaKind type;
  final String title;
  final String? posterPath;
  final String? backdropPath;
  final double watched;
  final double duration;
  final int? lastSeasonWatched;
  final int? lastEpisodeWatched;
  final int lastUpdated;

  WatchProgressRecord({
    required this.id,
    required this.type,
    required this.title,
    this.posterPath,
    this.backdropPath,
    required this.watched,
    required this.duration,
    this.lastSeasonWatched,
    this.lastEpisodeWatched,
    required this.lastUpdated,
  });

  double get progressPercent {
    if (duration <= 0) return 0;
    return (watched / duration).clamp(0, 1);
  }

  String get episodeLabel {
    if (type != MediaKind.series ||
        lastSeasonWatched == null ||
        lastEpisodeWatched == null) return '';
    final s = lastSeasonWatched.toString().padLeft(2, '0');
    final e = lastEpisodeWatched.toString().padLeft(2, '0');
    return 'S$s · E$e';
  }

  PlaybackTarget toPlaybackTarget() {
    if (type == MediaKind.series) {
      final s = lastSeasonWatched ?? 1;
      final e = lastEpisodeWatched ?? 1;
      return PlaybackTarget.series(id, s, e, watched);
    }
    return PlaybackTarget.movie(id, watched);
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'id': id,
      'type': type == MediaKind.movie ? 'movie' : 'series',
      'title': title,
      'last_updated': lastUpdated,
      'progress': {
        'watched': watched,
        'duration': duration,
      },
    };
    if (posterPath != null) map['poster_path'] = posterPath;
    if (backdropPath != null) map['backdrop_path'] = backdropPath;
    if (lastSeasonWatched != null) map['last_season_watched'] = lastSeasonWatched;
    if (lastEpisodeWatched != null) map['last_episode_watched'] = lastEpisodeWatched;
    return map;
  }

  static int? _readInt(dynamic v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static double? _readDouble(dynamic v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static String? _readString(dynamic v) {
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return null;
  }

  static WatchProgressRecord? fromJson(
      Map<String, dynamic> json, String? titleHint) {
    final id = _readInt(json['id'] ??
            json['mediaId'] ??
            json['tmdb_id'] ??
            json['tmdbId']);
    if (id == null) return null;

    final typeRaw = _readString(json['type'] ??
            json['mediaType'] ??
            json['kind']) ??
        (titleHint != null && titleHint.toLowerCase().contains('t')
            ? 'series'
            : 'movie');
    final type = parseKind(typeRaw);

    final progress = json['progress'] is Map
        ? json['progress'] as Map
        : json;

    double readProgress(List<String> keys) {
      for (final k in keys) {
        final v = progress[k];
        final d = _readDouble(v);
        if (d != null) return d;
        if (v is String) {
          final parsed = double.tryParse(v);
          if (parsed != null) return parsed;
        }
      }
      return 0;
    }

    final watched = readProgress(
        ['watched', 'current_time', 'currentTime', 'position']);
    final duration = readProgress(
        ['duration', 'total', 'totalDuration', 'runtime']);

    String readStringMulti(List<String> keys) {
      for (final k in keys) {
        final v = json[k];
        final s = _readString(v);
        if (s != null) return s;
      }
      return '';
    }

    final title = readStringMulti(
            ['title', 'name', 'original_title', 'originalName']) !=
        ''
        ? readStringMulti(
            ['title', 'name', 'original_title', 'originalName'])
        : 'Unbekannt';

    final poster = _readString(json['poster_path'] ??
        json['posterPath'] ??
        json['poster']);
    final backdrop = _readString(json['backdrop_path'] ??
        json['backdropPath'] ??
        json['backdrop']);

    final lastSeason = _readInt(json['last_season_watched'] ??
        json['lastSeasonWatched'] ??
        json['season']);
    final lastEpisode = _readInt(json['last_episode_watched'] ??
        json['lastEpisodeWatched'] ??
        json['episode']);
    final lastUpdated = _readInt(
            json['last_updated'] ?? json['lastUpdated']) ??
        DateTime.now().millisecondsSinceEpoch;

    return WatchProgressRecord(
      id: id,
      type: type,
      title: title,
      posterPath: poster,
      backdropPath: backdrop,
      watched: watched,
      duration: duration,
      lastSeasonWatched: lastSeason,
      lastEpisodeWatched: lastEpisode,
      lastUpdated: lastUpdated,
    );
  }
}

// TmdbMedia -> ec
class TmdbMedia {
  final int id;
  final String title;
  final String year;
  final double? voteAverage;
  final String? posterPath;
  final String? backdropPath;
  final MediaKind kind;

  TmdbMedia({
    required this.id,
    required this.title,
    required this.year,
    this.voteAverage,
    this.posterPath,
    this.backdropPath,
    required this.kind,
  });

  PlaybackTarget toPlaybackTarget() {
    if (kind == MediaKind.series) {
      return PlaybackTarget.series(id, 1, 1, 0);
    }
    return PlaybackTarget.movie(id, 0);
  }

  static TmdbMedia fromJson(Map<String, dynamic> json) {
    final mediaType = json['media_type'] as String?;
    final kind = (mediaType == 'tv') ? MediaKind.series : MediaKind.movie;

    final titleRaw = json['title'] ??
        json['original_title'] ??
        json['name'] ??
        json['original_name'] ??
        'Unbekannt';
    final title = titleRaw as String;

    final dateRaw = json['release_date'] ?? json['first_air_date'] ?? '';
    final year = (dateRaw is String && dateRaw.length >= 4)
        ? dateRaw.substring(0, 4)
        : '—';

    final id = (json['id'] as num?)?.toInt() ?? 0;
    final vote = (json['vote_average'] as num?)?.toDouble();
    final poster = json['poster_path'] as String?;
    final backdrop = json['backdrop_path'] as String?;

    return TmdbMedia(
      id: id,
      title: title,
      year: year,
      voteAverage: vote,
      posterPath: poster,
      backdropPath: backdrop,
      kind: kind,
    );
  }
}

// ThemePreset -> dM
class ThemePreset {
  final String id;
  final String name;
  final String description;
  final Brightness brightness;
  final Color primary;
  final Color secondary;
  final Color background;
  final Color card;
  final Color accent;

  ThemePreset({
    required this.id,
    required this.name,
    required this.description,
    required this.brightness,
    required this.primary,
    required this.secondary,
    required this.background,
    required this.card,
    required this.accent,
  });

  static ThemePreset fromJson(Map<String, dynamic> json, String fileName) {
    final name = json['name'] as String? ?? fileName.replaceAll('.json', '');
    final primary = parseHexColor(json['primary'] as String? ?? '#16A085');
    final secondary = parseHexColor(json['secondary'] as String? ?? '#5E60CE');
    final background = parseHexColor(json['background'] as String? ?? '#07111F');
    final card = parseHexColor(json['card'] as String? ?? '#13263F');
    final accent = parseHexColor(json['accent'] as String? ?? '#FF007F');
    final brightness =
        background.computeLuminance() > 0.5 ? Brightness.light : Brightness.dark;
    return ThemePreset(
      id: fileName.replaceAll('.json', '').toLowerCase(),
      name: name,
      description: 'Aus BElAppThemes/$fileName',
      brightness: brightness,
      primary: primary,
      secondary: secondary,
      background: background,
      card: card,
      accent: accent,
    );
  }
}

// EpisodeOverviewData -> px
class EpisodeOverviewData {
  final int episodeNumber;
  final String name;
  final String overview;
  final String airDate;
  final String? stillPath;

  EpisodeOverviewData({
    required this.episodeNumber,
    required this.name,
    required this.overview,
    required this.airDate,
    this.stillPath,
  });

  static EpisodeOverviewData fromJson(Map<String, dynamic> json) {
    final num = (json['episode_number'] as num?)?.toInt() ?? 0;
    final name = (json['name'] ?? json['episode_name'] ?? 'Episode') as String;
    final overview = (json['overview'] ?? '') as String;
    final airDate = (json['air_date'] ?? '') as String;
    final still = json['still_path'] as String?;
    return EpisodeOverviewData(
      episodeNumber: num,
      name: name,
      overview: overview,
      airDate: airDate,
      stillPath: still,
    );
  }
}

// SeasonOverviewData -> iC
class SeasonOverviewData {
  final int seasonNumber;
  final String name;
  final List<EpisodeOverviewData> episodes;

  SeasonOverviewData({
    required this.seasonNumber,
    required this.name,
    required this.episodes,
  });

  static SeasonOverviewData fromJson(
      Map<String, dynamic> json, int fallbackNumber) {
    final number = (json['season_number'] as num?)?.toInt() ?? fallbackNumber;
    final name = (json['name'] as String?) ?? 'Staffel $number';
    final episodesRaw = json['episodes'] as List? ?? [];
    final episodes = episodesRaw
        .whereType<Map<String, dynamic>>()
        .map(EpisodeOverviewData.fromJson)
        .toList();
    return SeasonOverviewData(
      seasonNumber: number,
      name: name,
      episodes: episodes,
    );
  }
}

// SeriesOverviewData -> jz
class SeriesOverviewData {
  final String name;
  final String overview;
  final String firstAirDate;
  final double? voteAverage;
  final String? posterPath;
  final String? backdropPath;
  final List<SeasonOverviewData> seasons;

  SeriesOverviewData({
    required this.name,
    required this.overview,
    required this.firstAirDate,
    this.voteAverage,
    this.posterPath,
    this.backdropPath,
    required this.seasons,
  });

  static SeriesOverviewData fromJson(
      Map<String, dynamic> json, List<SeasonOverviewData> seasons) {
    final name =
        (json['name'] ?? json['original_name'] ?? 'Serie') as String;
    final overview = (json['overview'] ?? '') as String;
    final firstAirDate = (json['first_air_date'] ?? '') as String;
    final vote = (json['vote_average'] as num?)?.toDouble();
    final poster = json['poster_path'] as String?;
    final backdrop = json['backdrop_path'] as String?;
    return SeriesOverviewData(
      name: name,
      overview: overview,
      firstAirDate: firstAirDate,
      voteAverage: vote,
      posterPath: poster,
      backdropPath: backdrop,
      seasons: seasons,
    );
  }
}

// PlaybackTarget -> uK
class PlaybackTarget {
  final MediaKind kind;
  final int id;
  final int? season;
  final int? episode;
  final double watched;

  PlaybackTarget(this.kind, this.id, this.season, this.episode, this.watched);

  factory PlaybackTarget.movie(int id, double watched) =>
      PlaybackTarget(MediaKind.movie, id, null, null, watched);

  factory PlaybackTarget.series(
          int id, int season, int episode, double watched) =>
      PlaybackTarget(MediaKind.series, id, season, episode, watched);
}

// ============================================================
// PROVIDERS - rekonstruiert aus init:* Symbolen
// ============================================================

final packageInfoProvider = FutureProvider<PackageInfo>((ref) async {
  try {
    // versucht version.json relativ zur baseUri zu laden (wie A.aen.auc)
    // Für native fällt es zurück auf PackageInfo.fromPlatform
    if (kIsWeb) {
      final base = Uri.base;
      final versionUri = base.resolve('version.json').replace(
          queryParameters: {'cachebuster': DateTime.now().millisecondsSinceEpoch.toString()});
      final res = await http.get(versionUri);
      if (res.statusCode == 200) {
        final m = jsonDecode(res.body) as Map<String, dynamic>;
        return PackageInfo(
          appName: m['app_name'] as String? ?? 'movie_player',
          packageName: m['package_name'] as String? ?? 'movie_player',
          version: m['version'] as String? ?? '1.0.0',
          buildNumber: m['build_number'] as String? ?? '1',
        );
      }
    }
    return await PackageInfo.fromPlatform();
  } catch (_) {
    return PackageInfo(
        appName: 'movie_player',
        packageName: 'movie_player',
        version: '1.0.0',
        buildNumber: '1');
  }
});

final tmdbApiKeyProvider = FutureProvider<String>((ref) async {
  try {
    final raw = await rootBundle.loadString('lib/key.env');
    final key = extractApiKey(raw);
    return key;
  } catch (_) {
    return '';
  }
});

final trendingTrailersProvider =
    FutureProvider<List<TmdbMedia>>((ref) async {
  final apiKey = await ref.watch(tmdbApiKeyProvider.future);
  if (apiKey.isEmpty) return [];
  final uri = Uri.https('api.themoviedb.org', '/3/trending/movie/week',
      {'api_key': apiKey, 'language': 'de-DE'});
  final res = await http.get(uri);
  if (res.statusCode != 200) throw Exception('TMDB-Trending konnte nicht geladen werden.');
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  final results = data['results'] as List? ?? [];
  return results
      .whereType<Map<String, dynamic>>()
      .map(TmdbMedia.fromJson)
      .toList();
});

final tmdbSearchResultsProvider =
    FutureProviderFamily<List<TmdbMedia>, String>((ref, query) async {
  final q = query.trim();
  if (q.isEmpty) return [];
  final apiKey = await ref.watch(tmdbApiKeyProvider.future);
  if (apiKey.isEmpty) return [];
  final uri = Uri.https('api.themoviedb.org', '/3/search/multi', {
    'api_key': apiKey,
    'language': 'de-DE',
    'query': q,
    'include_adult': 'false',
  });
  final res = await http.get(uri);
  if (res.statusCode != 200) throw Exception('TMDB-Suche konnte nicht geladen werden.');
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  final results = data['results'] as List? ?? [];
  return results
      .whereType<Map<String, dynamic>>()
      .where((m) => (m['media_type'] ?? 'movie') != 'person')
      .map(TmdbMedia.fromJson)
      .toList();
});

final seriesOverviewProvider =
    FutureProviderFamily<SeriesOverviewData, int>((ref, tvId) async {
  final apiKey = await ref.watch(tmdbApiKeyProvider.future);
  if (apiKey.isEmpty) throw Exception('TMDB API-Key fehlt.');
  final uri = Uri.https('api.themoviedb.org', '/3/tv/$tvId',
      {'api_key': apiKey, 'language': 'de-DE'});
  final res = await http.get(uri);
  if (res.statusCode != 200) throw Exception('Serien-Details konnten nicht geladen werden.');
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  final seasonsRaw = data['seasons'] as List? ?? [];
  final validSeasons = seasonsRaw
      .whereType<Map<String, dynamic>>()
      .where((s) => (s['season_number'] as num?) != null)
      .map((s) => (s['season_number'] as num).toInt())
      .where((n) => n > 0)
      .toList();

  final seasons = await Future.wait(validSeasons.map((seasonNum) async {
    final seasonUri = Uri.https('api.themoviedb.org',
        '/3/tv/$tvId/season/$seasonNum', {'api_key': apiKey, 'language': 'de-DE'});
    final seasonRes = await http.get(seasonUri);
    if (seasonRes.statusCode != 200) {
      return SeasonOverviewData(
          seasonNumber: seasonNum, name: 'Staffel $seasonNum', episodes: []);
    }
    final seasonData = jsonDecode(seasonRes.body) as Map<String, dynamic>;
    final episodesRaw = seasonData['episodes'] as List? ?? [];
    final episodes = episodesRaw
        .whereType<Map<String, dynamic>>()
        .map(EpisodeOverviewData.fromJson)
        .toList();
    final name = (seasonData['name'] as String?) ?? 'Staffel $seasonNum';
    return SeasonOverviewData(
        seasonNumber: seasonNum, name: name, episodes: episodes);
  }));

  return SeriesOverviewData.fromJson(data, seasons);
});

const _remoteThemeFiles = [
  'Theme1.json',
  'Theme2.json',
  'Theme3.json',
  'Theme4.json',
  'Theme5.json',
  'Theme6.json',
  'Theme7.json',
  'Theme8.json',
  'Theme9.json',
  'Theme10.json',
  'Theme11.json',
  'Theme12.json',
  'Theme13.json',
  'Theme14.json',
];

final remoteThemesProvider = FutureProvider<List<ThemePreset>>((ref) async {
  final themes = <ThemePreset>[];
  for (final file in _remoteThemeFiles) {
    try {
      final uri = Uri.parse(
          'https://raw.githubusercontent.com/Ferdi087/BElAppThemes/main/$file');
      final res = await http.get(uri);
      if (res.statusCode != 200) continue;
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic>) {
        themes.add(ThemePreset.fromJson(data, file));
      }
    } catch (_) {
      continue;
    }
  }
  return themes;
});

final appThemeControllerProvider =
    StateNotifierProvider<AppThemeController, String>((ref) {
  return AppThemeController();
});

class AppThemeController extends StateNotifier<String> {
  AppThemeController() : super('standard') {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('selectedThemePreset');
      state = saved ?? 'standard';
    } catch (_) {
      state = 'standard';
    }
  }

  Future<void> setTheme(String id) async {
    state = id;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selectedThemePreset', id);
    } catch (_) {}
  }

  ThemePreset resolveThemePreset(String id, List<ThemePreset> remote) {
    if (id == 'light') return _lightTheme;
    if (id == 'dark') return _darkTheme;
    if (id != 'standard') {
      for (final t in remote) {
        if (t.id == id) return t;
      }
    }
    return _standardTheme;
  }

  ThemeData buildTheme(ThemePreset preset) {
    final brightness = preset.brightness;
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: preset.primary,
      brightness: brightness,
      primary: preset.primary,
      secondary: preset.secondary,
      background: preset.background,
      surface: preset.card,
    );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: preset.background,
      cardColor: preset.card,
      useMaterial3: true,
      textTheme: isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: preset.background,
        foregroundColor: idealOnColorIsDark(preset.background)
            ? Colors.black
            : Colors.white,
        elevation: 0,
      ),
    );
  }
}

// Built-in Themes rekonstruiert aus B.zu / B.zv / B.zt
final _standardTheme = ThemePreset(
  id: 'standard',
  name: 'Standard',
  description: 'Das aktuelle App-Theme',
  brightness: Brightness.dark,
  primary: const Color(0xFF16A085),
  secondary: const Color(0xFF5E60CE),
  background: const Color(0xFF07111F),
  card: const Color(0xFF13263F),
  accent: const Color(0xFFFF007F),
);

final _lightTheme = ThemePreset(
  id: 'light',
  name: 'Hell',
  description: 'Helles, klares Theme',
  brightness: Brightness.light,
  primary: const Color(0xFF0C8A6D),
  secondary: const Color(0xFF5B5FEF),
  background: const Color(0xFFF7F9FC),
  card: Colors.white,
  accent: const Color(0xFFFF477E),
);

final _darkTheme = ThemePreset(
  id: 'dark',
  name: 'Dunkel',
  description: 'Dunkles, neutrales Theme',
  brightness: Brightness.dark,
  primary: const Color(0xFF4CC9F0),
  secondary: const Color(0xFF7B61FF),
  background: const Color(0xFF05070C),
  card: const Color(0xFF0F172A),
  accent: const Color(0xFFFFB703),
);

final progressControllerProvider =
    StateNotifierProvider<ProgressController, List<WatchProgressRecord>>(
        (ref) => ProgressController());

class ProgressController extends StateNotifier<List<WatchProgressRecord>> {
  ProgressController() : super([]) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('dummyProgress');
      if (raw == null || raw.isEmpty) {
        state = [];
        return;
      }
      final list = jsonDecode(raw) as List;
      final items = list
          .whereType<Map<String, dynamic>>()
          .map((e) => WatchProgressRecord.fromJson(e, null))
          .whereType<WatchProgressRecord>()
          .toList()
        ..sort((a, b) => b.lastUpdated.compareTo(a.lastUpdated));
      state = items;
    } catch (_) {
      state = [];
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(state.map((e) => e.toJson()).toList());
      await prefs.setString('dummyProgress', raw);
    } catch (_) {}
  }

  Future<void> addOrUpdate(WatchProgressRecord record) async {
    final filtered = state.where((e) => !(e.id == record.id && e.type == record.type)).toList();
    filtered.insert(0, record);
    filtered.sort((a, b) => b.lastUpdated.compareTo(a.lastUpdated));
    state = filtered;
    await _save();
  }

  Future<void> addPlayback(PlaybackTarget target, {String title = 'Unbekannt', String? poster, String? backdrop}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = state.firstWhere(
        (e) => e.id == target.id && e.type == target.kind,
        orElse: () => WatchProgressRecord(
            id: target.id,
            type: target.kind,
            title: title,
            posterPath: poster,
            backdropPath: backdrop,
            watched: 0,
            duration: 0,
            lastUpdated: now));

    final rec = WatchProgressRecord(
      id: target.id,
      type: target.kind,
      title: existing.title == 'Unbekannt' ? title : existing.title,
      posterPath: poster ?? existing.posterPath,
      backdropPath: backdrop ?? existing.backdropPath,
      watched: target.watched,
      duration: existing.duration > 0 ? existing.duration : (target.watched > 0 ? target.watched + 100 : 0),
      lastSeasonWatched: target.season ?? existing.lastSeasonWatched,
      lastEpisodeWatched: target.episode ?? existing.lastEpisodeWatched,
      lastUpdated: now,
    );
    await addOrUpdate(rec);
  }

  List<WatchProgressRecord> filterPopular(List<WatchProgressRecord> items) {
    // nur Filme? Oder nach Typ?
    return items.where((e) => e.type == MediaKind.series).toList();
  }

  List<WatchProgressRecord> filterRecent(List<WatchProgressRecord> items) {
    return items;
  }
}

// ============================================================
// WIDGETS
// ============================================================

class SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  const SectionHeader(this.title, this.subtitle, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(subtitle,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.68))),
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key});
  @override
  Widget build(BuildContext context) {
    return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
  }
}

class ErrorState extends StatelessWidget {
  final String message;
  const ErrorState(this.message, {super.key});
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text('Fehler beim Laden',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(message,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.72))),
          ],
        ),
      ),
    );
  }
}

class LoadingStrip extends StatelessWidget {
  const LoadingStrip({super.key});
  @override
  Widget build(BuildContext context) {
    return const LinearProgressIndicator();
  }
}

class MediaCardBase extends StatelessWidget {
  final Widget child;
  final Color? color;
  const MediaCardBase({super.key, required this.child, this.color});
  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      clipBehavior: Clip.hardEdge,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: child,
    );
  }
}

class MediaCardOverlay extends StatelessWidget {
  final String title;
  final String subtitle;
  const MediaCardOverlay({super.key, required this.title, required this.subtitle});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black.withOpacity(0.8), Colors.transparent]),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          Text(subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 12)),
        ],
      ),
    );
  }
}

// SearchResultCard -> Pt
class SearchResultCard extends StatelessWidget {
  final TmdbMedia media;
  final VoidCallback onTap;
  const SearchResultCard(
      {super.key, required this.media, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final typeLabel = media.kind == MediaKind.series ? 'Serie' : 'Film';
    final rating = media.voteAverage != null
        ? ' · ${media.voteAverage!.toStringAsFixed(1)}'
        : '';
    return InkWell(
      onTap: onTap,
      child: MediaCardBase(
        child: Stack(
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: media.posterPath != null && media.posterPath!.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: tmdbImageUrl(media.posterPath),
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: Theme.of(context).colorScheme.surfaceVariant),
                      errorWidget: (_, __, ___) => Container(color: Colors.grey.shade900),
                    )
                  : Container(color: Colors.grey.shade900),
            ),
            Positioned.fill(child: MediaCardOverlay(title: media.title, subtitle: '$typeLabel · ${media.year}$rating')),
          ],
        ),
      ),
    );
  }
}

// RecentProgressCard -> Om (Weitersehen)
class RecentProgressCard extends StatelessWidget {
  final WatchProgressRecord record;
  final VoidCallback onTap;
  const RecentProgressCard(
      {super.key, required this.record, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isSeries = record.type == MediaKind.series;
    final label = isSeries && record.episodeLabel.isNotEmpty
        ? record.episodeLabel
        : 'Weitersehen';
    final progress = record.progressPercent;
    final sub = isSeries
        ? '${record.episodeLabel} · ${ (progress*100).toStringAsFixed(0)}%'
        : '${ (progress*100).toStringAsFixed(0)}% Fortschritt';

    return InkWell(
      onTap: onTap,
      child: MediaCardBase(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: record.posterPath != null
                        ? CachedNetworkImage(
                            imageUrl: tmdbImageUrl(record.posterPath),
                            fit: BoxFit.cover,
                          )
                        : Container(color: Colors.grey.shade900),
                  ),
                  Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(999)),
                        child: Text('${ (progress*100).toStringAsFixed(0)}%',
                            style: const TextStyle(color: Colors.white, fontSize: 11)),
                      )),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(record.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: progress, minHeight: 4, backgroundColor: Theme.of(context).colorScheme.onSurface.withOpacity(0.18)),
                  const SizedBox(height: 6),
                  Text(sub,
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// TrendingTrailerCard -> QZ (Filme/serien ansehen)
class TrendingTrailerCard extends StatelessWidget {
  final TmdbMedia media;
  final VoidCallback onTap;
  const TrendingTrailerCard(
      {super.key, required this.media, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final rating = media.voteAverage != null
        ? ' · ${media.voteAverage!.toStringAsFixed(1)}'
        : '';
    return InkWell(
      onTap: onTap,
      child: MediaCardBase(
        child: Stack(
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: CachedNetworkImage(
                imageUrl: tmdbImageUrl(media.posterPath),
                fit: BoxFit.cover,
              ),
            ),
            Positioned.fill(
                child: MediaCardOverlay(
                    title: media.title, subtitle: '${media.year}$rating')),
            Positioned(
              bottom: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(8)),
                child: const Text('Filme/serien ansehen',
                    style: TextStyle(color: Colors.white, fontSize: 10)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// EpisodeProgressCard -> Lo (Episode fortsetzen)
class EpisodeProgressCard extends StatelessWidget {
  final WatchProgressRecord record;
  final VoidCallback onTap;
  const EpisodeProgressCard(
      {super.key, required this.record, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: MediaCardBase(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 64,
                  height: 96,
                  child: record.posterPath != null
                      ? CachedNetworkImage(
                          imageUrl: tmdbImageUrl(record.posterPath),
                          fit: BoxFit.cover)
                      : Container(color: Colors.grey.shade800),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(record.title,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(record.episodeLabel,
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.7))),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withOpacity(0.12),
                          borderRadius: BorderRadius.circular(999)),
                      child: const Text('Episode fortsetzen',
                          style: TextStyle(fontSize: 11)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// PAGES
// ============================================================

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(appThemeControllerProvider);
    final remoteAsync = ref.watch(remoteThemesProvider);
    final remote = remoteAsync.value ?? [];
    final controller = ref.read(appThemeControllerProvider.notifier);
    final preset = controller.resolveThemePreset(selected, remote);
    final theme = controller.buildTheme(preset);

    return MaterialApp(
      title: 'movie_player',
      theme: theme,
      darkTheme: theme,
      themeMode: preset.brightness == Brightness.dark
          ? ThemeMode.dark
          : preset.brightness == Brightness.light
              ? ThemeMode.light
              : ThemeMode.system,
      home: const AppShell(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      StreamingHomePage(
        onOpenSeries: (id) {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SeriesOverviewPage(tvId: id)));
        },
      ),
      const SettingsPage(),
    ];

    // Original hatte nur 2 Tabs: Start und Settings
    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Start',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class StreamingHomePage extends ConsumerStatefulWidget {
  final void Function(int tvId) onOpenSeries;
  const StreamingHomePage({super.key, required this.onOpenSeries});

  @override
  ConsumerState<StreamingHomePage> createState() =>
      _StreamingHomePageState();
}

class _StreamingHomePageState extends ConsumerState<StreamingHomePage> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _query = _searchController.text;
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _openPlayback(PlaybackTarget target,
      {String? title, String? poster, String? backdrop}) {
    // speichert Fortschritt lokal (dummyProgress)
    ref
        .read(progressControllerProvider.notifier)
        .addPlayback(target, title: title ?? 'Unbekannt', poster: poster, backdrop: backdrop);
    // öffnet Player
    if (kIsWeb) {
      // Web: navigiert zu player.html wie A.aKm
      final params = <String, String>{
        'kind': target.kind == MediaKind.movie ? 'movie' : 'series',
        'id': target.id.toString(),
      };
      if (target.season != null) params['season'] = target.season.toString();
      if (target.episode != null) params['episode'] = target.episode.toString();
      if (target.watched > 0) params['startAt'] = target.watched.toStringAsFixed(0);
      final uri = Uri.parse('player.html').replace(queryParameters: params);
      // ignore: avoid_web_libraries_in_flutter
      // window.location.assign(uri.toString()); -> Für Web wird im original JS window.location.assign verwendet
      // Wir nutzen Navigator für Flutter Web Fallback
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PlayerPage(target: target)));
    } else {
      Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => PlayerPage(target: target)));
    }
  }

  void _openSeriesOverview(int tvId) {
    widget.onOpenSeries(tvId);
  }

  void _openEpisode(SeasonOverviewData season, EpisodeOverviewData episode,
      int tvId, String title, String? poster, String? backdrop) {
    final target = PlaybackTarget.series(
        tvId, season.seasonNumber, episode.episodeNumber, 0);
    _openPlayback(target, title: '$title - ${episode.name}', poster: poster, backdrop: backdrop);
  }

  void _openRecentSeriesOverview(WatchProgressRecord record) {
    _openSeriesOverview(record.id);
  }

  @override
  Widget build(BuildContext context) {
    final apiKeyAsync = ref.watch(tmdbApiKeyProvider);
    final searchAsync = ref.watch(tmdbSearchResultsProvider(_query));
    final trendingAsync = ref.watch(trendingTrailersProvider);
    final progressAsync = ref.watch(progressControllerProvider);
    final apiKey = apiKeyAsync.value ?? '';

    final isWide = MediaQuery.of(context).size.width >= 900;
    final crossAxis = isWide ? 5 : 2;
    final cardHeight = isWide ? 210.0 : 180.0;

    final hasNoKey = apiKey.trim().isEmpty;

    final children = <Widget>[
      // Header
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Streaming Frontend',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
              'Suche, setze die Wiedergabe fort und öffne Filme/serien direkt im Player.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.78)),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                        },
                      )
                    : null,
                hintText: 'Titel filtern ...',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18)),
                filled: true,
              ),
            ),
            if (hasNoKey) ...[
              const SizedBox(height: 14),
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'TMDB_API_KEY ist noch nicht gesetzt. Hinterlege den Key sicher per --dart-define, damit die Trending-Filme live geladen werden.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),

      if (_query.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 18, 16, 8),
          child: SectionHeader('Suchergebnisse',
              'TMDB-Multi-Suche für Filme und Serien.'),
        ),
        searchAsync.when(
          loading: () => const LoadingStrip(),
          error: (e, _) => ErrorState(e.toString()),
          data: (list) {
            if (list.isEmpty) {
              return const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                      'Keine Treffer\nVersuche einen anderen Titel oder kürze die Suche.'),
                ),
              );
            }
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxis,
                childAspectRatio: 0.62,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: list.length,
              itemBuilder: (c, i) {
                final m = list[i];
                return SearchResultCard(
                  media: m,
                  onTap: () {
                    if (m.kind == MediaKind.series) {
                      _openSeriesOverview(m.id);
                    } else {
                      _openPlayback(m.toPlaybackTarget(),
                          title: m.title,
                          poster: m.posterPath,
                          backdrop: m.backdropPath);
                    }
                  },
                );
              },
            );
          },
        ),
      ],

      const Padding(
        padding: EdgeInsets.fromLTRB(16, 18, 16, 8),
        child: SectionHeader(
            'Zuletzt gesehen', 'Fortsetzen aus deinem lokalen Fortschritt.'),
      ),
      if (progressAsync.isEmpty)
        const Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
                'Noch kein Verlauf gespeichert\nSobald ein Player-Event Daten liefert, erscheint der Verlauf hier. (in bearbeitung)'),
          ),
        )
      else
        SizedBox(
          height: cardHeight + 80,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: progressAsync.length,
            itemBuilder: (c, i) {
              final rec = progressAsync[i];
              return SizedBox(
                width: isWide ? 180 : 150,
                child: RecentProgressCard(
                  record: rec,
                  onTap: () {
                    if (rec.type == MediaKind.series) {
                      _openRecentSeriesOverview(rec);
                    } else {
                      _openPlayback(rec.toPlaybackTarget(),
                          title: rec.title,
                          poster: rec.posterPath,
                          backdrop: rec.backdropPath);
                    }
                  },
                ),
              );
            },
          ),
        ),

      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: SectionHeader('Beliebte Filme/serien',
            hasNoKey
                ? 'Lege den Key in lib/key.env ab oder setze TMDB_API_KEY via --dart-define.'
                : 'Aktuelle Trending-Filme/serien von TMDB.'),
      ),
      trendingAsync.when(
        loading: () => const LoadingStrip(),
        error: (e, _) => ErrorState(e.toString()),
        data: (list) {
          if (hasNoKey) {
            return const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                    'TMDB API-Key fehlt\nDie Trending-Liste wird geladen, sobald der Key in lib/key.env oder per --dart-define vorhanden ist.'),
              ),
            );
          }
          if (list.isEmpty) {
            return const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                    'Keine Filme/serien gefunden\nVersuche es später erneut.'),
              ),
            );
          }
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxis,
              childAspectRatio: 0.62,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: list.length,
            itemBuilder: (c, i) {
              final m = list[i];
              return TrendingTrailerCard(
                media: m,
                onTap: () => _openPlayback(m.toPlaybackTarget(),
                    title: m.title,
                    poster: m.posterPath,
                    backdrop: m.backdropPath),
              );
            },
          );
        },
      ),

      if (progressAsync.where((e) => e.type == MediaKind.series).isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: SectionHeader('Neue Episoden',
              'Serienfortschritt mit S- und E-Labels zum direkten Fortsetzen.'),
        ),
        SizedBox(
          height: 130,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: progressAsync
                .where((e) => e.type == MediaKind.series)
                .map((rec) => SizedBox(
                      width: 300,
                      child: EpisodeProgressCard(
                        record: rec,
                        onTap: () => _openRecentSeriesOverview(rec),
                      ),
                    ))
                .toList(),
          ),
        ),
      ],

      const SizedBox(height: 24),
    ];

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SeriesOverviewPage extends ConsumerWidget {
  final int tvId;
  const SeriesOverviewPage({super.key, required this.tvId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seriesAsync = ref.watch(seriesOverviewProvider(tvId));
    return seriesAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('Serie')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Serie')),
        body: Center(child: Text(e.toString())),
      ),
      data: (series) {
        return Scaffold(
          appBar: AppBar(title: Text(series.name)),
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (series.backdropPath != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: CachedNetworkImage(
                              imageUrl: tmdbImageUrl(series.backdropPath),
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      Text(series.name,
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Text(
                        '${series.firstAirDate} · ${series.voteAverage != null ? '${series.voteAverage!.toStringAsFixed(1)}' : ''}',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withOpacity(0.78)),
                      ),
                      const SizedBox(height: 12),
                      Text(series.overview.isEmpty
                          ? 'Keine Beschreibung vorhanden.'
                          : series.overview),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (c, seasonIndex) {
                    final season = series.seasons[seasonIndex];
                    return ExpansionTile(
                      title: Text(season.name),
                      subtitle: Text('${season.episodes.length} Episoden'),
                      children: season.episodes.map((ep) {
                        return ListTile(
                          leading: CircleAvatar(child: Text('${ep.episodeNumber}')),
                          title: Text(ep.name),
                          subtitle: Text(ep.overview.isEmpty ? ep.airDate : ep.overview, maxLines: 2, overflow: TextOverflow.ellipsis),
                          onTap: () {
                            final target = PlaybackTarget.series(
                                tvId, season.seasonNumber, ep.episodeNumber, 0);
                            ref.read(progressControllerProvider.notifier).addPlayback(target,
                                title: '${series.name} - ${ep.name}',
                                poster: series.posterPath,
                                backdrop: series.backdropPath);
                            Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => PlayerPage(target: target)));
                          },
                        );
                      }).toList(),
                    );
                  },
                  childCount: series.seasons.length,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(appThemeControllerProvider);
    final remoteAsync = ref.watch(remoteThemesProvider);
    final packageInfoAsync = ref.watch(packageInfoProvider);
    final themeController = ref.read(appThemeControllerProvider.notifier);
    final remoteThemes = remoteAsync.value ?? [];

    final allPresets = <ThemePreset>[
      _standardTheme,
      _lightTheme,
      _darkTheme,
      ...remoteThemes,
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SettingsHeaderCard(),
          const SizedBox(height: 16),
          Text('Themes',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Standard, Hell, Dunkel und die Theme-Dateien aus dem BElAppThemes-Repository.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          ...allPresets.map((preset) {
            final isSelected = preset.id == selected ||
                (preset.id == 'standard' && selected == 'standard' && preset == _standardTheme);
            return Card(
              color: isSelected
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              child: ListTile(
                title: Text(preset.name),
                subtitle: Text(preset.description),
                leading: CircleAvatar(
                  backgroundColor: preset.primary,
                  child: Icon(Icons.palette,
                      color: idealOnColorIsDark(preset.primary)
                          ? Colors.black
                          : Colors.white),
                ),
                trailing: isSelected ? const Icon(Icons.check) : null,
                onTap: () => themeController.setTheme(preset.id),
              ),
            );
          }),
          const SizedBox(height: 12),
          remoteAsync.when(
            loading: () => const Text('Externe Themes werden geladen...'),
            error: (e, _) => Text('Externe Themes konnten nicht geladen werden: $e'),
            data: (list) => Text('${list.length} externe Themes aus BElAppThemes verfügbar.'),
          ),
          const SizedBox(height: 24),
          Card(
            child: ListTile(
              title: const Text('Hinweis zu Medienquellen'),
              subtitle: const Text('Alle Medien stammen aus fastvid.vc.'),
              leading: const Icon(Icons.info_outline),
            ),
          ),
          const SizedBox(height: 24),
          packageInfoAsync.when(
            loading: () => const Text('Version wird geladen...'),
            error: (_, __) => const Text('Version: unbekannt'),
            data: (info) => Text('Version ${info.version}+${info.buildNumber}'),
          ),
          const SizedBox(height: 4),
          const Text('Ferdinand aus Deutschland',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () async {
              final uri = Uri.parse('https://github.com/ferdi087/Movie_watcher');
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            icon: const Icon(Icons.open_in_new),
            label: const Text('GitHub-Link öffnen'),
          ),
        ],
      ),
    );
  }
}

class SettingsHeaderCard extends StatelessWidget {
  const SettingsHeaderCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.settings,
                size: 32, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Einstellungen',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const Text('Ferdinand aus Deutschland',
                      style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
