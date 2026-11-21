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

    // Les sources ne publient qu'une fois toutes répondues, ou passé
    // `settleMs` : on attend que la liste ait pris la forme attendue.
    function idsSoon(expected, withWeb, msg) {
        tryVerify(function () {
            return JSON.stringify(ids(withWeb)) === JSON.stringify(expected);
        }, 2000, msg || JSON.stringify(expected));
    }

    function init() {
        Search.clear();
        DefaultApps.lastUrl = "";
        Search.appSource.activated = null;
    }

    function test_query_is_trimmed_and_sent_to_every_source() {
        dispatch("  fi ");
        var srcs = [Search.appSource, Search.fileSource, Search.settingSource,
                    Search.wallpaperSource];
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
        answerAll(Search.appSource);
        compare(ids().length, 0, "la réponse à « fi » est jetée");
        dispatch("fire");
        answerAll(Search.appSource);
        Search.appSource.produced(Search._seq, [item("app", "firefox", 500)]);
        idsSoon(["firefox"], false);
    }

    function test_type_bonus_favours_apps() {
        // Le dossier « fish » score mieux que Firefox sur « fi » ; le bonus
        // d'application (120) le fait passer devant.
        dispatch("fi");
        Search.fileSource.produced(Search._seq, [item("file", "fish", 550)]);
        Search.appSource.produced(Search._seq, [item("app", "firefox", 500)]);
        idsSoon(["firefox", "fish"], false);
        compare(Search.firstItem.id, "firefox");
    }

    function test_cutoff_drops_weak_local_matches() {
        dispatch("fox");
        Search.fileSource.produced(Search._seq, [
            item("file", "foxglove", 900),
            item("file", "near", 900 - Search.cutoff),
            item("file", "firefox.txt", 900 - Search.cutoff - 1)
        ]);
        idsSoon(["foxglove", "near"], false);
    }

    function test_web_shrinks_when_local_is_enough() {
        dispatch("example.com");
        Search.fileSource.produced(Search._seq, [
            item("file", "a", 950), item("file", "b", 940), item("file", "c", 930)
        ]);
        idsSoon(["a", "b", "c", "web:direct"], true);
        var web = Search.results.filter(function (it) { return it.type === "web"; });
        compare(web.length, 1);
        compare(web[0].id, "web:direct");
    }

    function test_web_escapes_the_cutoff() {
        dispatch("zzz");
        Search.fileSource.produced(Search._seq, [item("file", "zzz", 900)]);
        // Le moteur score 60, bien sous le seuil : il reste proposé.
        idsSoon(["zzz", "web:web"], true);
    }

    function test_results_are_capped_but_always_items_stay() {
        dispatch("n");
        var many = [];
        for (var i = 0; i < 20; i++)
            many.push(item("file", "f" + i, 900 - i));
        Search.fileSource.produced(Search._seq, many);
        Search.settingSource.produced(Search._seq, [item("setting", "setting:always", 1, { always: true })]);
        tryVerify(function () { return ids().indexOf("setting:always") !== -1; }, 2000,
                  "un résultat « toujours là » reste");
        compare(Search.results.length, Search.maxResults);
    }

    function test_previous_list_stays_until_the_new_one_is_ready() {
        dispatch("fi");
        answerAll(Search.appSource);
        Search.appSource.produced(Search._seq, [item("app", "firefox", 500)]);
        verify(!Search.loading);
        Search.query = "fir";
        verify(Search.loading, "la frappe d'après charge");
        tryVerify(function () { return Search.appSource.lastQuery === "fir"; });
        Search.fileSource.produced(Search._seq, [item("file", "fir.txt", 450)]);
        compare(ids(), ["firefox"], "l'ancienne liste reste tant que tout n'a pas répondu");
        answerAll(Search.fileSource);
        compare(ids(), ["fir.txt"]);
        verify(!Search.loading);
    }

    function test_address_alone_after_the_delay() {
        dispatch("example.com");
        // Adresse reconnue : le web propose l'adresse directe + le moteur.
        tryVerify(function () { return Search.results.length === 2; });
    }

    // Toutes les sources ont répondu : la liste se publie aussitôt, sans
    // attendre le délai.
    function answerAll(except) {
        var srcs = [Search.appSource, Search.fileSource, Search.settingSource,
                    Search.wallpaperSource, Search.taskSource];
        for (var i = 0; i < srcs.length; i++)
            if (srcs[i] !== except)
                srcs[i].produced(Search._seq, []);
    }

    function test_publishes_at_once_when_every_source_answered() {
        dispatch("fi");
        answerAll(Search.appSource);
        Search.appSource.produced(Search._seq, [item("app", "firefox", 500)]);
        compare(ids(), ["firefox"]);
    }

    function test_one_list_per_keystroke() {
        dispatch("fi");
        Search.appSource.produced(Search._seq, [item("app", "firefox", 500)]);
        compare(ids(), [], "fd n'a pas répondu : rien ne s'affiche encore");
        idsSoon(["firefox"], false, "le délai passé, on publie ce qu'on a");
        verify(!Search.loading);
        // Après la publication, une réponse tardive est jetée : la liste ne
        // bouge plus sous le curseur.
        Search.fileSource.produced(Search._seq, [item("file", "fish", 900)]);
        compare(ids(), ["firefox"]);
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
