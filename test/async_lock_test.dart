// Proves AsyncLock's one real guarantee -- calls through the same lock
// instance never execute concurrently -- which is what MigrationService
// .schemaLock actually depends on to fix the real server crash documented
// in CLAUDE.md ("Incident: the sync server crash-looped for real"): a
// SqlCrdt.getChangeset() call racing MigrationService.applyPending()'s own
// DDL on the same isolate's event loop. Pure Dart, no database involved --
// this only needs to prove the concurrency primitive itself is correct.
import 'package:essentials_app/db/migration_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('two calls through the same lock never run concurrently', () async {
    final lock = AsyncLock();
    var running = 0;
    var maxConcurrent = 0;
    final order = <int>[];

    Future<void> task(int id) => lock.synchronized(() async {
      running++;
      maxConcurrent = maxConcurrent < running ? running : maxConcurrent;
      // Yields control mid-"critical section" -- if the lock didn't
      // actually serialize callers, this is exactly where a second call
      // would slip in and overlap.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      order.add(id);
      running--;
    });

    await Future.wait([task(1), task(2), task(3)]);

    expect(maxConcurrent, 1, reason: 'no two calls should ever run inside the lock at the same time');
    expect(order, [1, 2, 3], reason: 'calls issued together should still run in the order they were made');
  });

  test('an exception inside the locked action still releases the lock for the next caller', () async {
    final lock = AsyncLock();

    await expectLater(
      lock.synchronized(() async => throw StateError('boom')),
      throwsA(isA<StateError>()),
    );

    // If the lock were left held after the throw, this would hang forever
    // -- the test's own timeout is the real assertion here.
    final result = await lock.synchronized(() async => 'still works');
    expect(result, 'still works');
  });

  test('a lock instance only serializes calls made through itself, not unrelated code', () async {
    final lockA = AsyncLock();
    final lockB = AsyncLock();
    var bothRunning = 0;
    var sawOverlap = false;

    Future<void> onA() => lockA.synchronized(() async {
      bothRunning++;
      if (bothRunning > 1) sawOverlap = true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      bothRunning--;
    });
    Future<void> onB() => lockB.synchronized(() async {
      bothRunning++;
      if (bothRunning > 1) sawOverlap = true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      bothRunning--;
    });

    await Future.wait([onA(), onB()]);

    expect(sawOverlap, isTrue, reason: 'two different lock instances must not serialize each other');
  });
}
