import QtQuick

// Une liste de clés pour un Repeater, mise à jour en place : à chaque
// relevé, on retire ce qui a disparu, on insère ce qui arrive et on déplace
// le reste, sans recréer les délégués qui restent. Leur survol, leur focus,
// leurs animations et leur état (une liste dépliée) survivent ; leurs
// données, ils les lisent par leur clé dans une table à part.
//
//   sync(keys, apply) : `apply` est appelé une fois les disparus retirés,
//   avant les insertions ; c'est là qu'on remplace la table, pour qu'aucun
//   délégué ne lise une clé qui n'y est plus.
ListModel {
    id: model

    function sync(keys, apply) {
        for (var i = model.count - 1; i >= 0; i--)
            if (keys.indexOf(model.get(i).key) < 0)
                model.remove(i);
        if (apply)
            apply();
        for (var n = 0; n < keys.length; n++) {
            var at = -1;
            for (var k = n; k < model.count; k++) {
                if (model.get(k).key === keys[n]) {
                    at = k;
                    break;
                }
            }
            if (at < 0)
                model.insert(n, { key: keys[n] });
            else if (at !== n)
                model.move(at, n, 1);
        }
    }
}
