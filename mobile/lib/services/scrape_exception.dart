/// 站点抓取/解析层的统一异常。
///
/// 原名 PhubException——却被所有站点适配器（phub/xvideos/mitao/huangguo/
/// generic）共用，导致其它适配器为这一个异常类型就 import 整个
/// phub_api.dart。独立成文件后，各适配器只依赖这个轻量文件。
/// [toString] 直接返回 message（与原行为一致，UI 里的 message 解析不变）。
class ScrapeException implements Exception {
  final String message;
  ScrapeException(this.message);

  @override
  String toString() => message;
}

/// 兼容别名：既有调用点（含 phub_api.dart 内部）仍可继续写
/// `PhubException(...)` / `is PhubException`，无需逐一改名。
typedef PhubException = ScrapeException;