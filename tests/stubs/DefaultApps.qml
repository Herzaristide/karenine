pragma Singleton
import QtQuick

// Remplace services/DefaultApps.qml : retient l'adresse au lieu de l'ouvrir.
QtObject {
    property string lastUrl: ""

    function openInBrowser(url) {
        lastUrl = url;
    }
}
