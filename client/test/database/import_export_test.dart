// Import of a Hops data export.
//
// Worth real coverage because this is the restore half of a backup, and
// every failure mode is quiet and expensive: duplicating a thread,
// silently restoring nothing, rolling a newer local row back to an older
// exported one, or throwing on an export taken under a different schema.
//
// Also the first test to touch database_helper at all. It was previously
// untestable because every path reaches the file through
// getApplicationDocumentsDirectory(), a platform channel — openInMemoryForTest
// bypasses that one call and nothing else, so these run against the real
// _onCreate schema rather than a hand-built approximation.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:client/database/database_helper.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.instance.close();
    await DatabaseHelper.instance.openInMemoryForTest();
  });

  Map<String, dynamic> exportWith({
    List<Map<String, dynamic>>? messages,
    List<Map<String, dynamic>>? tasks,
  }) =>
      <String, dynamic>{
        'app': 'Hops',
        'exported_at': DateTime.now().toIso8601String(),
        DatabaseHelper.table: messages ?? const [],
        DatabaseHelper.vibeTable: const [],
        DatabaseHelper.tasksTable: tasks ?? const [],
        DatabaseHelper.contactProfilesTable: const [],
      };

  Map<String, dynamic> message(String id,
          {String peer = 'victor', String text = 'hello', int ts = 1700000000000}) =>
      <String, dynamic>{
        DatabaseHelper.columnId: id,
        DatabaseHelper.columnMessage: text,
        DatabaseHelper.columnSenderId: peer,
        DatabaseHelper.columnIsForMe: 1,
        DatabaseHelper.columnNeedsRelay: 0,
        DatabaseHelper.columnTimestamp: ts,
        DatabaseHelper.columnPeerId: peer,
        DatabaseHelper.columnDelivered: 1,
      };

  group('rejects what is not a Hops export', () {
    test('a file with no app marker', () {
      expect(
        () => DatabaseHelper.instance
            .importAllData(<String, dynamic>{'messages': []}),
        throwsA(isA<FormatException>()),
      );
    });

    test('a file from some other app', () {
      expect(
        () => DatabaseHelper.instance
            .importAllData(<String, dynamic>{'app': 'SomethingElse'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('restoring', () {
    test('inserts rows and reports how many', () async {
      final r = await DatabaseHelper.instance
          .importAllData(exportWith(messages: [message('a'), message('b')]));
      expect(r[DatabaseHelper.table]![DatabaseHelper.importInserted], 2);
      expect(r[DatabaseHelper.table]![DatabaseHelper.importSkipped], 0);
      expect((await DatabaseHelper.instance.getMessagesForPeer('victor')).length,
          2);
    });

    test('is idempotent — the same file twice adds nothing', () async {
      final file = exportWith(messages: [message('a'), message('b')]);
      await DatabaseHelper.instance.importAllData(file);
      final second = await DatabaseHelper.instance.importAllData(file);
      expect(second[DatabaseHelper.table]![DatabaseHelper.importInserted], 0);
      expect(second[DatabaseHelper.table]![DatabaseHelper.importSkipped], 2);
      expect((await DatabaseHelper.instance.getMessagesForPeer('victor')).length,
          2);
    });

    test('never overwrites a row already here', () async {
      // The local copy is the fresher one by definition — it may carry a
      // read receipt or a delivered flag the export predates, and
      // replacing would quietly roll that back.
      await DatabaseHelper.instance
          .insertMessage(message('a', text: 'local version'));
      await DatabaseHelper.instance.importAllData(
          exportWith(messages: [message('a', text: 'from backup')]));
      final rows = await DatabaseHelper.instance.getMessagesForPeer('victor');
      expect(rows.single[DatabaseHelper.columnMessage], 'local version');
    });

    test('merges rather than replacing — existing rows survive', () async {
      await DatabaseHelper.instance.insertMessage(message('local-only'));
      await DatabaseHelper.instance
          .importAllData(exportWith(messages: [message('from-backup')]));
      final ids = (await DatabaseHelper.instance.getMessagesForPeer('victor'))
          .map((r) => r[DatabaseHelper.columnId])
          .toSet();
      expect(ids, {'local-only', 'from-backup'});
    });
  });

  group('schema drift', () {
    test('accepts an export that predates a column', () async {
      // read_at arrived in v11. An export taken at v10 has no such key and
      // must still import rather than throwing.
      final old = message('a')..remove(DatabaseHelper.columnReadAt);
      final r = await DatabaseHelper.instance
          .importAllData(exportWith(messages: [old]));
      expect(r[DatabaseHelper.table]![DatabaseHelper.importInserted], 1);
    });

    test('ignores a column this build has never heard of', () async {
      // An export from a FUTURE version. A blind insert would throw on the
      // unknown key and lose the whole file.
      final future = message('a')..['some_future_column'] = 'whatever';
      final r = await DatabaseHelper.instance
          .importAllData(exportWith(messages: [future]));
      expect(r[DatabaseHelper.table]![DatabaseHelper.importInserted], 1);
      final rows = await DatabaseHelper.instance.getMessagesForPeer('victor');
      expect(rows.single.containsKey('some_future_column'), isFalse);
    });
  });

  group('malformed input', () {
    test('one bad row does not abandon the rest of the file', () async {
      final r = await DatabaseHelper.instance.importAllData(exportWith(
        messages: [
          message('good-1'),
          <String, dynamic>{'nonsense': true},
          message('good-2'),
        ],
      ));
      expect(r[DatabaseHelper.table]![DatabaseHelper.importInserted], 2);
      expect(r[DatabaseHelper.table]![DatabaseHelper.importSkipped], 1);
    });

    test('a table key that is not a list is skipped, not fatal', () async {
      final file = exportWith(messages: [message('a')]);
      file[DatabaseHelper.tasksTable] = 'not a list';
      final r = await DatabaseHelper.instance.importAllData(file);
      expect(r[DatabaseHelper.table]![DatabaseHelper.importInserted], 1);
      expect(r[DatabaseHelper.tasksTable]![DatabaseHelper.importInserted], 0);
    });

    test('a table key that is absent entirely is fine', () async {
      final r = await DatabaseHelper.instance.importAllData(<String, dynamic>{
        'app': 'Hops',
        DatabaseHelper.table: [message('a')],
      });
      expect(r[DatabaseHelper.table]![DatabaseHelper.importInserted], 1);
    });

    test('an unrecognised table name in the file is ignored', () async {
      // The file is user-supplied; "whatever table the JSON claims" is not
      // something to hand to sqflite.
      final file = exportWith(messages: [message('a')]);
      file['sqlite_master'] = [
        <String, dynamic>{'x': 1}
      ];
      final r = await DatabaseHelper.instance.importAllData(file);
      expect(r.containsKey('sqlite_master'), isFalse);
    });
  });

  test('a round trip through export restores the same rows', () async {
    await DatabaseHelper.instance
        .insertMessage(message('a', text: 'one', ts: 1700000000001));
    await DatabaseHelper.instance
        .insertMessage(message('b', text: 'two', ts: 1700000000002));
    final exported = await DatabaseHelper.instance.exportAllData();

    // Wipe and reopen, as a reinstall would.
    await DatabaseHelper.instance.close();
    await DatabaseHelper.instance.openInMemoryForTest();
    expect(await DatabaseHelper.instance.getMessagesForPeer('victor'), isEmpty);

    await DatabaseHelper.instance.importAllData(exported);
    final rows = await DatabaseHelper.instance.getMessagesForPeer('victor');
    expect(rows.map((r) => r[DatabaseHelper.columnMessage]).toList(),
        ['one', 'two']);
  });
}
