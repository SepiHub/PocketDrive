import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdrive_phone/resume_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const movie = Duration(minutes: 100);

  test('what is worth resuming', () {
    expect(shouldRemember(const Duration(minutes: 30), movie), isTrue);
    expect(shouldRemember(const Duration(seconds: 5), movie), isFalse);
    // Last 5% of a long video counts as finished.
    expect(shouldRemember(const Duration(minutes: 96), movie), isFalse);
    // Short clips are never resumed.
    expect(
      shouldRemember(const Duration(seconds: 50), const Duration(seconds: 90)),
      isFalse,
    );
    // For shorter videos the "finished" tail is at least 30 seconds.
    expect(
      shouldRemember(
        const Duration(minutes: 2, seconds: 40),
        const Duration(minutes: 3),
      ),
      isFalse,
    );
  });

  test('saves, resumes, forgets when finished', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await ResumeStore.load();
    final id = ResumeStore.idFor('pc', 'Movies/a.mkv', DateTime(2025));

    await store.save(id, const Duration(minutes: 42), movie);
    expect(store.positionFor(id), const Duration(minutes: 42));

    // A changed file (other modified time) starts from the beginning.
    expect(
      store.positionFor(
        ResumeStore.idFor('pc', 'Movies/a.mkv', DateTime(2026)),
      ),
      isNull,
    );

    await store.save(id, const Duration(minutes: 99), movie);
    expect(store.positionFor(id), isNull);
  });

  test('keeps only the most recent entries', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await ResumeStore.load();
    for (var i = 0; i < ResumeStore.maxEntries + 20; i++) {
      await store.save('v$i', const Duration(minutes: 10), movie);
    }
    expect(store.positionFor('v0'), isNull);
    expect(
      store.positionFor('v${ResumeStore.maxEntries + 19}'),
      const Duration(minutes: 10),
    );
  });
}
