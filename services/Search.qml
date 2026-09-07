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
//   4. panels/cards/<type>.qml   : la carte, nommée d'après `type`
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
    property ClaudeSource claudeSource: ClaudeSource {
        onProduced: (seq, items) => root._collect(seq, "conversation", items)
    }
    property WebSource webSource: WebSource {
        onProduced: (seq, items) => root._collect(seq, "web", items)
    }

    readonly property var sources: [appSource, fileSource, settingSource,
                                    claudeSource, webSource]

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
            root.results = [];
            return;
        }
        debounce.restart();
    }

    function _dispatch() {
        root._seq++;
        root._buckets = ({});
        root.results = [];

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

    readonly property int maxResults: 24

    function _rebuild() {
        var out = [];

        for (var i = 0; i < root.sources.length; i++) {
            var items = root._buckets[root.sources[i].type];
            if (!items)
                continue;
            for (var j = 0; j < items.length; j++)
                out.push(items[j]);
        }

        out.sort(function (a, b) { return b.score - a.score; });
        root.results = out.slice(0, root.maxResults);
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
