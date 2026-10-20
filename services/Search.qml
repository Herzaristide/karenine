pragma Singleton
import QtQuick

// Agrégateur de recherche. Il ne sait rien du contenu : il tient la requête,
// la distribue aux sources, recolle leurs réponses et les classe en une liste.
//
// AJOUTER UN TYPE DE RÉSULTAT — quatre gestes, aucun autre fichier à toucher :
//   1. services/<Nom>Source.qml  : search(query, seq) → produced(seq, items)
//                                  et activate(item, actionId)
//   2. services/qmldir           : déclarer le nouveau composant
//   3. ici                       : une propriété + une entrée dans `sources`
//   4. panels/ConversationBar.qml : l'icône et l'étiquette du type
QtObject {
    id: root

    property string query: ""
    readonly property bool active: query.trim().length > 0

    // Une seule liste, tous types confondus, ordonnée par pertinence. Les
    // sources plafonnent chacune leur contribution ; le classement fait le
    // reste. Pas de découpage par type : une application pertinente doit
    // pouvoir passer devant un fichier qui l'est moins.
    property var results: []

    readonly property var firstItem: results.length > 0 ? results[0] : null

    // Chaque requête porte un numéro. Une réponse qui n'a pas le numéro courant
    // est une réponse périmée : elle est jetée. C'est ce qui évite d'afficher
    // les résultats d'une frappe précédente quand une source répond en retard.
    property int _seq: 0
    property var _buckets: ({})

    property AppSource appSource: AppSource {
        onProduced: (seq, items) => root._collect(seq, "app", items)
    }
    property FileSource fileSource: FileSource {
        onProduced: (seq, items) => root._collect(seq, "file", items)
    }
    property SettingSource settingSource: SettingSource {
        onProduced: (seq, items) => root._collect(seq, "setting", items)
    }
    property WallpaperSource wallpaperSource: WallpaperSource {
        onProduced: (seq, items) => root._collect(seq, "wallpaper", items)
    }
    // Pas de sessions Claude : la recherche de la barre reste sur ce qu'on
    // ouvre.
    property WebSource webSource: WebSource {
        onProduced: (seq, items) => root._collect(seq, "web", items)
    }
    // Les notes de l'onglet Notes, et « Créer une note » avec ce qu'on tape.
    property NoteSource noteSource: NoteSource {
        onProduced: (seq, items) => root._collect(seq, "note", items)
    }

    readonly property var sources: [appSource, fileSource, settingSource,
                                    wallpaperSource, noteSource, webSource]

    // Le débounce protège la seule source coûteuse (fd) sans se faire sentir
    // sur les autres, qui répondent en moins d'une milliseconde.
    property Timer debounce: Timer {
        interval: 130
        onTriggered: root._dispatch()
    }

    onQueryChanged: {
        // On relit la requête, pas `active` : au moment où ce gestionnaire
        // tourne, la liaison de `active` n'a pas encore été réévaluée.
        if (root.query.trim().length === 0) {
            debounce.stop();
            root._seq++;             // invalide tout ce qui est encore en vol
            root._buckets = ({});
            root._stale = ({});
            root._shown = "";
            root.results = [];
            return;
        }
        debounce.restart();
    }

    // Les réponses de la requête précédente : une source qui n'a pas encore
    // répondu à la nouvelle garde les siennes à l'écran en attendant. Vider la
    // liste à chaque lettre la faisait se replier puis se redéplier (et le
    // voile avec elle) le temps que `fd` réponde.
    property var _stale: ({})
    // Ce qu'affiche la liste, en une chaîne : une réponse qui n'y change rien
    // ne recrée pas ses lignes.
    property string _shown: ""

    function _dispatch() {
        root._seq++;
        root._stale = root._buckets;
        root._buckets = ({});

        var q = root.query.trim();
        for (var i = 0; i < root.sources.length; i++)
            root.sources[i].search(q, root._seq);
    }

    function _collect(seq, type, items) {
        if (seq !== root._seq)
            return;                  // réponse périmée

        root._buckets[type] = items;
        root._rebuild();
    }

    readonly property int maxResults: 12

    // À correspondance égale, ce qu'on lance le plus souvent passe devant :
    // sans ce bonus, un dossier « fish » battait l'application Firefox sur
    // « fi », simplement parce que son nom est plus court.
    readonly property var typeBonus: ({ app: 120, setting: 60, file: 0, web: 0 })

    // Écart toléré sous le meilleur résultat local. Les paliers de Fuzzy sont
    // espacés d'environ 300 : on garde le palier du meilleur et le haut du
    // suivant, pas les fragments en milieu de mot quand un préfixe existe.
    readonly property int cutoff: 350

    // Dès qu'il y a ce nombre de résultats locaux, le web se réduit à une ligne.
    readonly property int webWhenFew: 3

    function _rebuild() {
        var local = [];
        var web = [];
        // Ce qui doit rester proposé quoi qu'il arrive (`always` : « Créer
        // une note ») : hors du seuil et de la limite.
        var always = [];

        for (var i = 0; i < root.sources.length; i++) {
            var type = root.sources[i].type;
            var items = root._buckets[type] || root._stale[type];
            if (!items)
                continue;
            for (var j = 0; j < items.length; j++) {
                var it = items[j];
                it.rank = it.score + (root.typeBonus[it.type] || 0);
                (it.always ? always : it.type === "web" ? web : local).push(it);
            }
        }

        var byRank = function (a, b) { return b.rank - a.rank; };
        local.sort(byRank);
        web.sort(byRank);

        if (local.length > 0) {
            var floor = local[0].rank - root.cutoff;
            local = local.filter(function (it) { return it.rank >= floor; });
        }

        // Le web échappe au seuil : c'est le recours quand rien ne colle.
        if (local.length >= root.webWhenFew)
            web = web.slice(0, 1);

        var out = local.concat(web);
        out.sort(byRank);
        out = out.slice(0, root.maxResults - always.length).concat(always);
        out.sort(byRank);

        var shown = out.map(function (it) {
            return it.id + "\u0001" + it.title + "\u0001" + it.subtitle;
        }).join("\u0002");
        if (shown === root._shown)
            return;
        root._shown = shown;
        root.results = out;
    }

    function _sourceFor(type) {
        for (var i = 0; i < root.sources.length; i++)
            if (root.sources[i].type === type)
                return root.sources[i];
        return null;
    }

    function activate(item, actionId) {
        var s = root._sourceFor(item.type);
        if (s)
            s.activate(item, actionId);
    }

    function clear() {
        root.query = "";
    }
}
