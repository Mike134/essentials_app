// One-off: restore books.rating for a specific row via the real sqlite_crdt
// API (never raw SQL against a crdt-managed table) after an incidental test
// edit during a real-device checkbox/rating verification pass.
//
//   dart run tool/fix_books_rating.dart --path <db> --id <book_id> --rating <n>
import 'dart:io';

import 'package:sqlite_crdt/sqlite_crdt.dart';

Future<void> main(List<String> args) async {
  final path = _argValue(args, '--path');
  final id = int.tryParse(_argValue(args, '--id') ?? '');
  final rating = _argValue(args, '--rating');

  if (path == null || id == null || rating == null) {
    print('Usage: dart run tool/fix_books_rating.dart --path <db> --id <book_id> --rating <n>');
    exitCode = 64;
    return;
  }
  if (!await File(path).exists()) {
    print('REFUSING: no file at $path');
    exitCode = 1;
    return;
  }

  print('Opening $path ...');
  final crdt = await SqliteCrdt.open(path);
  try {
    final before = await crdt.query('SELECT id, title, rating FROM books WHERE id = ?1', [id]);
    print('Before: $before');
    await crdt.execute('UPDATE books SET rating = ?1 WHERE id = ?2', [rating, id]);
    final after = await crdt.query('SELECT id, title, rating FROM books WHERE id = ?1', [id]);
    print('After: $after');
  } finally {
    await crdt.close();
  }
}

String? _argValue(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index == -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}
