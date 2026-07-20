import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

class DatabaseHelper {
  static const _databaseName = "MeshNetwork.db";
  static const _databaseVersion = 4;

  static const table = 'messages';
  static const vibeTable = 'vibe_records';
  static const tasksTable = 'tasks';

  // Columns for Mesh Routing
  static const columnId = 'id';
  static const columnMessage = 'message';
  static const columnSenderId = 'sender_id';
  static const columnIsForMe = 'is_for_me';
  static const columnNeedsRelay = 'needs_relay';
  static const columnTimestamp = 'timestamp';

  // Columns for Vibe Records
  static const vibeColId = 'id';
  static const vibeColLocation = 'location_name';
  static const vibeColDeviceCount = 'device_count';
  static const vibeColTimestamp = 'timestamp';

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

  _initDatabase() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = join(documentsDirectory.path, _databaseName);

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
        $columnTimestamp INTEGER NOT NULL
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

  Future<List<Map<String, dynamic>>> getMessagesToRelay() async {
    Database db = await instance.database;
    return await db.query(table, where: '$columnNeedsRelay = ?', whereArgs: [1]);
  }

  Future<int> markAsRelayed(String uuid) async {
    Database db = await instance.database;
    return await db.update(table, {columnNeedsRelay: 0},
        where: '$columnId = ?', whereArgs: [uuid]);
  }
}