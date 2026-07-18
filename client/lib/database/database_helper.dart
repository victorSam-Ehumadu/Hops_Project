import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

class DatabaseHelper {
  static const _databaseName = "MeshNetwork.db";
  static const _databaseVersion = 2;   // upgraded

  static const table = 'messages';
  static const vibeTable = 'vibe_records';   // new

  // Columns for Mesh Routing (unchanged)
  static const columnId = 'id';
  static const columnMessage = 'message';
  static const columnSenderId = 'sender_id';
  static const columnIsForMe = 'is_for_me';
  static const columnNeedsRelay = 'needs_relay';
  static const columnTimestamp = 'timestamp';

  // Columns for Vibe Check records
  static const vibeColId = 'id';
  static const vibeColLocation = 'location_name';
  static const vibeColDeviceCount = 'device_count';
  static const vibeColTimestamp = 'timestamp';

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

    // Create vibe records table
    await db.execute('''
      CREATE TABLE $vibeTable (
        $vibeColId TEXT PRIMARY KEY,
        $vibeColLocation TEXT NOT NULL,
        $vibeColDeviceCount INTEGER NOT NULL,
        $vibeColTimestamp INTEGER NOT NULL
      )
    ''');
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE $vibeTable (
          $vibeColId TEXT PRIMARY KEY,
          $vibeColLocation TEXT NOT NULL,
          $vibeColDeviceCount INTEGER NOT NULL,
          $vibeColTimestamp INTEGER NOT NULL
        )
      ''');
    }
  }

  // Insert a new vibe record
  Future<int> insertVibeRecord(Map<String, dynamic> row) async {
    Database db = await instance.database;
    return await db.insert(vibeTable, row, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  // Get all vibe records, ordered by most recent first
  Future<List<Map<String, dynamic>>> getVibeRecords() async {
    Database db = await instance.database;
    return await db.query(
      vibeTable,
      orderBy: '$vibeColTimestamp DESC',
    );
  }

  // Delete a vibe record by ID
  Future<int> deleteVibeRecord(String id) async {
    Database db = await instance.database;
    return await db.delete(vibeTable, where: '$vibeColId = ?', whereArgs: [id]);
  }

  // ---------- Existing message methods (unchanged) ----------
  Future<int> insertMessage(Map<String, dynamic> row) async {
    Database db = await instance.database;
    return await db.insert(table, row, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Map<String, dynamic>>> getMessagesToRelay() async {
    Database db = await instance.database;
    return await db.query(
      table,
      where: '$columnNeedsRelay = ?',
      whereArgs: [1],
    );
  }

  Future<int> markAsRelayed(String uuid) async {
    Database db = await instance.database;
    return await db.update(
      table,
      {columnNeedsRelay: 0},
      where: '$columnId = ?',
      whereArgs: [uuid],
    );
  }
}