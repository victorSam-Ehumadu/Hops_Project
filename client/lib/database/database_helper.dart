import 'dart:convert';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

class DatabaseHelper {
  static const _databaseName = "MeshNetwork.db";
  static const _databaseVersion = 11;

  static const table = 'messages';
  static const vibeTable = 'vibe_records';
  static const tasksTable = 'tasks';
  static const contactProfilesTable = 'contact_profiles';

  // Columns for Mesh Routing
  static const columnId = 'id';
  static const columnMessage = 'message';
  static const columnSenderId = 'sender_id';
  static const columnIsForMe = 'is_for_me';
  static const columnNeedsRelay = 'needs_relay';
  static const columnTimestamp = 'timestamp';
  // The *other* party in a 1:1 conversation, regardless of message
  // direction. sender_id alone can't scope a thread (an outgoing row's
  // sender_id is always *my* username, not the recipient's), which used to
  // make every conversation show every message you'd ever sent to anyone.
  static const columnPeerId = 'peer_id';
  // 1 once an outgoing message has actually been handed to the transport
  // successfully; 0 while it's waiting to be (re)sent. Meaningless for
  // inbound rows — they only exist because they already arrived, so they're
  // always written as delivered. Defaults to 1 so pre-existing rows from
  // before this column existed don't retroactively show as pending.
  static const columnDelivered = 'delivered';
  // When the PEER confirmed reading an outgoing message, as epoch ms.
  // Null means not yet read — which is also every inbound row (there is
  // nothing to report back to ourselves) and every row that predates this
  // column.
  //
  // A nullable timestamp rather than a second boolean: the three states a
  // message can be in are already ordered (pending -> delivered -> read),
  // so two independent flags could represent "read but not delivered",
  // which is not a thing. It also means the read *time* is available for
  // free if it is ever wanted.
  static const columnReadAt = 'read_at';

  // Columns for Vibe Records
  static const vibeColId = 'id';
  static const vibeColLocation = 'location_name';
  static const vibeColDeviceCount = 'device_count';
  static const vibeColTimestamp = 'timestamp';

  // Columns for Contact Profiles — a peer's avatar/bio, learned only by
  // direct device-to-device exchange the first time you actually chat
  // with them (see HopsChatService.sendProfile). Nothing in this app ever
  // uploads this anywhere; it's a purely local cache of what that peer's
  // device told yours.
  static const cpColUsername = 'username';
  static const cpColAvatarPath = 'avatar_path';
  static const cpColBio = 'bio';
  static const cpColUpdatedAt = 'updated_at';
  // This contact's rotating-ID seed (base64), learned the same way as
  // avatar/bio — direct exchange over the first chat session — and used to
  // resolve their ever-changing "HPS:<token>" presence beacon back to a
  // name. Stored separately from avatar/bio's upsert (see
  // upsertContactRotatingSeed) so updating one never clobbers the other.
  static const cpColRotatingSeed = 'rotating_seed';
  // This contact's classic-Bluetooth MAC address, learned the first time
  // an RFCOMM chat with them actually connects (see rfcomm_chat_service.dart
  // /chat_terminal.dart) — lets a future chat with the same contact skip
  // both classic-BT discovery and (on the hosting side) the intrusive
  // "make this device discoverable" system dialog, connecting directly
  // instead. Same separate-upsert reasoning as rotating_seed above.
  static const cpColRfcommMac = 'rfcomm_mac';
  // This contact's "thinking" status (see edit_identity_screen.dart) —
  // learned the same way as bio, riding the same profile-exchange payload
  // (hops_chat_service.dart's sendProfile, type 0x02), so it's kept in the
  // same upsertContactProfile call as bio rather than a separate one.
  static const cpColThinking = 'thinking';

  // Columns for Tasks
  static const taskColId = 'id';
  static const taskColTitle = 'title';
  static const taskColDescription = 'description';
  static const taskColDueDate = 'due_date';
  static const taskColStartTime = 'start_time';
  static const taskColEndTime = 'end_time';
  static const taskColCompleted = 'completed';
  static const taskColCreatedAt = 'created_at';

  DatabaseHelper._privateConstructor();
  static final DatabaseHelper instance = DatabaseHelper._privateConstructor();

  static Database? _database;
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  // Must be called before deleting the underlying db file (e.g. on
  // "Destroy Identity") — otherwise the file gets unlinked while this
  // singleton still holds an open handle to it, and every DB call made
  // afterward in the same app session keeps talking to the stale handle
  // instead of the freshly-created file a new sign-up expects.
  Future<void> close() async {
    final db = _database;
    _database = null;
    await db?.close();
  }

  /// Opens a throwaway in-memory database with the real schema.
  ///
  /// Test seam. Everything else here reaches the file through
  /// resolveDatabasePath(), which calls getApplicationDocumentsDirectory()
  /// — a platform channel, and the reason this class had no tests at all
  /// (see CLAUDE.md). This bypasses that one call and nothing else: the
  /// schema comes from the same _onCreate, so a test exercises the real
  /// tables and constraints rather than a hand-built approximation.
  ///
  /// Requires sqflite_common_ffi to be installed as the factory, exactly
  /// as main.dart already does on desktop.
  @visibleForTesting
  Future<Database> openInMemoryForTest() async {
    _database = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: _databaseVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    return _database!;
  }

  // Single source of truth for where the db file actually lives —
  // account_management_screen.dart's log-out/delete-account wipe used to
  // independently reconstruct this path via sqflite's getDatabasesPath(),
  // which is a *different* directory than the one _initDatabase() below
  // actually opens (getApplicationDocumentsDirectory()). On Android those
  // are two genuinely different folders, so the "delete the database on
  // sign-out" step was silently deleting a file that never existed, while
  // the real one — every message, task, and vibe record — survived
  // untouched into whatever account signed in next on the same device.
  // Anything that needs this path should call this instead of
  // reconstructing it by hand.
  static Future<String> resolveDatabasePath() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    return join(documentsDirectory.path, _databaseName);
  }

  _initDatabase() async {
    final path = await resolveDatabasePath();

    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $table (
        $columnId TEXT PRIMARY KEY,
        $columnMessage TEXT NOT NULL,
        $columnSenderId TEXT NOT NULL,
        $columnIsForMe INTEGER NOT NULL,
        $columnNeedsRelay INTEGER NOT NULL,
        $columnTimestamp INTEGER NOT NULL,
        $columnPeerId TEXT,
        $columnDelivered INTEGER NOT NULL DEFAULT 1,
        $columnReadAt INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE $vibeTable (
        $vibeColId TEXT PRIMARY KEY,
        $vibeColLocation TEXT NOT NULL,
        $vibeColDeviceCount INTEGER NOT NULL,
        $vibeColTimestamp INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $tasksTable (
        $taskColId TEXT PRIMARY KEY,
        $taskColTitle TEXT NOT NULL,
        $taskColDescription TEXT,
        $taskColDueDate INTEGER,
        $taskColStartTime INTEGER,
        $taskColEndTime INTEGER,
        $taskColCompleted INTEGER NOT NULL DEFAULT 0,
        $taskColCreatedAt INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $contactProfilesTable (
        $cpColUsername TEXT PRIMARY KEY,
        $cpColAvatarPath TEXT,
        $cpColBio TEXT,
        $cpColUpdatedAt INTEGER NOT NULL,
        $cpColRotatingSeed TEXT,
        $cpColRfcommMac TEXT,
        $cpColThinking TEXT
      )
    ''');
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $vibeTable (
          $vibeColId TEXT PRIMARY KEY,
          $vibeColLocation TEXT NOT NULL,
          $vibeColDeviceCount INTEGER NOT NULL,
          $vibeColTimestamp INTEGER NOT NULL
        )
      ''');
    }
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $tasksTable (
          $taskColId TEXT PRIMARY KEY,
          $taskColTitle TEXT NOT NULL,
          $taskColDueDate INTEGER,
          $taskColCompleted INTEGER NOT NULL DEFAULT 0,
          $taskColCreatedAt INTEGER NOT NULL
        )
      ''');
    }
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE $tasksTable ADD COLUMN $taskColDescription TEXT');
      await db.execute('ALTER TABLE $tasksTable ADD COLUMN $taskColStartTime INTEGER');
      await db.execute('ALTER TABLE $tasksTable ADD COLUMN $taskColEndTime INTEGER');
    }
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE $table ADD COLUMN $columnPeerId TEXT');
    }
    if (oldVersion < 6) {
      await db.execute('ALTER TABLE $table ADD COLUMN $columnDelivered INTEGER NOT NULL DEFAULT 1');
    }
    if (oldVersion < 7) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $contactProfilesTable (
          $cpColUsername TEXT PRIMARY KEY,
          $cpColAvatarPath TEXT,
          $cpColBio TEXT,
          $cpColUpdatedAt INTEGER NOT NULL
        )
      ''');
    }
    if (oldVersion < 8) {
      await db.execute('ALTER TABLE $contactProfilesTable ADD COLUMN $cpColRotatingSeed TEXT');
    }
    if (oldVersion < 9) {
      await db.execute('ALTER TABLE $contactProfilesTable ADD COLUMN $cpColRfcommMac TEXT');
    }
    if (oldVersion < 10) {
      await db.execute('ALTER TABLE $contactProfilesTable ADD COLUMN $cpColThinking TEXT');
    }
    if (oldVersion < 11) {
      // Nullable with no default, so every existing message reads as
      // "not read" rather than being retroactively claimed as read.
      await db.execute('ALTER TABLE $table ADD COLUMN $columnReadAt INTEGER');
    }
  }

  // ---------- Read receipts ----------

  /// Marks outgoing messages as read by the peer.
  ///
  /// Called when an RCP: receipt arrives (see rfcomm_chat_service.dart).
  /// Ids come off the wire from the peer, so this is deliberately narrow
  /// about what it will touch:
  ///
  ///   * scoped to [peerUsername], so a receipt from one contact cannot
  ///     mark a conversation with somebody else as read;
  ///   * only rows we SENT (is_for_me = 0) — a peer has no business
  ///     reporting on messages they sent us;
  ///   * never overwrites an existing read_at, so a replayed receipt
  ///     cannot move the timestamp later.
  ///
  /// Returns how many rows actually changed, so the caller can skip a
  /// pointless UI rebuild on a duplicate receipt.
  Future<int> markMessagesReadByPeer(
      String peerUsername, List<String> ids) async {
    if (ids.isEmpty) return 0;
    final db = await instance.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    return await db.rawUpdate(
      'UPDATE $table SET $columnReadAt = ? '
      'WHERE $columnId IN ($placeholders) '
      'AND $columnPeerId = ? AND $columnIsForMe = 0 AND $columnReadAt IS NULL',
      [DateTime.now().millisecondsSinceEpoch, ...ids, peerUsername],
    );
  }

  /// Ids of messages this contact sent us that we have not yet reported
  /// reading. Drives what gets put in the next RCP: receipt.
  ///
  /// Tracked by writing read_at on INBOUND rows too. That field means
  /// something different on each side — "when the peer read my message"
  /// outgoing, "when I read theirs, and therefore no longer need to tell
  /// them" inbound — which is worth being explicit about, because the two
  /// meanings share one column.
  Future<List<String>> unacknowledgedIncomingMessageIds(
      String peerUsername) async {
    final db = await instance.database;
    final rows = await db.query(
      table,
      columns: [columnId],
      where: '$columnPeerId = ? AND $columnIsForMe = 1 AND $columnReadAt IS NULL',
      whereArgs: [peerUsername],
    );
    return rows.map((r) => r[columnId] as String).toList();
  }

  /// Records that we have read (and reported reading) these inbound
  /// messages, so the same receipt is not sent again on every rebuild.
  Future<void> markIncomingAcknowledged(
      String peerUsername, List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await instance.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE $table SET $columnReadAt = ? '
      'WHERE $columnId IN ($placeholders) '
      'AND $columnPeerId = ? AND $columnIsForMe = 1',
      [DateTime.now().millisecondsSinceEpoch, ...ids, peerUsername],
    );
  }

  // ---------- Vibe Records ----------
  Future<int> insertVibeRecord(Map<String, dynamic> row) async {
    Database db = await instance.database;
    return await db.insert(vibeTable, row, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Map<String, dynamic>>> getVibeRecords() async {
    Database db = await instance.database;
    return await db.query(vibeTable, orderBy: '$vibeColTimestamp DESC');
  }

  Future<int> deleteVibeRecord(String id) async {
    Database db = await instance.database;
    return await db.delete(vibeTable, where: '$vibeColId = ?', whereArgs: [id]);
  }

  // ---------- Tasks ----------
  Future<int> insertTask(Map<String, dynamic> row) async {
    Database db = await instance.database;
    return await db.insert(tasksTable, row, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Map<String, dynamic>>> getTasks({DateTime? date}) async {
    Database db = await instance.database;
    if (date != null) {
      final startOfDay = DateTime(date.year, date.month, date.day).millisecondsSinceEpoch;
      final endOfDay = DateTime(date.year, date.month, date.day, 23, 59, 59).millisecondsSinceEpoch;
      return await db.query(
        tasksTable,
        where: '$taskColDueDate BETWEEN ? AND ?',
        whereArgs: [startOfDay, endOfDay],
        orderBy: '$taskColStartTime ASC, $taskColDueDate ASC',
      );
    }
    return await db.query(tasksTable, orderBy: '$taskColDueDate ASC, $taskColStartTime ASC');
  }

  Future<List<Map<String, dynamic>>> getTasksForMonth(DateTime month) async {
    final start = DateTime(month.year, month.month, 1).millisecondsSinceEpoch;
    final end = DateTime(month.year, month.month + 1, 0, 23, 59, 59).millisecondsSinceEpoch;
    final db = await instance.database;
    return await db.query(tasksTable,
        where: '$taskColDueDate BETWEEN ? AND ?',
        whereArgs: [start, end],
        orderBy: '$taskColDueDate ASC');
  }

  Future<int> updateTask(String id, Map<String, dynamic> values) async {
    Database db = await instance.database;
    return await db.update(tasksTable, values, where: '$taskColId = ?', whereArgs: [id]);
  }

  Future<int> deleteTask(String id) async {
    Database db = await instance.database;
    return await db.delete(tasksTable, where: '$taskColId = ?', whereArgs: [id]);
  }

  // ---------- Full local export ----------
  /// Every row this device has stored, across every table — backs Account
  /// Management's "Export My Data". This app has no cloud copy of any of
  /// this by design (see CLAUDE.md's offline-first architecture), so this
  /// is the one way to get a copy that survives something happening to
  /// THIS specific phone — a wipe, a factory reset, moving to a new
  /// device — beyond whatever Android's own Auto Backup already covers.
  /// Table names double as the JSON keys so the exported file is
  /// self-describing without needing a separate schema doc next to it.
  Future<Map<String, dynamic>> exportAllData() async {
    final db = await database;
    return {
      'app': 'Hops',
      'exported_at': DateTime.now().toIso8601String(),
      table: await db.query(table),
      vibeTable: await db.query(vibeTable),
      tasksTable: await db.query(tasksTable),
      contactProfilesTable: await db.query(contactProfilesTable),
    };
  }

  /// Result of an import: how many rows went in and how many were skipped,
  /// per table.
  ///
  /// Reported rather than swallowed because "imported successfully" with no
  /// numbers is indistinguishable from importing nothing — which is exactly
  /// what happens if the file is from a different app, or every row was
  /// already present.
  static const String importInserted = 'inserted';
  static const String importSkipped = 'skipped';

  /// Restores rows from a file produced by [exportAllData].
  ///
  /// MERGES, never replaces. Nothing already on this device is deleted, so
  /// an import cannot lose data the way a restore-over-the-top would — and
  /// running the same file twice is a no-op rather than a duplication,
  /// because every table here has a real primary key and conflicts are
  /// ignored rather than replaced.
  ///
  /// Ignored, not replaced, specifically: a row already on this device may
  /// carry state the export predates — a read receipt, a delivered flag, a
  /// contact's newer avatar — and replacing it would quietly roll that
  /// back. The local copy is the fresher one by definition.
  ///
  /// ONLY COLUMNS THE CURRENT SCHEMA HAS are written. An export taken
  /// before `read_at` existed (schema v10) has no such key, and an export
  /// from a future version may carry keys this build has never heard of;
  /// either would make a blind insert throw. The intersection is taken per
  /// table, read from the live table rather than from a hardcoded list, so
  /// this keeps working across schema bumps without being touched.
  ///
  /// Runs in a single transaction: a malformed row partway through leaves
  /// the database exactly as it was rather than half-populated.
  ///
  /// Throws [FormatException] if the file is not a Hops export.
  Future<Map<String, Map<String, int>>> importAllData(
      Map<String, dynamic> data) async {
    if (data['app'] != 'Hops') {
      throw const FormatException(
          'That file is not a Hops data export.');
    }

    final db = await database;
    final result = <String, Map<String, int>>{};

    // Only these four. A key in the file that is not one of them is
    // ignored rather than trusted — the file is user-supplied, and
    // "whatever table name the JSON claims" is not something to hand to
    // sqflite.
    const importable = [table, vibeTable, tasksTable, contactProfilesTable];

    await db.transaction((txn) async {
      for (final name in importable) {
        var inserted = 0, skipped = 0;
        final rows = data[name];
        if (rows is! List) {
          result[name] = {importInserted: 0, importSkipped: 0};
          continue;
        }

        // The columns this build's table actually has.
        final info = await txn.rawQuery('PRAGMA table_info($name)');
        final live = {for (final c in info) c['name'] as String};

        for (final raw in rows) {
          if (raw is! Map) {
            skipped++;
            continue;
          }
          final row = <String, Object?>{};
          raw.forEach((k, v) {
            if (k is String && live.contains(k)) row[k] = v;
          });
          if (row.isEmpty) {
            skipped++;
            continue;
          }
          try {
            final id = await txn.insert(name, row,
                conflictAlgorithm: ConflictAlgorithm.ignore);
            // insert() returns 0 when the conflict clause dropped the row.
            if (id == 0) {
              skipped++;
            } else {
              inserted++;
            }
          } catch (_) {
            // One bad row (a missing NOT NULL, a wrong type) must not
            // abandon the rest of the file.
            skipped++;
          }
        }
        result[name] = {importInserted: inserted, importSkipped: skipped};
      }
    });

    return result;
  }

  // ---------- Messages ----------
  Future<int> insertMessage(Map<String, dynamic> row) async {
    Database db = await instance.database;
    return await db.insert(table, row, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  // Full 1:1 thread with a peer, both directions — every row written for a
  // conversation (inbound or outbound) must carry columnPeerId = the other
  // party's username, or it won't show up here.
  Future<List<Map<String, dynamic>>> getMessagesForPeer(String peerId) async {
    Database db = await instance.database;
    return await db.query(
      table,
      where: '$columnPeerId = ?',
      whereArgs: [peerId],
      orderBy: '$columnTimestamp ASC',
    );
  }

  Future<int> markMessageDelivered(String id) async {
    Database db = await instance.database;
    return await db.update(table, {columnDelivered: 1},
        where: '$columnId = ?', whereArgs: [id]);
  }

  // "Delete my message" (chat_terminal.dart) — removes the row from THIS
  // device's own copy of the thread. chat_terminal.dart's
  // _confirmDeleteMessage also best-effort notifies the peer over RFCOMM
  // (RfcommChatService.sendDeleteMessage) so their matching row gets
  // deleted here too, on their device, when they call this same function
  // in response — but only while a live connection to them exists at the
  // moment of deleting. Over an often-disconnected P2P transport with no
  // server relay, a delete requested while the peer is unreachable can't
  // be queued or retried, so it stays local-only in that case.
  Future<int> deleteMessage(String id) async {
    Database db = await instance.database;
    return await db.delete(table, where: '$columnId = ?', whereArgs: [id]);
  }

  // Messages I sent to this peer that never got confirmed as delivered —
  // used to retry-send once a connection to them is (re)established.
  Future<List<Map<String, dynamic>>> getUndeliveredMessagesForPeer(
      String peerId, String myUsername) async {
    Database db = await instance.database;
    return await db.query(
      table,
      where: '$columnPeerId = ? AND $columnSenderId = ? AND $columnDelivered = 0',
      whereArgs: [peerId, myUsername],
      orderBy: '$columnTimestamp ASC',
    );
  }

  Future<int> deleteConversationWithPeer(String peerId) async {
    Database db = await instance.database;
    return await db.delete(
      table,
      // OR sender_id covers rows written by the older pairing-log flow,
      // which predates columnPeerId and never set it.
      where: '$columnPeerId = ? OR $columnSenderId = ?',
      whereArgs: [peerId, peerId],
    );
  }

  Future<List<Map<String, dynamic>>> getMessagesToRelay() async {
    Database db = await instance.database;
    return await db.query(table, where: '$columnNeedsRelay = ?', whereArgs: [1]);
  }

  Future<int> markAsRelayed(String uuid) async {
    Database db = await instance.database;
    return await db.update(table, {columnNeedsRelay: 0},
        where: '$columnId = ?', whereArgs: [uuid]);
  }

  // ---------- Contact Profiles ----------
  // Raw upsert (INSERT ... ON CONFLICT DO UPDATE) rather than
  // ConflictAlgorithm.replace — replace deletes and re-inserts the whole
  // row, which would silently null out rotating_seed (set by a completely
  // separate call, upsertContactRotatingSeed below) every time the bio or
  // avatar gets refreshed, and vice versa.
  //
  // Each column is coalesced for the SAME reason, one level down. A null
  // argument here means "I don't know this field", not "erase it", and
  // this is reached from one place only: a peer's profile arriving over
  // RFCOMM. That payload carries whatever the peer happened to have set,
  // so a peer with a bio but no avatar used to null out an avatar this
  // device had already received and stored from them earlier — the
  // contact's picture simply vanished, with nothing to explain it.
  //
  // The trade: a peer cannot CLEAR a field this way any more, only change
  // it. For a cached copy of someone else's profile that is the right side
  // to err on — a stale picture beats a missing one, and the next exchange
  // with an actual value overwrites it.
  Future<void> upsertContactProfile(
    String username, {
    String? avatarPath,
    String? bio,
    String? thinking,
  }) async {
    Database db = await instance.database;
    await db.rawInsert('''
      INSERT INTO $contactProfilesTable ($cpColUsername, $cpColAvatarPath, $cpColBio, $cpColThinking, $cpColUpdatedAt)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT($cpColUsername) DO UPDATE SET
        $cpColAvatarPath = coalesce(excluded.$cpColAvatarPath, $cpColAvatarPath),
        $cpColBio = coalesce(excluded.$cpColBio, $cpColBio),
        $cpColThinking = coalesce(excluded.$cpColThinking, $cpColThinking),
        $cpColUpdatedAt = excluded.$cpColUpdatedAt
    ''', [username, avatarPath, bio, thinking, DateTime.now().millisecondsSinceEpoch]);
  }

  // Learned the same way as avatar/bio — see hops_chat_service.dart's
  // payload type 0x03 — and kept separate for the reason noted above.
  Future<void> upsertContactRotatingSeed(String username, String seedBase64) async {
    Database db = await instance.database;
    await db.rawInsert('''
      INSERT INTO $contactProfilesTable ($cpColUsername, $cpColRotatingSeed, $cpColUpdatedAt)
      VALUES (?, ?, ?)
      ON CONFLICT($cpColUsername) DO UPDATE SET
        $cpColRotatingSeed = excluded.$cpColRotatingSeed,
        $cpColUpdatedAt = excluded.$cpColUpdatedAt
    ''', [username, seedBase64, DateTime.now().millisecondsSinceEpoch]);
  }

  // Learned the same way as rotating_seed — see RfcommChatService's
  // onMacLearned. Kept separate from the other upserts for the same
  // don't-clobber-unrelated-fields reason.
  Future<void> upsertContactMacAddress(String username, String macAddress) async {
    Database db = await instance.database;
    await db.rawInsert('''
      INSERT INTO $contactProfilesTable ($cpColUsername, $cpColRfcommMac, $cpColUpdatedAt)
      VALUES (?, ?, ?)
      ON CONFLICT($cpColUsername) DO UPDATE SET
        $cpColRfcommMac = excluded.$cpColRfcommMac,
        $cpColUpdatedAt = excluded.$cpColUpdatedAt
    ''', [username, macAddress, DateTime.now().millisecondsSinceEpoch]);
  }

  // Every known contact's rotating-ID seed, decoded and ready to test
  // against an observed beacon token — used by Radar to resolve
  // "HPS:<token>" back to a name. Contacts with no cached seed yet (never
  // chatted) are simply absent, same bounded limitation as avatar/bio.
  Future<Map<String, List<int>>> getAllContactRotatingSeeds() async {
    Database db = await instance.database;
    final rows = await db.query(
      contactProfilesTable,
      columns: [cpColUsername, cpColRotatingSeed],
      where: '$cpColRotatingSeed IS NOT NULL',
    );
    final result = <String, List<int>>{};
    for (final row in rows) {
      final b64 = row[cpColRotatingSeed] as String?;
      if (b64 == null) continue;
      try {
        result[row[cpColUsername] as String] = base64Decode(b64);
      } catch (_) {
        // Corrupt/legacy value — skip rather than crash resolution for
        // every other contact.
      }
    }
    return result;
  }

  Future<Map<String, dynamic>?> getContactProfile(String username) async {
    Database db = await instance.database;
    final rows = await db.query(
      contactProfilesTable,
      where: '$cpColUsername = ?',
      whereArgs: [username],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  // Keyed by username, for the contacts list to look up avatars in bulk
  // instead of one query per row.
  Future<Map<String, Map<String, dynamic>>> getAllContactProfiles() async {
    Database db = await instance.database;
    final rows = await db.query(contactProfilesTable);
    return {for (final row in rows) row[cpColUsername] as String: row};
  }

  Future<int> deleteContactProfile(String username) async {
    Database db = await instance.database;
    return await db.delete(
      contactProfilesTable,
      where: '$cpColUsername = ?',
      whereArgs: [username],
    );
  }
}