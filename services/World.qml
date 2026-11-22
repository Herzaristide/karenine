pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

// Ce que le géoïde du bureau vide dit d'un pays (panels/Globe.qml). Tout
// passe par `anna world …` (anna/src/world.rs), qui fait les requêtes et
// garde les réponses en cache :
//
//   trends <CC>          les articles de Wikipédia les plus lus depuis le
//                        pays, toutes langues confondues (la veille)
//   music <CC> <nom>     les titres les plus écoutés du pays sur Last.fm
//   lastfm [<clé>]       la clé Last.fm (gratuite, créée par l'utilisateur),
//                        rangée dans le trousseau
//
// Les réponses sont tenues par code de pays : { state, data }, où state
// vaut "loading", "ok" ou "error" (data.error dit pourquoi : "no-key",
// "bad-key", ou un message). Une demande déjà faite ne repart pas.
Singleton {
    id: world

    readonly property string anna: Quickshell.env("KARENINE_ANNA") || "anna"

    property var trends: ({})
    property var music: ({})

    function _set(kind, cc, entry) {
        var copy = Object.assign({}, world[kind]);
        copy[cc] = entry;
        world[kind] = copy;
    }

    // Les deux d'un coup, pour le pays choisi : `name` est son nom anglais,
    // celui que Last.fm comprend le plus souvent.
    function fetch(cc, name) {
        if (!cc)
            return;
        // Un territoire sans code ISO à deux lettres (Natural Earth lui en
        // donne un à trois) : ni Wikimedia ni Last.fm ne le connaissent.
        if (!/^[A-Z]{2}$/.test(cc)) {
            var none = { state: "ok", data: { articles: [], tracks: [] } };
            world._set("trends", cc, none);
            world._set("music", cc, none);
            return;
        }
        world._ask("trends", cc, [world.anna, "world", "trends", cc]);
        world._ask("music", cc, [world.anna, "world", "music", cc, name || ""]);
    }

    function _ask(kind, cc, command) {
        var have = world[kind][cc];
        if (have && have.state !== "error")
            return;
        world._set(kind, cc, { state: "loading", data: null });
        job.createObject(world, { kind: kind, cc: cc, command: command });
    }

    // La clé Last.fm : la range, puis redemande la musique de tout pays qui
    // l'attendait.
    function setLastfmKey(key) {
        keyJob.command = [world.anna, "world", "lastfm", key.trim()];
        keyJob.running = true;
    }

    Process {
        id: keyJob
        onRunningChanged: {
            if (running)
                return;
            var copy = Object.assign({}, world.music);
            for (var cc in copy) {
                if (copy[cc].state === "error")
                    delete copy[cc];
            }
            world.music = copy;
        }
    }

    Component {
        id: job

        Process {
            id: proc
            property string kind
            property string cc
            running: true
            stdout: StdioCollector { id: out }
            onRunningChanged: {
                if (running)
                    return;
                var entry;
                try {
                    var r = JSON.parse(out.text);
                    entry = r.ok ? { state: "ok", data: r }
                                 : { state: "error", data: { error: r.error || "" } };
                } catch (e) {
                    entry = { state: "error", data: { error: I18n.tr("anna.noAnswer") } };
                }
                world._set(proc.kind, proc.cc, entry);
                proc.destroy();
            }
        }
    }
}
