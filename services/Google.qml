pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Le compte Google : d'où l'onglet Agenda lit les événements et les tâches
// (anna/src/google/). Tout passe par `anna google …` :
//
//   status       l'état, relu à l'ouverture d'un réglage qui le montre, et
//                toutes les deux secondes pendant une connexion
//   client       l'identifiant OAuth que l'utilisateur a créé (Google n'ouvre
//                ses API qu'à une application déclarée chez lui)
//   connect      ouvre la page d'autorisation de Google dans le navigateur et
//                attend qu'on y autorise karenine (lancé détaché : il survit
//                à l'onglet qu'on ferme pour aller dans le navigateur)
//   cancel       abandonne cette attente
//   disconnect   révoque le jeton et l'oublie
//
// Le mot de passe de l'utilisateur ne passe jamais par ici : Google donne à
// anna un jeton, rangé dans le trousseau.
Singleton {
    id: google

    readonly property string anna: Quickshell.env("KARENINE_ANNA") || "anna"

    property bool known: false
    // L'identifiant OAuth est donné.
    property bool configured: false
    property bool connected: false
    property string email: ""
    // La connexion en cours : "pending" (le navigateur attend), "error", ou "".
    property string loginState: ""
    property string loginError: ""
    property string loginUrl: ""
    // L'identifiant refusé par anna (un fichier qui n'en est pas un…).
    property string clientError: ""

    // anna ne répond pas (absent, ou trop ancien pour connaître `google`) :
    // dit tel quel plutôt qu'une section vide.
    property string problem: ""

    readonly property bool pending: google.loginState === "pending"

    // Change à chaque connexion ou déconnexion : l'Agenda s'y recharge.
    property int generation: 0

    function refresh() {
        if (!status.running)
            status.running = true;
    }

    // L'ID et le secret, ou le chemin du JSON téléchargé de la console.
    function setClient(id, secret) {
        google.clientError = "";
        var args = [google.anna, "google", "client", id.trim().replace(/^~\//, Quickshell.env("HOME") + "/")];
        if (secret.trim() !== "")
            args.push(secret.trim());
        client.command = args;
        client.running = true;
    }

    function connect() {
        google.loginState = "pending";
        google.loginError = "";
        Quickshell.execDetached([google.anna, "google", "connect"]);
        poll.restart();
    }

    function cancel() {
        Quickshell.execDetached([google.anna, "google", "cancel"]);
        google.loginState = "";
    }

    function disconnect() {
        once.command = [google.anna, "google", "disconnect"];
        once.running = true;
    }

    // La page d'autorisation, rouverte (onglet fermé par mégarde).
    function reopen() {
        if (google.loginUrl !== "")
            Qt.openUrlExternally(google.loginUrl);
    }

    Process {
        id: status
        command: [google.anna, "google", "status"]
        stdout: StdioCollector { id: statusOut }
        onRunningChanged: {
            if (running)
                return;
            try {
                var r = JSON.parse(statusOut.text);
                if (!r.ok)
                    throw r.error;
                google.problem = "";
                var was = google.connected + "|" + google.email;
                google.configured = r.configured;
                google.connected = r.connected;
                google.email = r.email || "";
                google.loginState = r.login ? r.login.state : "";
                google.loginError = r.login ? r.login.error : "";
                google.loginUrl = r.login ? r.login.url : "";
                if (google.known && was !== google.connected + "|" + google.email)
                    google.generation++;
                google.known = true;
            } catch (e) {
                google.problem = I18n.tr("google.annaOutdated");
                google.known = true;
            }
        }
    }

    Process {
        id: client
        stdout: StdioCollector { id: clientOut }
        onRunningChanged: {
            if (running)
                return;
            try {
                var r = JSON.parse(clientOut.text);
                if (!r.ok)
                    google.clientError = r.error || I18n.tr("common.failedSentence");
            } catch (e) {
                google.clientError = I18n.tr("anna.noAnswer");
            }
            google.refresh();
        }
    }

    // `disconnect` attend la révocation : l'état est relu après.
    Process {
        id: once
        onRunningChanged: if (!running) google.refresh()
    }

    // Pendant une connexion, l'état est relu jusqu'à ce qu'elle aboutisse.
    Timer {
        id: poll
        interval: 2000
        repeat: true
        running: google.pending
        onTriggered: google.refresh()
    }

    Component.onCompleted: google.refresh()
}
