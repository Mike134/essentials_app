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
