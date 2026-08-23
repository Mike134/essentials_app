import 'package:url_launcher/url_launcher.dart';

/// Opens [raw] in the system default browser (never an in-app webview --
/// `LaunchMode.externalApplication` -- since these are read-only reference
/// links, not part of any in-app flow). Tolerates a scheme-less value like
/// `example.com` by assuming `https://`; returns false without throwing for
/// anything blank or unparseable, so callers can just fire-and-forget.
Future<bool> openLink(String? raw) async {
  final text = raw?.trim();
  if (text == null || text.isEmpty) return false;

  final hasScheme = Uri.tryParse(text)?.hasScheme ?? false;
  final uri = Uri.tryParse(hasScheme ? text : 'https://$text');
  if (uri == null) return false;

  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Opens [raw] the way a `link_file` field's value should be opened --
/// distinct from [openLink] because a bare local path (`C:\Databases\...`,
/// no scheme) is the expected common case here, not the exception:
/// [openLink] would wrongly prepend `https://` to it. A value that already
/// parses as a URL with a real scheme (`https://...`, `file://...`) is
/// opened as-is; anything else is treated as a plain filesystem path via
/// [Uri.file], which produces the correct `file://` URI on both Windows
/// and Android. Tolerates blank/unparseable input the same way [openLink]
/// does, for the same fire-and-forget reason.
Future<bool> openFileLink(String? raw) async {
  final text = raw?.trim();
  if (text == null || text.isEmpty) return false;

  final hasScheme = Uri.tryParse(text)?.hasScheme ?? false;
  final uri = hasScheme ? Uri.tryParse(text) : Uri.tryParse(Uri.file(text).toString());
  if (uri == null) return false;

  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
