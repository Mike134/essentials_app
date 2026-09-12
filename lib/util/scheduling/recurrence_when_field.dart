import 'package:flutter/material.dart';

import '../form_label_style.dart';
import 'recurrence_when.dart';

/// The contextual "When" editor for a [RecurringReminderFields] group's
/// `when` field -- what it shows depends entirely on the sibling
/// Timeframe field's *current* value, per Mike's own spec: daily/yearly
/// need nothing, weekly needs a weekday, monthly needs one of three real
/// patterns (day of month, last day of month, or a weekday position like
/// "2nd Tuesday"). See claude/essentials-v2-agenda-scheduling-design.md.
///
/// A controlled widget over the same shared [TextEditingController]
/// `GenericFormScreen` already keeps for every plain-text field (matching
/// `InlineOptionListEditor`/`ColorDefaultValueField`'s own convention) --
/// [controller]'s `.text` is the actual [RecurrenceWhenRule] JSON that
/// gets saved, kept in sync with this widget's own local UI state on every
/// change.
///
/// **Every possible pattern's fields are kept in local state at once**,
/// not just whichever one is currently active -- switching Timeframe away
/// from Weekly and back doesn't lose a previously-chosen weekday, since
/// this widget's `State` (and therefore its local fields) survives a
/// parent rebuild that only changes [timeframeKeyword] (same widget
/// position, `didUpdateWidget` not a fresh `initState`).
class RecurrenceWhenField extends StatefulWidget {
  const RecurrenceWhenField({required this.controller, required this.timeframeKeyword, super.key});

  final TextEditingController controller;

  /// The sibling Timeframe field's current resolved display text,
  /// lowercased (e.g. `"weekly"`) -- `null` if Timeframe has no selection
  /// yet, or its options haven't finished loading.
  final String? timeframeKeyword;

  @override
  State<RecurrenceWhenField> createState() => _RecurrenceWhenFieldState();
}

class _RecurrenceWhenFieldState extends State<RecurrenceWhenField> {
  static const _weekdayLabels = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  static const _nthLabels = {1: '1st', 2: '2nd', 3: '3rd', 4: '4th', -1: 'Last'};

  late int _weekday;
  late MonthlyPatternKind _monthlyKind;
  late int _dayOfMonth;
  late int _nth;
  late int _nthWeekday;

  @override
  void initState() {
    super.initState();
    final rule = RecurrenceWhenRule.decode(widget.controller.text);
    _weekday = (rule?.weekday != null && rule!.weekday! >= 1 && rule.weekday! <= 7)
        ? rule.weekday!
        : DateTime.now().weekday;
    _monthlyKind = rule?.monthlyKind ?? MonthlyPatternKind.dayOfMonth;
    _dayOfMonth = (rule?.dayOfMonth != null && rule!.dayOfMonth! >= 1 && rule.dayOfMonth! <= 31)
        ? rule.dayOfMonth!
        : 1;
    _nth = rule?.nth ?? 1;
    _nthWeekday = (rule?.nthWeekday != null && rule!.nthWeekday! >= 1 && rule.nthWeekday! <= 7)
        ? rule.nthWeekday!
        : 1;
    _writeCurrentRule();
  }

  @override
  void didUpdateWidget(covariant RecurrenceWhenField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.timeframeKeyword != widget.timeframeKeyword) {
      // Rewrite immediately (not just re-render) so a save made right
      // after switching Timeframe -- before touching "When" at all --
      // still writes a value matching the pattern that's now active,
      // never stale JSON left over from a different Timeframe.
      _writeCurrentRule();
    }
  }

  void _writeCurrentRule() {
    final keyword = (widget.timeframeKeyword ?? '').trim().toLowerCase();
    final text = switch (keyword) {
      'weekly' => RecurrenceWhenRule(weekday: _weekday).encode(),
      'monthly' => _monthlyRule().encode(),
      _ => '',
    };
    if (widget.controller.text != text) widget.controller.text = text;
  }

  RecurrenceWhenRule _monthlyRule() {
    switch (_monthlyKind) {
      case MonthlyPatternKind.dayOfMonth:
        return RecurrenceWhenRule(monthlyKind: _monthlyKind, dayOfMonth: _dayOfMonth);
      case MonthlyPatternKind.lastDay:
        return RecurrenceWhenRule(monthlyKind: _monthlyKind);
      case MonthlyPatternKind.nthWeekday:
        return RecurrenceWhenRule(monthlyKind: _monthlyKind, nth: _nth, nthWeekday: _nthWeekday);
    }
  }

  InputDecoration _decoration(BuildContext context, String label) => InputDecoration(
    labelText: label,
    floatingLabelBehavior: FloatingLabelBehavior.always,
    floatingLabelStyle: formLabelFloatingStyle(context),
  );

  @override
  Widget build(BuildContext context) {
    final keyword = (widget.timeframeKeyword ?? '').trim().toLowerCase();
    switch (keyword) {
      case 'weekly':
        return DropdownButtonFormField<int>(
          initialValue: _weekday,
          decoration: _decoration(context, 'When'),
          items: [
            for (var i = 1; i <= 7; i++) DropdownMenuItem(value: i, child: Text(_weekdayLabels[i - 1])),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _weekday = value;
              _writeCurrentRule();
            });
          },
        );
      case 'monthly':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<MonthlyPatternKind>(
              initialValue: _monthlyKind,
              decoration: _decoration(context, 'When'),
              items: const [
                DropdownMenuItem(value: MonthlyPatternKind.dayOfMonth, child: Text('Day of month')),
                DropdownMenuItem(value: MonthlyPatternKind.lastDay, child: Text('Last day of month')),
                DropdownMenuItem(value: MonthlyPatternKind.nthWeekday, child: Text('Weekday position')),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _monthlyKind = value;
                  _writeCurrentRule();
                });
              },
            ),
            if (_monthlyKind == MonthlyPatternKind.dayOfMonth)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: DropdownButtonFormField<int>(
                  initialValue: _dayOfMonth,
                  decoration: _decoration(context, 'Day of month'),
                  items: [for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text('$d'))],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _dayOfMonth = value;
                      _writeCurrentRule();
                    });
                  },
                ),
              ),
            if (_monthlyKind == MonthlyPatternKind.nthWeekday)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _nth,
                        decoration: _decoration(context, 'Occurrence'),
                        items: [
                          for (final n in [1, 2, 3, 4, -1])
                            DropdownMenuItem(value: n, child: Text(_nthLabels[n]!)),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _nth = value;
                            _writeCurrentRule();
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _nthWeekday,
                        decoration: _decoration(context, 'Weekday'),
                        items: [
                          for (var i = 1; i <= 7; i++)
                            DropdownMenuItem(value: i, child: Text(_weekdayLabels[i - 1])),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _nthWeekday = value;
                            _writeCurrentRule();
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      default:
        return InputDecorator(
          decoration: _decoration(context, 'When'),
          child: Text(
            keyword.isEmpty
                ? 'Set Timeframe first.'
                : 'Not needed for ${keyword[0].toUpperCase()}${keyword.substring(1)}.',
            style: TextStyle(color: Theme.of(context).disabledColor),
          ),
        );
    }
  }
}
