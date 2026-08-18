import 'package:flutter/foundation.dart';

/// 黄果封面诊断日志（环形缓冲）+ 重试信号。
/// 设置里的“隐藏 · 缩略图”按钮会把这里的内容复制到剪贴板。
class HgCoverLog {
  HgCoverLog._();

  static final List<String> _lines = [];
  static const int _limit = 400;

  /// 触发所有失败封面重新加载（页面控件自行监听）。
  static final ValueNotifier<int> retrySignal = ValueNotifier<int>(0);

  static void add(String line) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    _lines.add('[$ts] $line');
    if (_lines.length > _limit) _lines.removeAt(0);
    debugPrint('HGW $line');
  }

  static String dump() {
    final s = _lines.join('\n');
    return s.isEmpty ? '(暂无缩略图日志)' : s;
  }

  static void requestRetry() => retrySignal.value++;
}