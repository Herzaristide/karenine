import QtQuick

// Source « web » : aucune requête réseau. On fabrique des liens à ouvrir, ce
// qui couvre l'essentiel du besoin sans envoyer chaque frappe à un tiers.
// Ajouter un moteur = une ligne dans `engines`.
QtObject {
    id: src

    readonly property string type:  "web"
    readonly property string label: "Web"
    readonly property int    limit: 3

    // Il n'existe pas de « moteur par défaut » au niveau du système sous Linux :
    // Chromium garde le sien dans sa propre base, pas dans un réglage lisible.
    // C'est donc un choix de configuration, et il tient sur ces trois lignes.
    readonly property var engines: [
        { id: "web",  name: "Google",          url: "https://www.google.com/search?q=%s" },
        { id: "nix",  name: "Options NixOS",   url: "https://search.nixos.org/options?query=%s" },
        { id: "gh",   name: "GitHub",          url: "https://github.com/search?q=%s" }
    ]

    signal produced(int seq, var items)

    // Une requête qui ressemble déjà à une adresse est proposée telle quelle,
    // en premier.
    function _asUrl(query) {
        var q = query.trim();
        if (/^https?:\/\/\S+$/i.test(q))
            return q;
        if (/^[\w-]+(\.[\w-]+)+(\/\S*)?$/.test(q) && q.indexOf(" ") === -1)
            return "https://" + q;
        return "";
    }

    function search(query, seq) {
        if (query.trim().length === 0) {
            src.produced(seq, []);
            return;
        }

        var out = [];
        var direct = _asUrl(query);

        if (direct.length > 0)
            out.push({
                type: src.type, id: "web:direct", title: direct,
                subtitle: "Ouvrir l'adresse", meta: "",
                tone: Theme.colorCyan, score: 900,
                payload: { url: direct }
            });

        for (var i = 0; i < src.engines.length && out.length < src.limit; i++) {
            var e = src.engines[i];
            out.push({
                type: src.type,
                id: "web:" + e.id,
                title: query,
                subtitle: e.name,
                meta: "",
                tone: Theme.colorCyan,
                // Toujours sous les résultats locaux : le web est un recours.
                score: 60 - i,
                payload: { url: e.url.replace("%s", encodeURIComponent(query)) }
            });
        }

        src.produced(seq, out);
    }

    // Le navigateur vient de DefaultApps, comme les outils de fichiers : il
    // suit le défaut du système.
    function activate(item, actionId) {
        if (actionId === "open")
            DefaultApps.openInBrowser(item.payload.url);
    }
}
