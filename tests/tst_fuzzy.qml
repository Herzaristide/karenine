import QtQuick
import QtTest
import "pure"  // monté par tests/run.sh

// Score de la recherche de la barre (services/Fuzzy.qml) : l'ordre des paliers
// décide de ce qui remonte en tête, c'est lui qu'on fige ici.
TestCase {
    name: "Fuzzy"

    function test_no_match_is_zero() {
        compare(Fuzzy.score("xyz", "firefox"), 0);
        compare(Fuzzy.score("abc", ""), 0);
        compare(Fuzzy.score("abc", null), 0);
    }

    function test_empty_query_matches_everything() {
        compare(Fuzzy.score("", "firefox"), 1);
    }

    function test_case_insensitive() {
        compare(Fuzzy.score("FIRE", "firefox"), Fuzzy.score("fire", "Firefox"));
    }

    function test_tiers_are_ordered() {
        var prefix = Fuzzy.score("fox", "foxglove");
        var wordStart = Fuzzy.score("fox", "red fox");
        var inside = Fuzzy.score("fox", "firefox");
        var subseq = Fuzzy.score("ffx", "firefox");
        verify(prefix > wordStart, prefix + " > " + wordStart);
        verify(wordStart > inside, wordStart + " > " + inside);
        verify(inside > subseq, inside + " > " + subseq);
        verify(subseq > 0);
    }

    function test_word_boundaries() {
        // Après « - », « _ », « . », « / », « : » ou une espace : début de mot.
        var seps = [" ", "-", "_", ".", "/", ":"];
        for (var i = 0; i < seps.length; i++)
            compare(Fuzzy.score("code", "vs" + seps[i] + "code"), 700 - 3, "sep '" + seps[i] + "'");
        compare(Fuzzy.score("code", "vscode"), 400 - 2);
    }

    function test_shorter_prefix_match_wins() {
        verify(Fuzzy.score("term", "term") > Fuzzy.score("term", "terminal-emulator"));
    }

    function test_subsequence() {
        verify(Fuzzy.subsequence("nxs", "nixos"));
        verify(!Fuzzy.subsequence("nsx", "nixos"));
        verify(Fuzzy.subsequence("", "nixos"));
    }

    function test_best_prefers_first_field() {
        var title = Fuzzy.best("notes", ["notes", "other"]);
        var secondary = Fuzzy.best("notes", ["other", "notes"]);
        verify(title > secondary, title + " > " + secondary);
        compare(Fuzzy.best("zzz", ["a", "b"]), 0);
    }
}
