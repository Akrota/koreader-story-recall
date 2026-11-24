#!/bin/zsh
# Runs all Story Recall test patches in a separate KOReader home (kohome2),
# never touching the main test home or its keys. Usage: run_tests.sh [names...]
S=${0:A:h:h}
T=${0:A:h}  # folder of this script (the test patches)
H=$S/kohome2; B=$S/books-ctx; O=$S/run2
mkdir -p $O/shots $O/shots-big $H/patches; rm -f $H/patches/*(N) $H/settings/story_recall_keys.lua*(N)
for b in schwester reise primal; do [ -f $B/$b.epub ] || cp $S/books/$b.epub $B/; done
runko() { ( cd $S && KO_HOME=$H STORYRECALL_TEST_OUT=$O $S/koreader-mac/KOReader.app/Contents/MacOS/koreader -d "$1" > "$2" 2>&1 & PID=$!; for i in $(seq 1 150); do kill -0 $PID 2>/dev/null || break; sleep 1; done; kill $PID 2>/dev/null ); }
fresh() { rm -rf $B/$1.sdr; mkdir -p $B/$1.sdr; echo "return { [\"version\"] = 1, [\"last_seen\"] = $2, [\"chapters\"] = {}, [\"notes\"] = {}, [\"next_note_id\"] = 1 }" > $B/$1.sdr/story_recall.lua; }
NAMES=${@:-test stress ai guide quota series2 spoiler block2 context}
for n in ${=NAMES}; do
  rm -f $H/patches/*(N)
  case $n in
    test) cp "$T/2-storyrecall-test.lua" $H/patches/; fresh schwester $(( $(date +%s) - 10*86400 )); runko $B/schwester.epub $O/ko-test.log; R=test-results.txt;;
    stress) cp "$T/2-storyrecall-stress.lua" $H/patches/; fresh reise $(( $(date +%s) - 21*86400 )); runko $B/reise.epub $O/ko-stress.log; R=stress-results.txt;;
    ai) cp "$T/2-storyrecall-ai.lua" $H/patches/; rm -f $O/ratelimit-done $O/requests.log; fresh schwester $(date +%s); runko $B/schwester.epub $O/ko-ai.log; R=ai-results.txt;;
    guide) cp "$T/2-storyrecall-guide.lua" $H/patches/; runko $B/schwester.epub $O/ko-guide.log; R=guide-results.txt;;
    quota) cp "$T/2-storyrecall-quota.lua" $H/patches/; fresh schwester $(date +%s); runko $B/schwester.epub $O/ko-quota.log; R=quota-results.txt;;
    series2) cp "$T/2-storyrecall-series2.lua" $H/patches/; fresh schwester $(date +%s); runko $B/schwester.epub $O/ko-series2.log; R=series2-results.txt;;
    spoiler) cp "$T/2-storyrecall-spoiler.lua" $H/patches/; fresh reise $(date +%s); runko $B/reise.epub $O/ko-spoiler.log; R=spoiler-results.txt;;
    block2) cp "$T/2-storyrecall-block2.lua" $H/patches/; fresh schwester $(date +%s); runko $B/schwester.epub $O/ko-block2.log; R=block2-results.txt;;
    lesestand2) cp "$T/2-storyrecall-lesestand2.lua" $H/patches/; fresh reise $(date +%s); runko $B/reise.epub $O/ko-lesestand2.log; R=lesestand2-results.txt;;
    context) cp "$T/2-storyrecall-context.lua" $H/patches/; fresh reise $(date +%s); runko $B/reise.epub $O/ko-context.log; R=context-results.txt;;
    context-primal) cp "$T/2-storyrecall-context.lua" $H/patches/; rm -f $B/primal.sdr/*.old(N); runko $B/primal.epub $O/ko-context.log; R=context-results.txt;;
  esac
  echo "$n: $(grep -c '^PASS' $O/$R 2>/dev/null) pass"; grep -E "^FAIL|ERROR" $O/$R 2>/dev/null
done
rm -f $H/patches/*(N)
