pragma Singleton
import QtQuick

// Remplace services/I18n.qml (qui lit i18n/ via Quickshell) : rend la clé.
QtObject {
    function tr(key, args) {
        return key;
    }
    function trn(key, n, args) {
        return key;
    }
}
