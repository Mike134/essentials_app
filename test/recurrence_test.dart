// Proves the shared recurrence.dart primitives directly -- parseRecurrenceConfig,
// anchorAlignedSlotAtOrBefore, and missedOccurrenceCount -- pure Dart, no
// device or database involved, same style as next_due_time_test.dart.
// See claude/essentials-v2-recurring-schedule-design.md.
import 'dart:convert';

import 'package:essentials_app/util/scripting/recurrence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseRecurrenceConfig', () {
    test('valid minutes/hours/days/weeks all parse correctly', () {
      expect(parseRecurrenceConfig(jsonEncode({'interval': 10, 'unit': 'minutes'}))!.interval, const Duration(minutes: 10));
      expect(parseRecurrenceConfig(jsonEncode({'interval': 4, 'unit': 'hours'}))!.interval, const Duration(hours: 4));
      expect(parseRecurrenceConfig(jsonEncode({'interval': 3, 'unit': 'days'}))!.interval, const Duration(days: 3));
      expect(parseRecurrenceConfig(jsonEncode({'interval': 7, 'unit': 'weeks'}))!.interval, const Duration(days: 49));
    });

    test('anchor is parsed when present, null when absent', () {
      final withAnchor = parseRecurrenceConfig(
        jsonEncode({'interval': 4, 'unit': 'hours', 'anchor': '2026-09-05T10:20:00'}),
      );
      expect(withAnchor!.anchor, DateTime(2026, 9, 5, 10, 20));

      final withoutAnchor = parseRecurrenceConfig(jsonEncode({'interval': 4, 'unit': 'hours'}));
      expect(withoutAnchor!.anchor, isNull);
    });

    test('below the 5-minute floor is clamped up to exactly 5 minutes', () {
      expect(parseRecurrenceConfig(jsonEncode({'interval': 1, 'unit': 'minutes'}))!.interval, minRecurrenceInterval);
      expect(parseRecurrenceConfig(jsonEncode({'interval': 4, 'unit': 'minutes'}))!.interval, minRecurrenceInterval);
      // Right at the floor and above it are left alone.
      expect(parseRecurrenceConfig(jsonEncode({'interval': 5, 'unit': 'minutes'}))!.interval, const Duration(minutes: 5));
      expect(parseRecurrenceConfig(jsonEncode({'interval': 6, 'unit': 'minutes'}))!.interval, const Duration(minutes: 6));
    });

    test('null, malformed, non-object, missing/bad interval or unit, unrecognized unit -> null', () {
      expect(parseRecurrenceConfig(null), isNull);
      expect(parseRecurrenceConfig('not json'), isNull);
      expect(parseRecurrenceConfig(jsonEncode([1, 2, 3])), isNull);
      expect(parseRecurrenceConfig(jsonEncode({'unit': 'hours'})), isNull);
      expect(parseRecurrenceConfig(jsonEncode({'interval': 'garbage', 'unit': 'hours'})), isNull);
      expect(parseRecurrenceConfig(jsonEncode({'interval': 4})), isNull);
      expect(parseRecurrenceConfig(jsonEncode({'interval': 4, 'unit': 'fortnights'})), isNull);
    });

    test('a malformed anchor string is silently treated as unanchored, not a parse failure', () {
      final config = parseRecurrenceConfig(jsonEncode({'interval': 4, 'unit': 'hours', 'anchor': 'garbage'}));
      expect(config, isNotNull);
      expect(config!.anchor, isNull);
    });
  });

  group('anchorAlignedSlotAtOrBefore', () {
    final anchor = DateTime(2026, 9, 4, 8, 0);
    const interval = Duration(hours: 4);

    test('reference at or before the anchor returns the anchor itself', () {
      expect(anchorAlignedSlotAtOrBefore(anchor, interval, anchor), anchor);
      expect(anchorAlignedSlotAtOrBefore(anchor, interval, anchor.subtract(const Duration(hours: 1))), anchor);
    });

    test('reference partway through a slot returns that slot\'s start', () {
      expect(anchorAlignedSlotAtOrBefore(anchor, interval, DateTime(2026, 9, 4, 10, 0)), anchor);
      expect(anchorAlignedSlotAtOrBefore(anchor, interval, DateTime(2026, 9, 4, 11, 59)), anchor);
    });

    test('reference exactly on a later slot boundary returns that slot', () {
      expect(anchorAlignedSlotAtOrBefore(anchor, interval, DateTime(2026, 9, 4, 12, 0)), DateTime(2026, 9, 4, 12, 0));
    });

    test('reference many slots later returns the correct far slot', () {
      expect(anchorAlignedSlotAtOrBefore(anchor, interval, DateTime(2026, 9, 4, 20, 0)), DateTime(2026, 9, 4, 20, 0));
    });
  });

  group('missedOccurrenceCount', () {
    final anchor = DateTime(2026, 9, 4, 8, 0);
    const interval = Duration(hours: 4);

    test('normal progression (lastRun serviced the immediately preceding slot) -> 0', () {
      final lastRun = DateTime(2026, 9, 4, 8, 5); // serviced 08:00 slot
      final now = DateTime(2026, 9, 4, 12, 30); // in the 12:00 slot
      expect(missedOccurrenceCount(anchor, interval, lastRun, now), 0);
    });

    test('not yet due again (still within the slot lastRun already serviced) -> 0', () {
      final lastRun = DateTime(2026, 9, 4, 8, 5);
      final now = DateTime(2026, 9, 4, 10, 0); // still in the 08:00 slot
      expect(missedOccurrenceCount(anchor, interval, lastRun, now), 0);
    });

    test('one whole slot skipped -> 1', () {
      final lastRun = DateTime(2026, 9, 4, 8, 5); // serviced 08:00
      final now = DateTime(2026, 9, 4, 16, 30); // in the 16:00 slot -- 12:00 was skipped
      expect(missedOccurrenceCount(anchor, interval, lastRun, now), 1);
    });

    test('several slots skipped after a long gap -> the correct count', () {
      final lastRun = DateTime(2026, 9, 4, 8, 5); // serviced 08:00
      final now = DateTime(2026, 9, 4, 20, 30); // in the 20:00 slot -- 12:00 and 16:00 skipped
      expect(missedOccurrenceCount(anchor, interval, lastRun, now), 2);
    });
  });
}
