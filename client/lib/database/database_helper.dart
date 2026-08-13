import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

class DatabaseHelper {
  static const _databaseName = "MeshNetwork.db";
  static const _databaseVersion = 8;

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
        $columnDelivered INTEGER NOT NULL DEFAULT 1
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
        $cpColRotatingSeed TEXT
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
  Future<void> upsertContactProfile(
    String username, {
    String? avatarPath,
    String? bio,
  }) async {
    Database db = await instance.database;
    await db.rawInsert('''
      INSERT INTO $contactProfilesTable ($cpColUsername, $cpColAvatarPath, $cpColBio, $cpColUpdatedAt)
      VALUES (?, ?, ?, ?)
      ON CONFLICT($cpColUsername) DO UPDATE SET
        $cpColAvatarPath = excluded.$cpColAvatarPath,
        $cpColBio = excluded.$cpColBio,
        $cpColUpdatedAt = excluded.$cpColUpdatedAt
    ''', [username, avatarPath, bio, DateTime.now().millisecondsSinceEpoch]);
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