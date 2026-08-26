import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Real OS-level notifications for a script's `notify()` call when
/// there's no foreground `SnackBar` to show it in -- Essentials v2 Phase
/// 5 build order step 7's background firing is the first, and so far
/// only, caller (see `EventDispatchService.dispatchAndApplyEffects`'s own
/// doc comment for why the *foreground* path stays a `SnackBar` instead
/// of also going through this: a script the user just triggered by
/// saving a form doesn't need an OS notification competing for
/// attention with the screen already in front of them).
///
/// A thin singleton wrapper, not a new DI-style service class -- there's
/// exactly one real use (posting a plain text notification), and every
/// call site already reaches it as `ScriptNotifications.instance`, same
/// shape as `ThemeController.instance`/`FieldFormatRegistry.instance`
/// elsewhere in this app.
class ScriptNotifications {
  ScriptNotifications._();
  static final ScriptNotifications instance = ScriptNotifications._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  int _nextId = 0;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    // Android's default launcher icon -- this app has never bundled a
    // dedicated notification icon, and `flutter_local_notifications`
    // requires *some* valid drawable resource name here; `@mipmap/ic_launcher`
    // always exists in a Flutter-generated Android project.
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(settings: settings);
    _initialized = true;
  }

  /// Shows [message] as a real notification. Each call gets a fresh id
  /// (not a fixed one) so multiple scheduled scripts firing in the same
  /// background run each get their own notification rather than
  /// overwriting one another -- the same "don't silently drop a second
  /// simultaneous effect" instinct `EventDispatchService
  /// .dispatchAndApplyEffects` already applies to its own `SnackBar`
  /// loop.
  Future<void> show(String message) async {
    await _ensureInitialized();
    const androidDetails = AndroidNotificationDetails(
      'scheduled_scripts',
      'Scheduled scripts',
      channelDescription: 'Notifications from scripts run on a schedule, in the background.',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    const details = NotificationDetails(android: androidDetails);
    await _plugin.show(id: _nextId++, title: 'Essentials', body: message, notificationDetails: details);
  }
}
