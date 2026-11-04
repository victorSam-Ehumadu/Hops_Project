// Parsing an RCP: read-receipt line.
//
// Worth its own tests because the output of parseReadReceiptIds goes
// straight into a SQL `IN` clause, and its input is a line of text read
// off a Bluetooth socket from another device. Nothing upstream of it has
// validated anything.
//
// The database side is scoped too (DatabaseHelper.markMessagesReadByPeer
// restricts to the peer's own thread, to rows we sent, and refuses to
// overwrite an existing timestamp) — but that is defence in depth, not a
// reason for this layer to be loose.
import 'package:flutter_test/flutter_test.dart';

import 'package:client/services/rfcomm_chat_service.dart';

void main() {
  const a = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
  const b = '7c9e6679-7425-40de-944b-e07fc1f90ae7';

  group('well-formed input', () {
    test('parses a single id', () {
      expect(RfcommChatService.parseReadReceiptIds('RCP:$a'), [a]);
    });

    test('parses several comma-separated ids', () {
      expect(RfcommChatService.parseReadReceiptIds('RCP:$a,$b'), [a, b]);
    });

    test('tolerates surrounding whitespace', () {
      // A real line may pick up spacing; that should not cost a receipt.
      expect(RfcommChatService.parseReadReceiptIds('RCP: $a , $b '), [a, b]);
    });
  });

  group('rejects anything that is not a message id', () {
    test('drops a SQL fragment', () {
      // The reason the shape check exists at all.
      expect(
        RfcommChatService.parseReadReceiptIds("RCP:' OR 1=1 --"),
        isEmpty,
      );
    });

    test('drops an id of the right length but the wrong shape', () {
      // 36 characters, so a length-only check would have let this through.
      final sameLength = 'z' * 36;
      expect(sameLength.length, 36);
      expect(RfcommChatService.parseReadReceiptIds('RCP:$sameLength'),
          isEmpty);
    });

    test('drops a truncated id', () {
      expect(RfcommChatService.parseReadReceiptIds('RCP:${a.substring(0, 20)}'),
          isEmpty);
    });

    test('keeps the valid ids and drops the rest from a mixed line', () {
      // Partial corruption must not discard the whole receipt, or one bad
      // entry would permanently block a batch from ever being acknowledged.
      expect(RfcommChatService.parseReadReceiptIds('RCP:$a,garbage,$b'),
          [a, b]);
    });

    test('an empty payload yields nothing', () {
      expect(RfcommChatService.parseReadReceiptIds('RCP:'), isEmpty);
      expect(RfcommChatService.parseReadReceiptIds('RCP:,,,'), isEmpty);
    });
  });

  group('prefix handling', () {
    test('ignores a line with a different prefix', () {
      // _handleLine dispatches on prefix, but this must not depend on
      // being called only for its own lines.
      expect(RfcommChatService.parseReadReceiptIds('MSG:$a'), isEmpty);
      expect(RfcommChatService.parseReadReceiptIds('DEL:$a'), isEmpty);
    });

    test('ignores an unprefixed line', () {
      expect(RfcommChatService.parseReadReceiptIds(a), isEmpty);
      expect(RfcommChatService.parseReadReceiptIds(''), isEmpty);
    });
  });
}
