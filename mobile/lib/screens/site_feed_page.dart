import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_settings.dart';
import '../services/player_chrome.dart';
import '../services/source_catalog.dart';
import '../widgets/mirror_picker.dart';
import 'site_tag_directory_page.dart';
import 'video_feed_screen.dart';

/// Secondary page: bottom tabs (site sections) + search tab + back.
class SiteFeedPage extends StatefulWidget {
  const SiteFeedPage({super.key, required this.site});

  final SiteDef site;

  @override
  State<SiteFeedPage> createState() => _SiteFeedPageState();
}

class _SiteFeedPageState extends State<SiteFeedPage>
    with WidgetsBindingObserver {
  int _index = 0;
  final List<GlobalKey<VideoFeedScreenState>> _keys = [];

  /// The four direct feeds; the fifth destination is the tag directory.
  List<SiteTag> get _contentTabs {
    final t = widget.site.tags;
    if (t.isEmpty) return const [];
    return t.length > 4 ? t.sublist(0, 4) : List<SiteTag>.from(t);
  }

  int get _tagIndex => _contentTabs.length;

  int get _destinationCount => _contentTabs.length + 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ensureKeys();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _keys.isNotEmpty) {
        _keys[0].currentState?.startPlaying();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAllFeedsImmediately();
    super.dispose();
  }

  void _stopAllFeedsImmediately({bool leavingScreen = true}) {
    for (final key in _keys) {
      final state = key.currentState;
      if (state != null) {
        state.stopPlaybackImmediately(leavingScreen: leavingScreen);
      }
    }
  }

  Future<void> _exitToHome() async {
    _stopAllFeedsImmediately();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _index >= _keys.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          ModalRoute.of(context)?.isCurrent == true &&
          _index < _keys.length) {
        _keys[_index].currentState?.startPlaying();
      }
    });
  }

  void _ensureKeys() {
    final n = _contentTabs.length;
    while (_keys.length < n) {
      _keys.add(GlobalKey<VideoFeedScreenState>());
    }
    while (_keys.length > n) {
      _keys.removeLast();
    }
  }

  VideoFeedKind _kindAt(int i) {
    final tabs = _contentTabs;
    if (tabs.isEmpty) return VideoFeedKind.hot;
    return tabs[i.clamp(0, tabs.length - 1)].feedKind ?? VideoFeedKind.hot;
  }

  void _onTabSelected(int i) {
    if (i == _index) return;
    final chrome = context.read<PlayerChrome>();
    if (chrome.immersive) {
      // ignore: unawaited_futures
      chrome.exitFullscreen();
    }

    // Leaving content tab → pause players
    if (_index < _keys.length) {
      for (final k in _keys) {
        final state = k.currentState;
        if (state != null) {
          state.stopPlaybackImmediately(leavingScreen: false);
        }
      }
    }

    setState(() => _index = i);

    // Entering content tab → start play
    if (i < _keys.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _index != i) return;
        _keys[i].currentState?.startPlaying();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    _ensureKeys();
    final site = widget.site;
    final tabs = _contentTabs;
    final immersive = context.select<PlayerChrome, bool>((c) => c.immersive);
    final showSiteBackButton =
        defaultTargetPlatform != TargetPlatform.iOS ||
        context.select<AppSettings, bool>((s) => s.showSiteBackButton);

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        _stopAllFeedsImmediately();
        if (!didPop) {
          unawaited(_exitToHome());
        }
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      extendBody: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (tabs.isEmpty)
            const Center(
              child: Text('无标签', style: TextStyle(color: Colors.white54)),
            )
          else if (_index == _tagIndex)
            SiteTagDirectoryPage(key: ValueKey('tags_${site.id}'), site: site)
          else
            IndexedStack(
              index: _index.clamp(0, tabs.length - 1),
              sizing: StackFit.expand,
              children: [
                for (var i = 0; i < tabs.length; i++)
                  VideoFeedScreen(
                    key: _keys[i],
                    kind: _kindAt(i),
                    site: site,
                    tagId: tabs[i].id,
                    autoStart: false,
                  ),
              ],
            ),
          if (!immersive && showSiteBackButton)
            Positioned(
              left: 4,
              top: 0,
              child: SafeArea(
                child: Material(
                  color: Colors.black45,
                  shape: const CircleBorder(),
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: _exitToHome,
                    tooltip: '返回',
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: immersive || tabs.isEmpty
          ? null
          : RepaintBoundary(
              child: ClipRect(
                child: BackdropFilter(
                  // Smaller blur radius = much cheaper per-frame re-sampling
                  // while the feed scrolls under the bar (same glass look).
                  filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                  child: NavigationBar(
                    selectedIndex: _index.clamp(0, _destinationCount - 1),
                    onDestinationSelected: _onTabSelected,
                    backgroundColor: Colors.black.withValues(alpha: 0.28),
                    surfaceTintColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    elevation: 0,
                    indicatorColor: const Color(0x33FF6B35),
                    labelBehavior:
                        NavigationDestinationLabelBehavior.alwaysHide,
                    destinations: [
                      for (var ti = 0; ti < tabs.length; ti++)
                        if (ti == 0)
                          // LONG-PRESS the first tab ("热") to switch this
                          // site's mirror domain for the rest of the session.
                          GestureDetector(
                            onLongPress: () =>
                                unawaited(showMirrorPickerSheet(context, site)),
                            child: NavigationDestination(
                              icon: Icon(tabs[ti].icon),
                              selectedIcon: Icon(
                                tabs[ti].iconSelected,
                                color: const Color(0xFFFF6B35),
                              ),
                              label: tabs[ti].label,
                            ),
                          )
                        else
                          NavigationDestination(
                            icon: Icon(tabs[ti].icon),
                            selectedIcon: Icon(
                              tabs[ti].iconSelected,
                              color: const Color(0xFFFF6B35),
                            ),
                            label: tabs[ti].label,
                          ),
                      const NavigationDestination(
                        icon: Icon(Icons.sell_outlined),
                        selectedIcon: Icon(
                          Icons.sell,
                          color: Color(0xFFFF6B35),
                        ),
                        label: '\u6807\u7b7e',
                      ),
                    ],
                  ),
                ),
              ),
            ),
      ),
    );
  }
}
