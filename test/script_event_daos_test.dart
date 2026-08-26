// Essentials v2 Phase 5 build order step 5 -- ScriptDefinitionsDao/
// EventDefinitionsDao against the real essentials.db. Every row created
// here is cleaned up via addTearDown soft-deletes -- see the real leak
// this exact discipline was added to prevent (CLAUDE.md, this phase's
// step 4 write-up).
import 'package:essentials_app/db/event_definitions_dao.dart';
import 'package:essentials_app/db/script_definitions_dao.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final scripts = ScriptDefinitionsDao();
  final events = EventDefinitionsDao();
  final runTag = DateTime.now().microsecondsSinceEpoch;

  Future<int> createTestScript(String label, {String code = "notify('hi');"}) async {
    final id = await scripts.create(name: '$label $runTag', code: code);
    addTearDown(() => scripts.softDelete(id));
    return id;
  }

  Future<int> createTestBinding({
    required int scriptId,
    required String eventType,
    String? tableName,
    String? fieldName,
    String? scheduleConfig,
    bool enabled = true,
  }) async {
    final id = await events.create(
      scriptId: scriptId,
      eventType: eventType,
      tableName: tableName,
      fieldName: fieldName,
      scheduleConfig: scheduleConfig,
      enabled: enabled,
    );
    addTearDown(() => events.softDelete(id));
    return id;
  }

  test('create + loadAll round-trips a real script', () async {
    final id = await createTestScript('My Script', code: "notify('round trip');");
    final all = await scripts.loadAll();
    final found = all.firstWhere((s) => s.id == id);
    expect(found.code, "notify('round trip');");
  });

  test('update changes name/code/description in place', () async {
    final id = await createTestScript('Before Update');
    await scripts.update(id, name: 'After Update $runTag', code: "notify('updated');", description: 'desc');
    final all = await scripts.loadAll();
    final found = all.firstWhere((s) => s.id == id);
    expect(found.name, 'After Update $runTag');
    expect(found.code, "notify('updated');");
    expect(found.description, 'desc');
  });

  test('softDelete removes a script from loadAll', () async {
    final id = await createTestScript('To Delete');
    await scripts.softDelete(id);
    final all = await scripts.loadAll();
    expect(all.where((s) => s.id == id), isEmpty);
  });

  test('event bindings round-trip for a table and are found by loadForTable', () async {
    final scriptId = await createTestScript('Bound Script');
    final tableName = 'fake_table_$runTag';
    await createTestBinding(scriptId: scriptId, eventType: 'record_created', tableName: tableName);
    await createTestBinding(
      scriptId: scriptId,
      eventType: 'field_changed',
      tableName: tableName,
      fieldName: 'status',
    );

    final bindings = await events.loadForTable(tableName);
    expect(bindings, hasLength(2));
    expect(bindings.map((b) => b.eventType), containsAll(['record_created', 'field_changed']));
  });

  test('scheduled bindings (no table) are found by loadScheduled, not loadForTable', () async {
    final scriptId = await createTestScript('Scheduled Script');
    await createTestBinding(scriptId: scriptId, eventType: 'app_launch');

    final scheduled = await events.loadScheduled();
    expect(scheduled.where((b) => b.scriptId == scriptId), hasLength(1));
  });

  test('setEnabled toggles a binding without needing to recreate it', () async {
    final scriptId = await createTestScript('Toggle Script');
    final tableName = 'fake_table_toggle_$runTag';
    final bindingId = await createTestBinding(scriptId: scriptId, eventType: 'record_deleted', tableName: tableName, enabled: true);

    await events.setEnabled(bindingId, false);
    var bindings = await events.loadForTable(tableName);
    expect(bindings.single.enabled, isFalse);

    await events.setEnabled(bindingId, true);
    bindings = await events.loadForTable(tableName);
    expect(bindings.single.enabled, isTrue);
  });
}
