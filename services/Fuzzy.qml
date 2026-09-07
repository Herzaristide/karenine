pragma Singleton
import QtQuick

// Scoring partagé par toutes les sources de recherche. Fonctions pures, aucun
// état : c'est ce qui permet aux sources de l'utiliser sans dépendre de Search
// (qui, lui, les instancie — l'inverse créerait un cycle d'import).
QtObject {
    // Un score de 0 signifie « pas de correspondance ». Les valeurs plus hautes
    // remontent dans la liste. Les paliers sont volontairement écartés : le type
    // de correspondance pèse plus que la longueur du texte.
    function score(query, text) {
        if (!text || text.length === 0)
            return 0;

        var q = (query || "").toLowerCase();
        var t = text.toLowerCase();

        if (q.length === 0)
            return 1;

        var i = t.indexOf(q);

        if (i === 0)
            return 1000 - Math.min(text.length, 200);

        if (i > 0) {
            // Un début de mot vaut bien mieux qu'un fragment au milieu.
            var prev = t.charAt(i - 1);
            var boundary = " -_./:".indexOf(prev) !== -1;
            return (boundary ? 700 : 400) - Math.min(i, 200);
        }

        return subsequence(q, t) ? 150 : 0;
    }

    // Toutes les lettres de la requête, dans l'ordre, mais pas contiguës.
    function subsequence(q, t) {
        var j = 0;
        for (var i = 0; i < t.length && j < q.length; i++)
            if (t.charAt(i) === q.charAt(j))
                j++;
        return j === q.length;
    }

    // Meilleur score parmi plusieurs champs, le premier champ étant le plus
    // significatif (titre) et les suivants pénalisés.
    function best(query, fields) {
        var top = 0;
        for (var i = 0; i < fields.length; i++) {
            var s = score(query, fields[i]);
            if (s > 0)
                s = Math.max(1, s - i * 60);
            if (s > top)
                top = s;
        }
        return top;
    }
}
