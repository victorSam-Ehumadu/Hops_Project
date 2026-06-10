import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

class DatabaseHelper {
  static const _databaseName = "MeshNetwork.db";
  static const _databaseVersion = 1;

  static const table = 'messages';

  // Columns for Mesh Routing
  static const columnId = 'id'; // The UUID to prevent duplicates
  static const columnMessage = 'message';
  static const columnSenderId = 'sender_id';
  static const columnIsForMe = 'is_for_me'; // 1 for true, 0 for false
  static const columnNeedsRelay = 'needs_relay'; // 1 for true, 0 for false
  static const columnTimestamp = 'timestamp';

  // Make this a singleton class
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
    );
  }

  // Create the table
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
  }

  // Insert a new message (ignores duplicates)
  Future<int> insertMessage(Map<String, dynamic> row) async {
    Database db = await instance.database;
    return await db.insert(table, row, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
  // 1. THE FETCHER: Your team's Bluetooth code will call this to get data to send
  Future<List<Map<String, dynamic>>> getMessagesToRelay() async {
    Database db = await instance.database;

    // Query: SELECT * FROM messages WHERE needs_relay = 1
    return await db.query(
      table,
      where: '$columnNeedsRelay = ?',
      whereArgs: [1],
    );
  }

  // 2. THE UPDATER: Your team calls this AFTER they successfully broadcast the message
  Future<int> markAsRelayed(String uuid) async {
    Database db = await instance.database;

    // Update the row to set needs_relay to 0 (False)
    return await db.update(
      table,
      {columnNeedsRelay: 0},
      where: '$columnId = ?', // Find the exact message by its UUID
      whereArgs: [uuid],
    );
  }
}