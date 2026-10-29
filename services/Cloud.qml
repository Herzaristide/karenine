pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Le compte Nextcloud (Murena, ou un autre serveur) : où vivent les notes et
// d'où l'onglet Agenda lit les événements (anna/src/cloud/). Tout passe par
// `anna cloud …` :
//
//   status       l'état, relu à l'ouverture d'un réglage qui le montre, et
//                toutes les deux secondes pendant une connexion
//   connect      ouvre la page de connexion du serveur dans le navigateur et
//                attend qu'on y autorise karenine (lancé détaché : il survit
//                à l'onglet qu'on ferme pour aller dans le navigateur)
//   cancel       abandonne cette attente
//   disconnect   révoque le mot de passe d'application et l'oublie
//
// Le mot de passe de l'utilisateur ne passe jamais par ici : le serveur
// donne à anna un mot de passe d'application, rangé dans le trousseau.
Singleton {
    id: cloud

    readonly property string anna: Quickshell.env("KARENINE_ANNA") || "anna"

    property bool known: false
    property bool connected: false
    property string server: ""
    property string user: ""
    property string defaultServer: "https://murena.io"
    // La connexion en cours : "pending" (le navigateur attend), "error", ou "".
    property string loginState: ""
    property string loginError: ""
    property string loginUrl: ""
    // La dernière synchro des notes (secondes Unix) et sa dernière erreur.
    property int notesLast: 0
    property string notesError: ""

    // anna ne répond pas (absent, ou trop ancien pour connaître `cloud`) :
    // dit tel quel plutôt qu'une section vide.
    property string problem: ""

    readonly property bool pending: cloud.loginState === "pending"

    // Change à chaque connexion ou déconnexion : l'Agenda s'y recharge.
    property int generation: 0

    function refresh() {
        if (!status.running)
            status.running = true;
    }

    function connect(server) {
        cloud.loginState = "pending";
        cloud.loginError = "";
        Quickshell.execDetached([cloud.anna, "cloud", "connect", server || cloud.defaultServer]);
        poll.restart();
    }

    function cancel() {
        Quickshell.execDetached([cloud.anna, "cloud", "cancel"]);
        cloud.loginState = "";
    }

    function disconnect() {
        once.command = [cloud.anna, "cloud", "disconnect"];
        once.running = true;
    }

    // La page de connexion, rouverte (onglet fermé par mégarde).
    function reopen() {
        if (cloud.loginUrl !== "")
            Qt.openUrlExternally(cloud.loginUrl);
    }

    Process {
        id: status
        command: [cloud.anna, "cloud", "status"]
        stdout: StdioCollector { id: statusOut }
        onRunningChanged: {
            if (running)
                return;
            try {
                var r = JSON.parse(statusOut.text);
                if (!r.ok)
                    throw r.error;
                cloud.problem = "";
                var was = cloud.connected + "|" + cloud.user + "|" + cloud.server;
                cloud.connected = r.connected;
                cloud.server = r.server || "";
                cloud.user = r.user || "";
                cloud.defaultServer = r.default_server || cloud.defaultServer;
                cloud.loginState = r.login ? r.login.state : "";
                cloud.loginError = r.login ? r.login.error : "";
                cloud.loginUrl = r.login ? r.login.url : "";
                cloud.notesLast = r.notes ? r.notes.last : 0;
                cloud.notesError = r.notes ? r.notes.error : "";
                if (cloud.known && was !== cloud.connected + "|" + cloud.user + "|" + cloud.server)
                    cloud.generation++;
                cloud.known = true;
            } catch (e) {
                cloud.problem = I18n.tr("cloud.annaOutdated");
                cloud.known = true;
            }
        }
    }

    // `disconnect` attend la révocation : l'état est relu après.
    Process {
        id: once
        onRunningChanged: if (!running) cloud.refresh()
    }

    // Pendant une connexion, l'état est relu jusqu'à ce qu'elle aboutisse.
    Timer {
        id: poll
        interval: 2000
        repeat: true
        running: cloud.pending
        onTriggered: cloud.refresh()
    }

    Component.onCompleted: cloud.refresh()
}
