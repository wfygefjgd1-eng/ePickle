import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/feed_list_cache.dart';
import '../services/player_chrome.dart';
import 'search_screen.dart';
import 'video_feed_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;

  /// One key per kind so tab switch disposes the old feed (players freed)
  /// and creates the new one; list/index restored from [FeedListCache].
  final _hotKey = GlobalKey<VideoFeedScreenState>();
  final _asianKey = GlobalKey<VideoFeedScreenState>();
  final _xKey = GlobalKey<VideoFeedScreenState>();
  final _zhongKey = GlobalKey<VideoFeedScreenState>();

  static const _feedKinds = [
    VideoFeedKind.hot,
    VideoFeedKind.asian,
    VideoFeedKind.x,
    VideoFeedKind.zhong,
  ];

  List<GlobalKey<VideoFeedScreenState>> get _feedKeys =>
      [_hotKey, _asianKey, _xKey, _zhongKey];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final key in _feedKeys) {
      final state = key.currentState;
      if (state != null) {
        state.stopPlaybackImmediately();
      }
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _index >= _feedKinds.length) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          ModalRoute.of(context)?.isCurrent == true &&
          _index < _feedKinds.length) {
        _feedKeys[_index].currentState?.startPlaying();
      }
    });
  }

  void _onTabSelected(int i) {
    if (i == _index) return;
    final chrome = context.read<PlayerChrome>();
    if (chrome.immersive) {
      // ignore: unawaited_futures
      chrome.exitFullscreen();
    }
    // Leaving feed: widget unmounted → dispose → FeedListCache keeps list.
    _feedKeys[_index].currentState?.stopPlaybackImmediately();
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    final immersive = context.select<PlayerChrome, bool>((c) => c.immersive);
    final onFeed = _index >= 0 && _index < _feedKinds.length;
    final onSearch = _index == _feedKinds.length;

    return Scaffold(
      extendBody: true,
      // Only one feed mounted at a time. Search stays mounted (offstage) so
      // results/query survive tab switches without 4× feed memory.
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (onFeed)
            VideoFeedScreen(
              key: _feedKeys[_index],
              kind: _feedKinds[_index],
              autoStart: true,
            ),
          Offstage(
            offstage: !onSearch,
            child: TickerMode(
              enabled: onSearch,
              child: const SearchScreen(key: ValueKey('search')),
            ),
          ),
        ],
      ),
      bottomNavigationBar: immersive
          ? null
          : RepaintBoundary(
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: _buildNavigationBar(),
                ),
              ),
            ),
    );
  }

  Widget _buildNavigationBar() {
    return NavigationBar(
      selectedIndex: _index,
      onDestinationSelected: _onTabSelected,
      backgroundColor: Colors.black.withValues(alpha: 0.28),
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      indicatorColor: const Color(0x33FF6B35),
      destinations: [
        _buildNavigationDestination(
          0,
          Icons.local_fire_department_outlined,
          Icons.local_fire_department,
        ),
        _buildNavigationDestination(
          1,
          Icons.public_outlined,
          Icons.public,
        ),
        _buildNavigationDestination(
          2,
          Icons.cancel_outlined,
          Icons.cancel,
        ),
        _buildNavigationDestination(
          3,
          Icons.category_outlined,
          Icons.category,
        ),
        const NavigationDestination(
          icon: Icon(Icons.search),
          selectedIcon: Icon(Icons.search, color: Color(0xFFFF6B35)),
          label: '',
        ),
      ],
    );
  }

  NavigationDestination _buildNavigationDestination(
    int index,
    IconData icon,
    IconData selectedIcon,
  ) {
    return NavigationDestination(
      icon: GestureDetector(
        onLongPress: () => _showShareDialog(index),
        child: Icon(icon),
      ),
      selectedIcon: GestureDetector(
        onLongPress: () => _showShareDialog(index),
        child: Icon(selectedIcon, color: const Color(0xFFFF6B35)),
      ),
      label: '',
    );
  }

  String? _shareUrlForTab(int tabIndex) {
    if (tabIndex < 0 || tabIndex >= _feedKinds.length) return null;
    // Active feed: live player index.
    if (tabIndex == _index) {
      final live = _feedKeys[tabIndex].currentState?.getCurrentVideoUrl();
      if (live != null && live.isNotEmpty) return live;
    }
    // Inactive / just-left: list snapshot from FeedListCache.
    final snap = FeedListCache.take(_feedKinds[tabIndex].name);
    if (snap == null || snap.items.isEmpty) return null;
    final i = snap.index.clamp(0, snap.items.length - 1);
    return snap.items[i].url;
  }

  void _showShareDialog(int tabIndex) {
    if (tabIndex >= _feedKinds.length) return;

    final shareUrl = _shareUrlForTab(tabIndex);
    if (shareUrl == null || shareUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('当前没有可分享的视频'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '分享视频',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2A2A),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    shareUrl,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
                const SizedBox(height: 16),
                _ShareOption(
                  icon: Icons.ios_share,
                  label: '分享到其他 APP',
                  onTap: () {
                    Navigator.pop(ctx);
                    SharePlus.instance.share(
                      ShareParams(text: shareUrl, subject: '分享视频链接'),
                    );
                  },
                ),
                const SizedBox(height: 8),
                _ShareOption(
                  icon: Icons.content_copy,
                  label: '复制链接',
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: shareUrl));
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('链接已复制到剪贴板'),
                        duration: Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                _ShareOption(
                  icon: Icons.open_in_browser,
                  label: '在浏览器中打开',
                  onTap: () async {
                    Navigator.pop(ctx);
                    final uri = Uri.parse(shareUrl);
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri,
                          mode: LaunchMode.externalApplication);
                    } else {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('无法打开浏览器'),
                            duration: Duration(seconds: 2),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    }
                  },
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: const Color(0xFF2A2A2A),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    '取消',
                    style: TextStyle(color: Colors.white70, fontSize: 15),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ShareOption extends StatelessWidget {
  const _ShareOption({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF2A2A2A),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          child: Row(
            children: [
              Icon(icon, color: Colors.white, size: 22),
              const SizedBox(width: 12),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
