pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

// Ce que le géoïde du bureau vide dit d'un pays (panels/Globe.qml). Tout
// passe par `anna world …` (anna/src/world.rs), qui fait les requêtes et
// garde les réponses en cache :
//
//   apple <CC>    les classements d'Apple dans le pays : ebooks payants et
//                 gratuits, livres audio (Apple Books), titres les plus
//                 écoutés (Apple Music) ; une liste vide là où la boutique
//                 n'existe pas ; un livre y porte `cover`, sa couverture
//                 sur le disque
//   item <CC> <id>  la fiche d'une entrée de ces classements : pour un
//                 livre, résumé, prix, note des lecteurs ; pour un livre
//                 audio ou un titre, l'adresse de son extrait (`preview`)
//
// Les réponses sont tenues par code de pays : { state, data }, où state
// vaut "loading", "ok" ou "error" (data.error dit pourquoi). Une demande
// déjà faite ne repart pas.
Singleton {
    id: world

    readonly property string anna: Quickshell.env("KARENINE_ANNA") || "anna"

    property var apple: ({})
    // Par « CC/id ».
    property var items: ({})

    function _set(kind, cc, entry) {
        var copy = Object.assign({}, world[kind]);
        copy[cc] = entry;
        world[kind] = copy;
    }

    // Les classements du pays choisi.
    function fetch(cc) {
        if (!cc)
            return;
        // Un territoire sans code ISO à deux lettres (Natural Earth lui en
        // donne un à trois) : Apple ne le connaît pas.
        if (!/^[A-Z]{2}$/.test(cc)) {
            world._set("apple", cc, { state: "ok", data: { charts: {} } });
            return;
        }
        world._ask("apple", cc, [world.anna, "world", "apple", cc]);
    }

    // La fiche d'une entrée, dans `items["CC/id"]`.
    function item(cc, id) {
        if (/^[A-Z]{2}$/.test(cc) && /^[0-9]+$/.test(id))
            world._ask("items", cc + "/" + id, [world.anna, "world", "item", cc, id]);
    }

    function _ask(kind, cc, command) {
        var have = world[kind][cc];
        if (have && have.state !== "error")
            return;
        world._set(kind, cc, { state: "loading", data: null });
        job.createObject(world, { kind: kind, cc: cc, command: command });
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
