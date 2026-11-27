import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/thread_ripper/auto_concurrency.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final scenarios = jsonDecode(
    File('test/fixtures/ripper_auto.json').readAsStringSync(),
  ) as List;
  for (final scenario in scenarios) {
    test('automatic concurrency matches upstream: ${scenario['name']}', () {
      var now = 5000;
      final auto = RipperAutoConcurrency(now: () => now);
      for (final step in scenario['steps'] as List) {
        now = step['at'];
        final args = step['args'] as List;
        switch (step['op']) {
          case 'demand':
            auto.demand(args[0], args[1], args[2]);
          case 'activity':
            auto.activity();
          case 'delivered':
            auto.delivered((args[0] as num).toInt());
          case 'stall':
            auto.stall();
          case 'pushback':
            auto.pushback();
          case 'newSession':
            auto.newSession();
          case 'buffer':
            auto.buffer((args[0] as num).toDouble(), args[1]);
        }
        expect(auto.threads, step['threads'], reason: '${step['op']} at $now');
      }
    });
  }

  test('a full mpv cache below 15 s also ends the start', () {
    var now = 5000;
    var asked = 0;
    final auto = RipperAutoConcurrency(now: () => now);
    bool full() {
      asked++;
      return true;
    }

    auto.newSession();
    expect(auto.threads, 16);
    now += 2000;
    auto.buffer(4, true, cacheFull: full);
    expect((auto.threads, asked), (16, 0));
    now += 600;
    auto.buffer(4, true, cacheFull: () => false);
    expect(auto.threads, 16);
    auto.buffer(4, true, cacheFull: full);
    expect((auto.threads, asked), (12, 1));
    now += 2500;
    auto.buffer(4, true, cacheFull: full);
    expect((auto.threads, asked), (8, 2));
    now += 2500;
    auto.buffer(4, true, cacheFull: full);
    expect((auto.threads, asked), (8, 2));
  });

  group('native network-bound signal', () {
    late int now;
    late RipperAutoConcurrency auto;
    // [ms] of playback waiting on the network while [bytesPerSecond]
    // arrive, as the proxy samples and delivers them.
    void run(int ms, int bytesPerSecond, {bool bound = true}) {
      for (var t = 0; t < ms; t += 250) {
        now += 250;
        auto.networkBound(bound);
        auto.delivered(bytesPerSecond ~/ 4);
      }
    }

    setUp(() {
      now = 10000;
      auto = RipperAutoConcurrency(now: () => now);
    });

    test('stalls on a link that is the limit do not climb the ladder', () {
      run(5000, 1250000);
      expect(auto.stall(), isTrue);
      expect(auto.threads, 12);
      // A stall every 3 s for 30 s, the link unchanged: the trial is not
      // replaced before its verdict, which undoes it and bars 12 threads.
      for (var i = 0; i < 10; i++) {
        run(3000, 1250000);
        auto.stall();
      }
      expect(auto.threads, 8);
    });

    test('more threads that raise the throughput stay', () {
      run(5000, 500000);
      expect(auto.stall(), isTrue);
      run(11000, 800000);
      expect(auto.threads, 12);
      run(3000, 800000);
      auto.stall();
      expect(auto.threads, 16);
    });

    test('without the signal the upstream rules are unchanged', () {
      for (var t = 0; t < 5000; t += 250) {
        now += 250;
        auto.delivered(1250000 ~/ 4);
      }
      expect(auto.stall(), isTrue);
      now += 3000;
      expect(auto.stall(), isTrue);
      expect(auto.threads, 16);
    });
  });
}
