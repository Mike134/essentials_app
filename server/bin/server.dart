// essentials_app's crdt_sync coordinator -- the record-level sync hub for
// MIKE-CU. Not a general-purpose service; lives inside this repo so a
// protocol change here and its matching client-side change travel together
// in the same commit history. See CLAUDE.md "Syncing at the Record Level".
//
// Deliberately NOT using crdt_sync_server's listen() helper directly --
// that function hardcodes InternetAddress.loopbackIPv4, which would make
// this unreachable from any other device on the LAN. upgrade() is the same
// helper listen() calls internally per-connection, exposed so a real bind
// address can be used instead.

import 'dart:io';

import 'package:crdt_sync/crdt_sync_server.dart' as crdt_sync_server;
import 'package:sqlite_crdt/sqlite_crdt.dart';

const port = 1340;
const dbDir = r'C:\Databases\essentials_app\server';
const dbPath = r'C:\Databases\essentials_app\server\hub.db';

// Mirrors essentials_app's real schema.sql, table for table. The five
// entity tables (shipment, subscription, journal, orders, order_items) use
// `id INTEGER PRIMARY KEY DEFAULT (...)` here rather than schema.sql's
// current `id INTEGER UNIQUE NOT NULL DEFAULT (...)` -- confirmed in the
// "Syncing at the Record Level" Part A prototype that sqlite_crdt's merge
// needs a declared PRIMARY KEY to build its conflict-resolution target.
// Same generator expression either way (still non-AUTOINCREMENT, so the
// original cross-device collision-avoidance property is unchanged); this
// same fix needs to land in schema.sql and the real essentials.db in Part C
// so client and server schemas match exactly.
const schemaStatements = <String>[
  // sqflite_common_ffi's own internal table -- not part of this app's
  // design (schema.sql doesn't document it), but every real client has it
  // and the sync layer doesn't distinguish "business tables" from
  // anything else: it tries to merge whatever changesets a client sends,
  // for every table name it mentions. Without a structural counterpart
  // here, merging this table's changeset fails (found live, against the
  // real server, not assumed) -- `pragma_table_info` on a table the
  // server doesn't have at all returns zero rows same as "table exists
  // but has no PRIMARY KEY," so sqlite_crdt's merge() builds the same
  // broken `ON CONFLICT ()` either way. Shape matches the client's
  // (post-migrations/006 -- `locale` as a real PRIMARY KEY, not bare).
  '''
    CREATE TABLE android_metadata (
      locale TEXT PRIMARY KEY
    )
  ''',

  // ===================== LOOKUP / DOMAIN TABLES =====================
  '''
    CREATE TABLE domain (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      description TEXT,
      active      INTEGER NOT NULL DEFAULT 1,
      position    INTEGER,
      color       TEXT
    )
  ''',
  '''
    CREATE TABLE priority (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      description TEXT,
      active      INTEGER NOT NULL DEFAULT 1,
      position    INTEGER,
      color       TEXT
    )
  ''',
  '''
    CREATE TABLE gender (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      description TEXT,
      active      INTEGER NOT NULL DEFAULT 1,
      position    INTEGER,
      color       TEXT
    )
  ''',
  '''
    CREATE TABLE status (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      description TEXT,
      active      INTEGER NOT NULL DEFAULT 1,
      position    INTEGER,
      color       TEXT
    )
  ''',
  '''
    CREATE TABLE quality (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      description TEXT,
      active      INTEGER NOT NULL DEFAULT 1,
      position    INTEGER,
      color       TEXT
    )
  ''',
  '''
    CREATE TABLE condition (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      description TEXT,
      active      INTEGER NOT NULL DEFAULT 1,
      position    INTEGER,
      color       TEXT
    )
  ''',
  '''
    CREATE TABLE unit (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      name         TEXT NOT NULL UNIQUE,
      abbreviation TEXT,
      definition   TEXT,
      active       INTEGER NOT NULL DEFAULT 1,
      position     INTEGER,
      color        TEXT
    )
  ''',
  '''
    CREATE TABLE importance (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      description TEXT,
      active      INTEGER NOT NULL DEFAULT 1,
      position    INTEGER,
      color       TEXT
    )
  ''',
  '''
    CREATE TABLE disposition (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      description TEXT,
      active      INTEGER NOT NULL DEFAULT 1,
      position    INTEGER,
      color       TEXT
    )
  ''',
  '''
    CREATE TABLE time_frame (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      unit_id     INTEGER NOT NULL REFERENCES unit(id) ON DELETE RESTRICT,
      multiplier  INTEGER NOT NULL,
      description TEXT,
      active      INTEGER NOT NULL DEFAULT 1,
      position    INTEGER,
      color       TEXT
    )
  ''',
  'CREATE INDEX idx_time_frame_unit_id ON time_frame(unit_id)',
  '''
    CREATE TABLE class (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      description TEXT,
      active      INTEGER NOT NULL DEFAULT 1,
      position    INTEGER,
      color       TEXT
    )
  ''',
  '''
    CREATE TABLE category (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      class_id    INTEGER REFERENCES class(id) ON DELETE RESTRICT,
      description TEXT,
      active      INTEGER NOT NULL DEFAULT 1,
      position    INTEGER,
      color       TEXT
    )
  ''',
  'CREATE INDEX idx_category_class_id ON category(class_id)',
  '''
    CREATE TABLE account_type (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      name         TEXT NOT NULL UNIQUE,
      abbreviation TEXT,
      definition   TEXT,
      active       INTEGER NOT NULL DEFAULT 1,
      position     INTEGER,
      color        TEXT
    )
  ''',

  // ===================== ENTITY TABLES =====================
  '''
    CREATE TABLE account (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      name            TEXT NOT NULL UNIQUE,
      code            TEXT UNIQUE,
      institution     TEXT,
      account_type_id INTEGER REFERENCES account_type(id) ON DELETE RESTRICT,
      domain_id       INTEGER REFERENCES domain(id) ON DELETE RESTRICT,
      notes           TEXT,
      active          INTEGER NOT NULL DEFAULT 1,
      position        INTEGER,
      color           TEXT
    )
  ''',
  'CREATE INDEX idx_account_account_type_id ON account(account_type_id)',
  'CREATE INDEX idx_account_domain_id ON account(domain_id)',
  '''
    CREATE TABLE supplier (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      description TEXT,
      hyperlink   TEXT,
      active      INTEGER NOT NULL DEFAULT 1,
      position    INTEGER,
      color       TEXT
    )
  ''',
  '''
    CREATE TABLE shipper (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      description TEXT,
      hyperlink   TEXT,
      active      INTEGER NOT NULL DEFAULT 1,
      position    INTEGER,
      color       TEXT
    )
  ''',
  '''
    CREATE TABLE person (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      description TEXT,
      gender_id   INTEGER REFERENCES gender(id) ON DELETE RESTRICT,
      active      INTEGER NOT NULL DEFAULT 1,
      position    INTEGER,
      color       TEXT
    )
  ''',
  'CREATE INDEX idx_person_gender_id ON person(gender_id)',

  // ===================== TRANSACTIONAL / ONE-TO-MANY TABLES =====================
  // id scheme fix applied here -- see file header comment.
  '''
    CREATE TABLE shipment (
      id INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
      ),
      supplier_id    INTEGER REFERENCES supplier(id) ON DELETE RESTRICT,
      order_date     TEXT,
      due_date       TEXT,
      received_date  TEXT,
      domain_id      INTEGER REFERENCES domain(id) ON DELETE RESTRICT,
      order_id       TEXT,
      order_link     TEXT,
      shipper_id     INTEGER REFERENCES shipper(id) ON DELETE RESTRICT,
      tracking_id    TEXT,
      tracking_link  TEXT,
      items          TEXT,
      note           TEXT
    )
  ''',
  'CREATE INDEX idx_shipment_supplier_id ON shipment(supplier_id)',
  'CREATE INDEX idx_shipment_domain_id ON shipment(domain_id)',
  'CREATE INDEX idx_shipment_shipper_id ON shipment(shipper_id)',
  '''
    CREATE TABLE subscription (
      id INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
      ),
      name               TEXT NOT NULL UNIQUE,
      domain_id          INTEGER REFERENCES domain(id) ON DELETE RESTRICT,
      used_by_id         INTEGER REFERENCES person(id) ON DELETE RESTRICT,
      class_id           INTEGER REFERENCES class(id) ON DELETE RESTRICT,
      renewal_period_id  INTEGER REFERENCES time_frame(id) ON DELETE RESTRICT,
      cost               REAL,
      payment_method_id  INTEGER REFERENCES account(id) ON DELETE RESTRICT,
      importance_id      INTEGER REFERENCES importance(id) ON DELETE RESTRICT,
      disposition_id     INTEGER REFERENCES disposition(id) ON DELETE RESTRICT,
      start_date         TEXT,
      last_date          TEXT,
      link               TEXT,
      active             INTEGER NOT NULL DEFAULT 1,
      note               TEXT
    )
  ''',
  'CREATE INDEX idx_subscription_domain_id ON subscription(domain_id)',
  'CREATE INDEX idx_subscription_used_by_id ON subscription(used_by_id)',
  'CREATE INDEX idx_subscription_class_id ON subscription(class_id)',
  'CREATE INDEX idx_subscription_renewal_period_id ON subscription(renewal_period_id)',
  'CREATE INDEX idx_subscription_payment_method_id ON subscription(payment_method_id)',
  'CREATE INDEX idx_subscription_importance_id ON subscription(importance_id)',
  'CREATE INDEX idx_subscription_disposition_id ON subscription(disposition_id)',
  '''
    CREATE VIEW subscription_computed AS
    SELECT
        s.*,
        tf.multiplier AS renewal_multiplier_months,
        ROUND(s.cost * 12.0 / tf.multiplier, 2) AS yearly_cost,
        CASE
            WHEN s.start_date IS NULL OR tf.multiplier IS NULL THEN NULL
            WHEN date(s.start_date) > date('now') THEN s.start_date
            ELSE date(
                s.start_date,
                '+' || (
                    (
                        (
                            (CAST(strftime('%Y','now') AS INTEGER) - CAST(strftime('%Y', s.start_date) AS INTEGER)) * 12
                            + (CAST(strftime('%m','now') AS INTEGER) - CAST(strftime('%m', s.start_date) AS INTEGER))
                            - (CASE WHEN CAST(strftime('%d','now') AS INTEGER) < CAST(strftime('%d', s.start_date) AS INTEGER) THEN 1 ELSE 0 END)
                        ) / tf.multiplier + 1
                    ) * tf.multiplier
                ) || ' months'
            )
        END AS next_date
    FROM subscription s
    LEFT JOIN time_frame tf ON tf.id = s.renewal_period_id
  ''',
  '''
    CREATE TABLE journal (
      id INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
      ),
      entry_time  TEXT NOT NULL,
      entry       TEXT NOT NULL,
      tag         TEXT,
      status_id   INTEGER REFERENCES status(id) ON DELETE RESTRICT,
      location    TEXT,
      who_id      INTEGER REFERENCES person(id) ON DELETE RESTRICT,
      domain_id   INTEGER REFERENCES domain(id) ON DELETE RESTRICT,
      follow_up   TEXT,
      scheduled   INTEGER NOT NULL DEFAULT 0,
      link        TEXT,
      image       TEXT,
      file        TEXT,
      latitude    REAL,
      longitude   REAL,
      notes       TEXT
    )
  ''',
  'CREATE INDEX idx_journal_status_id ON journal(status_id)',
  'CREATE INDEX idx_journal_who_id ON journal(who_id)',
  'CREATE INDEX idx_journal_domain_id ON journal(domain_id)',

  // ===================== PER-DEVICE TABLE VIEW STATE =====================
  '''
    CREATE TABLE table_column_settings (
      table_name    TEXT NOT NULL,
      device_id     TEXT NOT NULL,
      column_name   TEXT NOT NULL,
      width         REAL,
      display_order INTEGER,
      visible       INTEGER NOT NULL DEFAULT 1,
      frozen        TEXT,
      wrap_text     INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (table_name, device_id, column_name)
    )
  ''',
  '''
    CREATE TABLE table_view_settings (
      table_name     TEXT NOT NULL,
      device_id      TEXT NOT NULL,
      sort_column    TEXT,
      sort_direction TEXT,
      filter_json    TEXT,
      PRIMARY KEY (table_name, device_id)
    )
  ''',

  // ===================== APP/DEVICE SETTINGS, FIELD METADATA, GROUPS =======
  '''
    CREATE TABLE app_settings (
      setting_key TEXT PRIMARY KEY,
      value       TEXT
    )
  ''',
  '''
    CREATE TABLE device_settings (
      device_id   TEXT NOT NULL,
      setting_key TEXT NOT NULL,
      value       TEXT,
      PRIMARY KEY (device_id, setting_key)
    )
  ''',
  '''
    CREATE TABLE field_metadata (
      table_name            TEXT NOT NULL,
      field_name             TEXT NOT NULL,
      display_label          TEXT,
      default_value           TEXT,
      lookup_display_column  TEXT,
      is_link                 INTEGER,
      PRIMARY KEY (table_name, field_name)
    )
  ''',
  '''
    CREATE TABLE table_group (
      table_name     TEXT PRIMARY KEY,
      group_name     TEXT NOT NULL,
      group_position INTEGER
    )
  ''',

  // ===================== ORDERS / ORDER_ITEMS ==============================
  '''
    CREATE TABLE orders (
      id INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
      ),
      order_number TEXT UNIQUE,
      supplier_id  INTEGER REFERENCES supplier(id) ON DELETE RESTRICT
    )
  ''',
  '''
    CREATE TABLE order_items (
      id INTEGER PRIMARY KEY DEFAULT (
        CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
        + (abs(random()) % 1000)
      ),
      order_id    INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
      description TEXT,
      cost        REAL
    )
  ''',
];

Future<void> createSchema(CrdtTableExecutor db, int version) async {
  for (final statement in schemaStatements) {
    await db.execute(statement);
  }
}

Future<void> main() async {
  Directory(dbDir).createSync(recursive: true);

  final crdt = await SqliteCrdt.open(dbPath, version: 1, onCreate: createSchema);
  await crdt.execute('PRAGMA foreign_keys = ON');
  print('Hub replica open: $dbPath');
  print('Hub node id: ${crdt.nodeId}');

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  print('Listening on 0.0.0.0:$port (reachable at 10.0.0.134:$port)');
  print('Press Ctrl+C to stop.');

  await for (final request in server) {
    try {
      await crdt_sync_server.upgrade(
        crdt,
        request,
        onConnect: (crdtSync, data) =>
            print('[connect] peer ${crdtSync.peerId}'),
        onDisconnect: (peerId, code, reason) =>
            print('[disconnect] peer $peerId (code=$code reason=$reason)'),
        onChangesetReceived: (nodeId, counts) =>
            print('[recv] from $nodeId: $counts'),
        onChangesetSent: (nodeId, counts) =>
            print('[send] to $nodeId: $counts'),
      );
    } catch (e) {
      print('[upgrade error] $e');
    }
  }
}
