// The offline assistant's knowledge base — the data, and whether the
// keyword scorer actually routes a plausible question to the right entry.
//
// HopsEngine had no coverage at all, which is why the knowledge base drifted
// out of step with the app: entries described a "Community Chat" students
// could post in (it is Community Alerts now, admin-only and read-only),
// claimed there was no in-app flare button, and listed Vibe Check venues
// that were renamed. Nothing failed, because nothing checked.
//
// askBunny() reads the asset through rootBundle, which flutter_test serves
// from pubspec's declared assets — so these run against the REAL
// assets/data/hops_knowledge.json, not a fixture. That is the point: a typo
// in the shipped file fails here.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:client/services/hops_engine.dart';

void main() {
  // rootBundle needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Map<String, dynamic>> raw;

  setUpAll(() async {
    final text =
        await rootBundle.loadString('assets/data/hops_knowledge.json');
    raw = (json.decode(text) as List<dynamic>)
        .cast<Map<String, dynamic>>();
  });

  group('the shipped file is well formed', () {
    test('every entry has keywords and at least one answer', () {
      for (var i = 0; i < raw.length; i++) {
        final e = raw[i];
        final kws = (e['keywords'] as List<dynamic>?) ?? const [];
        expect(kws, isNotEmpty, reason: 'entry $i has no keywords');
        final one = e['response'];
        final many = e['responses'] as List<dynamic>?;
        expect(one != null || (many != null && many.isNotEmpty), isTrue,
            reason: 'entry $i has no response');
        // An entry the loader would silently drop is worse than a missing
        // one: the topic looks covered in the file and is not in the app.
        if (many != null) {
          for (final r in many) {
            expect(r.toString().trim(), isNotEmpty,
                reason: 'entry $i has a blank rotating answer');
          }
        }
      }
    });

    test('no keyword is claimed by two entries', () {
      // Scoring is `words*10 + length` per keyword and the highest total
      // wins, so a keyword on two entries makes which answer you get depend
      // on the other keywords around it — effectively arbitrary.
      final owners = <String, List<int>>{};
      for (var i = 0; i < raw.length; i++) {
        for (final k in (raw[i]['keywords'] as List<dynamic>)) {
          owners.putIfAbsent(k.toString().toLowerCase().trim(), () => []).add(i);
        }
      }
      final shared = owners.entries.where((e) => e.value.length > 1).toList();
      expect(shared, isEmpty,
          reason: 'shared keywords: '
              '${shared.map((e) => '"${e.key}" -> ${e.value}').join(', ')}');
    });

    test('the engine loads every entry', () async {
      await HopsEngine.instance.init();
      expect(HopsEngine.instance.knowledgeEntryCount, raw.length,
          reason: 'The loader dropped entries — it discards any with no '
              'keywords or no usable answer.');
    });
  });

  group('a plausible question reaches the right entry', () {
    // Phrased as a user would type, not as the keywords read.
    const cases = <String, List<String>>{
      'what is study bunny': ['STUDY BUNNY'],
      'how do i find someone to study with': ['STUDY BUNNY'],
      'i lost my wallet': ['LOST & FOUND'],
      'how do i send an emergency flare': ['EMERGENCY FLARE'],
      'how do i raise a flare': ['EMERGENCY FLARE'],
      'what is community alerts': ['COMMUNITY ALERTS'],
      'is my chat private': ["WHAT'S ACTUALLY PROTECTED"],
      'can i be tracked': ["WHAT'S ANONYMOUS"],
      'why do i need wifi': ['1:1 CHAT'],
      'how do i export my data': ['EXPORT MY DATA'],
      'how do i change my profile picture': ['YOUR PICTURE'],
      'why is my phone called something weird': ['BLUETOOTH NAME'],
      'does my phone send other peoples alerts': ["OTHER PEOPLE'S ALERTS"],
      'what can i buy in the shop': ['HOPS SHOP'],
      'how do i stop being watched': ['ENDING A WATCH'],
      'what data do you collect': ['WHAT HOPS KEEPS'],
      'how do i make myself visible': ['DISCOVERABLE MODE'],
      'can you read my messages out loud': ['READING THINGS ALOUD'],
      'what games are there': ['GAMES'],
    };

    for (final entry in cases.entries) {
      test('"${entry.key}"', () async {
        final answer = await HopsEngine.instance.askBunny(entry.key);
        for (final expected in entry.value) {
          expect(answer, contains(expected),
              reason: 'Asked "${entry.key}" and got:\n$answer');
        }
      });
    }
  });

  group('first aid still wins over anything that merely sounds like it', () {
    // The scorer was rewritten once because substring matching sent "you're
    // cute" to bleeding-wound first aid. These are the ones that must not
    // regress now that there are 12 more entries competing.
    test('a real burn question gets burn advice', () async {
      final a = await HopsEngine.instance.askBunny('i burned my hand');
      expect(a.toLowerCase(), contains('cool'));
    });

    test('"you are cute" does NOT get first aid', () async {
      final a = await HopsEngine.instance.askBunny('you are cute');
      expect(a.toLowerCase(), isNot(contains('bleeding')));
    });

    test('"why is it so slow" does NOT get the battery tip', () async {
      final a = await HopsEngine.instance.askBunny('why is it so slow');
      expect(a.toLowerCase(), isNot(contains('battery saver')));
    });
  });

  group('rotating answers', () {
    test('jokes offer more than one, and all are non-empty', () {
      final jokes = raw.firstWhere(
          (e) => (e['keywords'] as List).contains('joke'));
      final many = jokes['responses'] as List<dynamic>?;
      expect(many, isNotNull,
          reason: 'The joke entry should rotate — a single fixed joke means '
              '"tell me another" returns the same one forever.');
      expect(many!.length, greaterThanOrEqualTo(5));
      for (final j in many) {
        expect(j.toString().trim(), isNotEmpty);
      }
    });

    test('asking for a joke repeatedly is not always the same answer',
        () async {
      // Random, so this is probabilistic — but with a dozen jokes, 25 draws
      // landing on one answer every time is about 1 in 10^26.
      final seen = <String>{};
      for (var i = 0; i < 25; i++) {
        seen.add(await HopsEngine.instance.askBunny('tell me a joke'));
      }
      expect(seen.length, greaterThan(1),
          reason: 'Rotation is not happening — pick() may be ignoring the '
              'extra responses.');
    });
  });
}
