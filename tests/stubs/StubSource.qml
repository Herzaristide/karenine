import QtQuick

// Une source de recherche factice : elle note ce qu'on lui demande, et le test
// émet lui-même `produced` pour simuler sa réponse (voir tst_search.qml).
QtObject {
    property string type: ""
    property string lastQuery: ""
    property int lastSeq: -1
    property var activated: null

    signal produced(int seq, var items)

    function search(query, seq) {
        lastQuery = query;
        lastSeq = seq;
    }

    function activate(item, actionId) {
        activated = { item: item, action: actionId };
    }
}
