// The hand-painted statistics chart.
//
// Covered because the painter does its own layout arithmetic — a reserved
// y-axis gutter, top headroom for the peak label, per-bar slot widths and
// a "will this number fit" check — and every one of those is a division or
// a negative dimension waiting to happen. A painter that throws takes the
// whole admin screen down with a red error box, so the edge cases are
// worth pinning even though the visual result is not assertable here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:client/views/admin/admin_statistics_screen.dart';

/// Paints onto a real canvas at [size] and fails if anything throws.
Future<void> _paint(WidgetTester tester, List<int> values, Size size) async {
  await tester.pumpWidget(MaterialApp(
    home: Center(
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: CustomPaint(
          painter: BarChartPainter(
            values: values,
            barColor: Colors.teal,
            axisColor: Colors.black12,
            textColor: Colors.black54,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    ),
  ));
  await tester.pump();
  expect(tester.takeException(), isNull);
}

/// Same as [_paint] but with x-axis labels, which reserve a strip under the
/// axis and move the baseline up off the canvas bottom.
Future<void> _paintLabelled(
  WidgetTester tester,
  List<int> values,
  List<String> labels,
  Size size,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Center(
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: CustomPaint(
          painter: BarChartPainter(
            values: values,
            labels: labels,
            barColor: Colors.teal,
            axisColor: Colors.black12,
            textColor: Colors.black54,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    ),
  ));
  await tester.pump();
  expect(tester.takeException(), isNull);
}

void main() {
  const phone = Size(320, 150);

  group('does not throw on', () {
    testWidgets('an empty series', (t) => _paint(t, const [], phone));

    testWidgets('an all-zero series', (t) async {
      // maxValue must floor at 1 or this divides by zero — and must not
      // draw full-height bars for nothing either.
      await _paint(t, const [0, 0, 0, 0], phone);
    });

    testWidgets('a single bucket', (t) => _paint(t, const [5], phone));

    testWidgets('a peak of 1', (t) async {
      // The half-height gridline would read "0" at this peak, which is
      // worse than no label, so it is suppressed below 2.
      await _paint(t, const [1, 0, 1], phone);
    });

    testWidgets('30 daily buckets on a narrow phone', (t) async {
      // The 30-day view. Slot width drops under the per-bar label
      // threshold here, so the numbers must be dropped rather than
      // overlapped.
      await _paint(t, List<int>.generate(30, (i) => i % 7), const Size(280, 150));
    });

    testWidgets('24 hourly buckets', (t) async {
      await _paint(t, List<int>.generate(24, (i) => i), phone);
    });

    testWidgets('large values that widen the axis labels', (t) async {
      await _paint(t, const [1200, 980, 1500], phone);
    });

    testWidgets('a canvas narrower than the y-axis gutter', (t) async {
      // plotWidth goes negative here; the painter must bail, not divide.
      await _paint(t, const [3, 4], const Size(20, 150));
    });

    testWidgets('a canvas of almost no height', (t) async {
      await _paint(t, const [3, 4], const Size(320, 14));
    });
  });

  group('shouldRepaint', () {
    BarChartPainter make(List<int> v, {Color text = Colors.black54}) =>
        BarChartPainter(
          values: v,
          barColor: Colors.teal,
          axisColor: Colors.black12,
          textColor: text,
        );

    test('repaints when the values change', () {
      expect(make(const [1, 2]).shouldRepaint(make(const [1, 3])), isTrue);
    });

    test('repaints when a colour changes', () {
      expect(
        make(const [1, 2]).shouldRepaint(make(const [1, 2], text: Colors.red)),
        isTrue,
      );
    });

    test('does NOT repaint for an equal list with a different identity', () {
      // Compared by contents, not identity. fetch() builds a fresh list
      // every poll, so an identity check would repaint the chart on every
      // refresh regardless of whether anything moved.
      expect(make([1, 2, 3]).shouldRepaint(make([1, 2, 3])), isFalse);
    });
  });
  // x-axis labels. The chart had no dates on it because BarChartPainter
  // only ever received the numbers: the screen mapped the series to values
  // and discarded each point's bucket timestamp. Labels reserve a 14px
  // strip under the axis, so every height below it shifts - the same class
  // of division-and-negative-size hazard the rest of this file exists for.
  group('x-axis labels', () {
    const tall = Size(320, 176);

    testWidgets('absent labels paint exactly as before', (t) async {
      await _paint(t, const [1, 5, 3], phone);
    });

    testWidgets('a full set of labels paints', (t) async {
      await _paintLabelled(
          t, const [1, 5, 3], const ['1/11', '2/11', '3/11'], tall);
    });

    testWidgets('30 daily buckets on a narrow phone paint', (t) async {
      // ~9px per bar against a ~26px label, so the thinning has to engage.
      await _paintLabelled(
        t,
        List<int>.generate(30, (i) => i % 7),
        List<String>.generate(30, (i) => '${i + 1}/11'),
        tall,
      );
    });

    testWidgets('24 hourly buckets paint', (t) async {
      await _paintLabelled(
        t,
        List<int>.generate(24, (i) => i),
        List<String>.generate(24, (i) => '${i.toString().padLeft(2, '0')}:00'),
        tall,
      );
    });

    testWidgets('a single labelled bucket paints', (t) async {
      await _paintLabelled(t, const [4], const ['14:00'], tall);
    });

    testWidgets('a mismatched label count is ignored, not an index crash',
        (t) async {
      // Both lists come from the same series so this should not happen, but
      // an index error inside paint() takes the whole admin screen down
      // with a red error box.
      await _paintLabelled(t, const [1, 2, 3, 4], const ['1/11', '2/11'], tall);
    });

    testWidgets('a canvas too short for the label strip stays non-negative',
        (t) async {
      // The strip takes 14px; at 10px tall plotHeight goes negative and the
      // painter must bail rather than compute a negative bar height.
      await _paintLabelled(
          t, const [1, 2], const ['1/11', '2/11'], const Size(320, 10));
    });

    test('shouldRepaint notices a label change with identical values', () {
      // fetch() rebuilds the series every poll, and identical counts can
      // land on a different day - an identity check would leave yesterday's
      // axis under today's bars.
      BarChartPainter p(List<String> labels) => BarChartPainter(
            values: const [1, 2],
            labels: labels,
            barColor: Colors.teal,
            axisColor: Colors.black12,
            textColor: Colors.black54,
          );
      expect(
          p(const ['2/11', '3/11']).shouldRepaint(p(const ['1/11', '2/11'])),
          isTrue);
      expect(
          p(const ['1/11', '2/11']).shouldRepaint(p(const ['1/11', '2/11'])),
          isFalse,
          reason: 'Identical contents must NOT repaint, or every poll '
              'repaints whether or not anything moved.');
    });
  });
}
