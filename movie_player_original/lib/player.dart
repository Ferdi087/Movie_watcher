import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_windows/webview_windows.dart' as win_webview;

import 'main.dart';

// ============================================================
// PlayerPage - rekonstruiert aus libapp.so
// _PlayerPageState@... mit _buildHtml, _handleBridgeMessage etc.
// ============================================================

class PlayerPage extends ConsumerStatefulWidget {
  final PlaybackTarget target;
  const PlayerPage({super.key, required this.target});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  late final WebViewController _controller;
  win_webview.WebviewController? _windowsController;
  bool _isWindows = false;
  String? _currentPosition;
  double _readDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  int _readInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  String _readString(dynamic v) {
    if (v is String) return v;
    if (v != null) return v.toString();
    return '';
  }

  // HTML Template rekonstruiert aus libapp12.so
  // Original: <!DOCTYPE html> <html lang="en"> ... frame-16x9 + playerFrame + allowedOrigins + PlaybackBridge
  String _buildHtml(PlaybackTarget target, String themeHex) {
    // vidfast domains - aus APK 1.2: 9 domains, aus 1.4: nur vc
    // Wir nehmen die vollständige Liste für Kompatibilität
    const allowedOrigins = [
      'vidfast.me',
      'vidfast.pro',
      'vidfast.in',
      'vidfast.vc',
      'vidfast.bz',
      'vidfast.pm',
      'vidfast.net',
      'vidfast.xyz',
      'vidfast.io',
    ];

    // Query params wie in app/player.html (web version)
    final query = <String, String>{
      'autoPlay': 'true',
      'title': 'true',
      'poster': 'true',
      'theme': themeHex.replaceAll('#', ''),
    };
    if (target.watched > 0) {
      query['startAt'] = target.watched.round().toString();
    }
    if (target.kind == MediaKind.series) {
      query['nextButton'] = 'true';
      query['autoNext'] = 'true';
    }

    final queryString = query.entries.map((e) => '${e.key}=${e.value}').join('&');
    final path = target.kind == MediaKind.movie
        ? '/movie/${target.id}'
        : '/tv/${target.id}/${target.season ?? 1}/${target.episode ?? 1}';

    // Primary domain: vidfast.vc (wie in web player.html)
    final iframeSrc = 'https://vidfast.vc$path?$queryString';

    // HTML wie in APK extrahiert
    return '''
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <style>
      html, body {
        margin: 0;
        width: 100%;
        height: 100%;
        overflow: hidden;
        background: #050505;
      }
      #shell {
        position: fixed;
        inset: 0;
        display: flex;
        align-items: center;
        justify-content: center;
        background: #050505;
      }
      .frame-16x9 {
        position: relative;
        width: min(100vw, calc(100vh * 16 / 9));
        aspect-ratio: 16 / 9;
        background: #000;
      }
      .frame-16x9 iframe {
        position: absolute;
        inset: 0;
        width: 100%;
        height: 100%;
        border: 0;
        background: #000;
      }
    </style>
  </head>
  <body>
    <div id="shell">
      <div class="frame-16x9">
        <iframe id="playerFrame" src="$iframeSrc" frameborder="0" allowfullscreen allow="encrypted-media"></iframe>
      </div>
    </div>
    <script>
      const allowedOrigins = ${jsonEncode(allowedOrigins)};

      function isAllowedOrigin(origin) {
        try {
          const host = new URL(origin).hostname;
          return allowedOrigins.some((allowed) => host === allowed || host.endsWith('.' + allowed));
        } catch (error) {
          return false;
        }
      }

      window.addEventListener('message', function(event) {
        if (!event || !event.origin || !isAllowedOrigin(event.origin)) {
          return;
        }
        const payload = typeof event.data === 'string' ? { type: 'PLAYER_EVENT', data: event.data } : event.data;
        PlaybackBridge.postMessage(JSON.stringify({ origin: event.origin, ...payload }));
      });

      window.__sendPlayerCommand = function(command, value) {
        const frame = document.getElementById('playerFrame');
        if (!frame || !frame.contentWindow) {
          return false;
        }
        frame.contentWindow.postMessage({ command: command, value: value }, '*');
        return true;
      };
    </script>
  </body>
</html>
''';
  }

  Map<String, dynamic>? _extractPayload(dynamic raw) {
    try {
      if (raw is String) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is String) {
          return jsonDecode(decoded) as Map<String, dynamic>?;
        }
      } else if (raw is Map<String, dynamic>) {
        return raw;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _handleBridgeMessage(String message) async {
    final payload = _extractPayload(message);
    if (payload == null) return;

    // Origin check - wie in _buildHtml isAllowedOrigin, aber zusätzlich in Dart
    final origin = payload['origin'] as String? ?? '';
    if (origin.isNotEmpty) {
      final allowed = [
        'vidfast.me',
        'vidfast.pro',
        'vidfast.in',
        'vidfast.vc',
        'vidfast.bz',
        'vidfast.pm',
        'vidfast.net',
        'vidfast.xyz',
        'vidfast.io',
      ];
      final host = Uri.tryParse(origin)?.host ?? '';
      final isAllowed = allowed.any((a) => host == a || host.endsWith('.$a'));
      if (!isAllowed && host != 'vidfast.vc' && !host.endsWith('.vidfast.vc')) {
        debugPrint('Blocked origin: $origin');
        return;
      }
    }

    // PLAYER_EVENT handling
    if (payload['type'] == 'PLAYER_EVENT') {
      dynamic data = payload['data'];
      if (data is String) {
        try {
          data = jsonDecode(data);
        } catch (_) {
          // data bleibt String
        }
      }

      if (data is Map) {
        // Versucht watched / current_time / position und duration zu lesen
        double watched = 0;
        double duration = 0;

        for (final key in ['watched', 'current_time', 'currentTime', 'position']) {
          if (data.containsKey(key)) {
            watched = _readDouble(data[key]);
            if (watched > 0) break;
          }
        }
        for (final key in ['duration', 'total', 'totalDuration', 'runtime']) {
          if (data.containsKey(key)) {
            duration = _readDouble(data[key]);
            if (duration > 0) break;
          }
        }

        // Wenn timeupdate Event
        if (data['type'] == 'timeupdate' || watched > 0) {
          final target = widget.target;
          final updated = PlaybackTarget(
            target.kind,
            target.id,
            target.season,
            target.episode,
            watched,
          );

          // Update progressController
          await ref.read(progressControllerProvider.notifier).addPlayback(
                updated,
                title: 'Fortschritt',
              );

          setState(() {
            _currentPosition = '${watched.toStringAsFixed(0)} / ${duration.toStringAsFixed(0)}';
          });
        }
      }
    }
  }

  Future<void> _sendCommand(String command, [dynamic value]) async {
    if (_isWindows) {
      if (_windowsController != null) {
        try {
          final js = '''
            (function(){
              const frame = document.getElementById('playerFrame');
              if(frame && frame.contentWindow){
                frame.contentWindow.postMessage({command: "$command", value: ${value != null ? jsonEncode(value) : 'null'}}, '*');
                return true;
              }
              return false;
            })()
          ''';
          await _windowsController!.executeScript(js);
        } catch (_) {}
      }
    } else {
      try {
        final val = value != null ? jsonEncode(value) : 'null';
        await _controller.runJavaScript('''
          window.__sendPlayerCommand("$command", $val);
        ''');
      } catch (_) {}
    }
  }

  Future<void> _initializeWindowsPlayer() async {
    // Windows spezifische Initialisierung - aus Symbol _initializeWindowsPlayer@610455924
    if (!Platform.isWindows) return;
    _isWindows = true;
    _windowsController = win_webview.WebviewController();
    try {
      await _windowsController!.initialize();
      final selectedTheme = ref.read(appThemeControllerProvider);
      final remote = await ref.read(remoteThemesProvider.future).catchError((_) => <ThemePreset>[]);
      final preset = ref.read(appThemeControllerProvider.notifier).resolveThemePreset(selectedTheme, remote);
      final themeHex = '#${preset.primary.value.toRadixString(16).substring(2)}';
      final html = _buildHtml(widget.target, themeHex);

      await _windowsController!.loadStringContent(html);

      // Erlaubt nur vidfast.vc Inhalte (wie in WIN 1.4: "Nur Inhalte von https://vidfast.vc sind erlaubt.")
      _windowsController!.webMessage.listen((msg) async {
        await _handleBridgeMessage(msg);
      });

      // Navigation check
      _windowsController!.url.listen((url) {
        final isAllowed = url.contains('vidfast.vc');
        if (!isAllowed && url != 'about:blank') {
          debugPrint('Blocked navigation to $url - Nur Inhalte von https://vidfast.vc sind erlaubt.');
        }
      });
    } catch (e) {
      debugPrint('Windows player init failed: $e');
    }
  }

  bool isAllowedPlaybackNavigation(String url) {
    return url.contains('vidfast.vc') ||
        url.contains('vidfast.') ||
        url == 'about:blank';
  }

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      _initializeWindowsPlayer();
    } else {
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFF050505))
        ..addJavaScriptChannel('PlaybackBridge',
            onMessageReceived: (JavaScriptMessage message) async {
          await _handleBridgeMessage(message.message);
        })
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) {
              if (!isAllowedPlaybackNavigation(request.url)) {
                return NavigationDecision.prevent;
              }
              return NavigationDecision.navigate;
            },
            onPageFinished: (_) {
              // Player bereit
            },
          ),
        );

      // Enable debugging etc. für Android
      if (_controller.platform is AndroidWebViewController) {
        ( _controller.platform as AndroidWebViewController)
            .enableDebugging(true);
      }

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final selectedTheme = ref.read(appThemeControllerProvider);
        final remote = await ref.read(remoteThemesProvider.future).catchError((_) => <ThemePreset>[]);
        final preset = ref.read(appThemeControllerProvider.notifier).resolveThemePreset(selectedTheme, remote);
        final themeHex = '#${preset.primary.value.toRadixString(16).substring(2)}';
        final html = _buildHtml(widget.target, themeHex);
        await _controller.loadHtmlString(html, baseUrl: 'https://vidfast.vc');
      });
    }
  }

  @override
  void dispose() {
    _windowsController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isWindows) {
      return Scaffold(
        backgroundColor: const Color(0xFF050505),
        appBar: AppBar(
          backgroundColor: const Color(0xFF050505),
          title: const Text('Movie Watcher – Player'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
          actions: [
            IconButton(icon: const Icon(Icons.play_arrow), onPressed: () => _sendCommand('play')),
            IconButton(icon: const Icon(Icons.pause), onPressed: () => _sendCommand('pause')),
          ],
        ),
        body: _windowsController == null
            ? const Center(child: Text('Player konnte nicht geladen werden', style: TextStyle(color: Colors.white)))
            : win_webview.Webview(_windowsController!),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF050505),
      appBar: AppBar(
        backgroundColor: const Color(0xFF050505),
        foregroundColor: Colors.white,
        title: const Text('Player'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.play_arrow), onPressed: () => _sendCommand('play')),
          IconButton(icon: const Icon(Icons.pause), onPressed: () => _sendCommand('pause')),
          if (_currentPosition != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Center(child: Text(_currentPosition!, style: const TextStyle(fontSize: 11))),
            ),
        ],
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
