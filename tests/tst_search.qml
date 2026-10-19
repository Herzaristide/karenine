import QtQuick
import QtTest
import "pure"  // monté par tests/run.sh

// L'agrégateur de la barre (services/Search.qml), branché sur des sources
// factices (tests/stubs) : on simule leurs réponses et on vérifie ce qui
// s'affiche — ordre, seuil, place du web, réponses périmées.
TestCase {
    name: "Search"

    function item(type, id, score, extra) {
        var it = { type: type, id: id, title: id, subtitle: "", score: score };
        for (var k in extra)
            it[k] = extra[k];
        return it;
    }

    // Tape la requête et attend que le débounce l'ait distribuée.
    function dispatch(q) {
        var before = Search._seq;
        Search.query = q;
        tryVerify(function () { return Search._seq > before; }, 2000, "dispatch de « " + q + " »");
    }

    // Le web répond à chaque requête (sans attendre) : on ne le compte que si
    // le test le demande.
    function ids(withWeb) {
        return Search.results
            .filter(function (it) { return withWeb || it.type !== "web"; })
            .map(function (it) { return it.id; });
    }

    function init() {
        Search.clear();
        DefaultApps.lastUrl = "";
        Search.appSource.activated = null;
    }

    function test_query_is_trimmed_and_sent_to_every_source() {
        dispatch("  fi ");
        var srcs = [Search.appSource, Search.fileSource, Search.settingSource,
                    Search.wallpaperSource, Search.noteSource];
        for (var i = 0; i < srcs.length; i++) {
            compare(srcs[i].lastQuery, "fi", srcs[i].type);
            compare(srcs[i].lastSeq, Search._seq, srcs[i].type);
        }
        verify(Search.active);
    }

    function test_debounce_coalesces_keystrokes() {
        var before = Search._seq;
        Search.query = "f";
        Search.query = "fi";
        Search.query = "fir";
        compare(Search._seq, before, "rien n'est envoyé avant le débounce");
        tryVerify(function () { return Search._seq === before + 1; });
        compare(Search.appSource.lastQuery, "fir");
    }

    function test_stale_answers_are_dropped() {
        dispatch("fi");
        var old = Search._seq;
        dispatch("fir");
        Search.appSource.produced(old, [item("app", "firefox", 500)]);
        compare(ids().length, 0);
        Search.appSource.produced(Search._seq, [item("app", "firefox", 500)]);
        compare(ids(), ["firefox"]);
    }

    function test_type_bonus_favours_apps() {
        // Le dossier « fish » score mieux que Firefox sur « fi » ; le bonus
        // d'application (120) le fait passer devant.
        dispatch("fi");
        Search.fileSource.produced(Search._seq, [item("file", "fish", 550)]);
        Search.appSource.produced(Search._seq, [item("app", "firefox", 500)]);
        compare(ids(), ["firefox", "fish"]);
        compare(Search.firstItem.id, "firefox");
    }

    function test_cutoff_drops_weak_local_matches() {
        dispatch("fox");
        Search.fileSource.produced(Search._seq, [
            item("file", "foxglove", 900),
            item("file", "near", 900 - Search.cutoff),
            item("file", "firefox.txt", 900 - Search.cutoff - 1)
        ]);
        compare(ids(), ["foxglove", "near"]);
    }

    function test_web_shrinks_when_local_is_enough() {
        dispatch("example.com");
        // Adresse reconnue : le web propose l'adresse directe + le moteur.
        compare(Search.results.length, 2);
        Search.fileSource.produced(Search._seq, [
            item("file", "a", 950), item("file", "b", 940), item("file", "c", 930)
        ]);
        var web = Search.results.filter(function (it) { return it.type === "web"; });
        compare(web.length, 1);
        compare(web[0].id, "web:direct");
    }

    function test_web_escapes_the_cutoff() {
        dispatch("zzz");
        Search.fileSource.produced(Search._seq, [item("file", "zzz", 900)]);
        // Le moteur score 60, bien sous le seuil : il reste proposé.
        compare(ids(true), ["zzz", "web:web"]);
    }

    function test_results_are_capped_but_always_items_stay() {
        dispatch("n");
        var many = [];
        for (var i = 0; i < 20; i++)
            many.push(item("file", "f" + i, 900 - i));
        Search.fileSource.produced(Search._seq, many);
        compare(Search.results.length, Search.maxResults);

        Search.noteSource.produced(Search._seq, [item("note", "note:new", 1, { always: true })]);
        compare(Search.results.length, Search.maxResults);
        verify(ids().indexOf("note:new") !== -1, "« Créer une note » reste");
    }

    function test_unanswered_source_keeps_its_previous_results() {
        dispatch("fi");
        Search.appSource.produced(Search._seq, [item("app", "firefox", 500)]);
        dispatch("fir");
        Search.fileSource.produced(Search._seq, [item("file", "fir.txt", 450)]);
        compare(ids(), ["firefox", "fir.txt"], "l'app n'a pas encore répondu : on garde la sienne");
        Search.appSource.produced(Search._seq, []);
        compare(ids(), ["fir.txt"]);
    }

    function test_clear_empties_and_invalidates() {
        dispatch("fi");
        var seq = Search._seq;
        Search.clear();
        verify(!Search.active);
        compare(Search.results.length, 0);
        Search.appSource.produced(seq, [item("app", "firefox", 500)]);
        compare(Search.results.length, 0, "une réponse en vol après l'effacement est jetée");
    }

    function test_activate_routes_to_the_item_source() {
        var it = item("app", "firefox", 500);
        Search.activate(it, "open");
        compare(Search.appSource.activated.item.id, "firefox");
        compare(Search.appSource.activated.action, "open");

        Search.activate({ type: "web", payload: { url: "https://x.org" } }, "open");
        compare(DefaultApps.lastUrl, "https://x.org");

        Search.activate({ type: "inconnu" }, "open");  // sans source : ignoré
    }
}
