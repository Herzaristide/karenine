pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Tailscale sur cette machine : l'état du nœud, l'allumer ou le couper, s'y
// connecter ou s'en déconnecter. Tout passe par le CLI `tailscale` du PATH
// système (celui de son démon), comme le Wi-Fi passe par nmcli :
//
//   status --json   l'état, relu toutes les 3 s tant qu'un volet le montre
//                   (`watchers`), toutes les secondes pendant une connexion
//   up / down       allume ou coupe le nœud (WantRunning), sans toucher au
//                   reste de ses réglages
//   login           demande à se connecter : le démon donne une URL
//                   d'autorisation, ouverte dans le navigateur ; le processus
//                   attend qu'on y valide et finit avec la connexion
//   logout          oublie le compte (le nœud devra être réautorisé)
//
// Sans droits sur le démon (ni root, ni « operator »), il refuse : l'erreur
// le dit, avec la commande qui donne ces droits.
Singleton {
    id: ts

    readonly property string user: Quickshell.env("USER") || ""

    // Le CLI a répondu au moins une fois ; `missing` : il n'y a pas de démon.
    property bool known: false
    property bool missing: false

    // « Running », « Stopped », « NeedsLogin », « NeedsMachineAuth »,
    // « Starting », « NoState »…
    property string backend: ""
    property string hostName: ""
    property string ip: ""
    property string tailnet: ""
    property string login: ""
    property int peersOnline: 0
    property string authUrl: ""

    // L'action en cours (« up », « down », « login », « logout ») et la
    // dernière erreur du CLI.
    property string busy: ""
    property string error: ""
    // L'erreur vient d'un refus de droits : les réglages proposent la commande.
    property bool denied: false

    readonly property bool running: ts.backend === "Running"
    readonly property bool loggedIn: ts.known && !ts.missing
                                     && ts.backend !== "NeedsLogin" && ts.backend !== "NoState" && ts.backend !== ""
    readonly property bool pendingLogin: ts.busy === "login" || ts.authUrl !== ""
    // L'état en une ligne, pour les volets.
    readonly property string stateText: ts.busy === "login" || ts.authUrl !== "" ? I18n.tr("tailscale.pending")
        : ts.busy === "up" || ts.backend === "Starting" ? I18n.tr("tailscale.starting")
        : ts.busy === "down" ? I18n.tr("tailscale.stopping")
        : ts.backend === "Running" ? (ts.ip !== "" ? ts.hostName + "  ·  " + ts.ip : ts.hostName)
        : ts.backend === "Stopped" ? I18n.tr("tailscale.stopped")
        : ts.backend === "NeedsMachineAuth" ? I18n.tr("tailscale.needsApproval")
        : I18n.tr("tailscale.loggedOut")
    // La commande qui donne les droits sur le démon (une fois pour toutes).
    readonly property string operatorCommand: "sudo tailscale set --operator=" + ts.user

    // Les volets ouverts qui montrent Tailscale : on ne relit qu'alors.
    property int watchers: 0

    function refresh() {
        if (!statusProc.running)
            statusProc.running = true;
    }

    function setRunning(on) {
        if (on === ts.running)
            return;
        // L'affichage suit tout de suite ; la relecture corrige.
        ts.backend = on ? "Starting" : "Stopped";
        ts.run(on ? "up" : "down", ["tailscale", on ? "up" : "down"]);
    }

    function toggle() {
        ts.setRunning(!ts.running);
    }

    function connect() {
        if (loginProc.running)
            return;
        ts.error = "";
        ts.denied = false;
        ts.busy = "login";
        loginProc.opened = false;
        loginProc.running = true;
    }

    function cancelLogin() {
        if (loginProc.running)
            loginProc.signal(15);
        ts.busy = "";
        ts.authUrl = "";
    }

    // La page d'autorisation, rouverte (onglet fermé par mégarde).
    function reopen() {
        if (ts.authUrl !== "")
            Qt.openUrlExternally(ts.authUrl);
    }

    function disconnect() {
        ts.run("logout", ["tailscale", "logout"]);
    }

    function run(what, cmd) {
        if (actProc.running)
            return;
        ts.error = "";
        ts.denied = false;
        ts.busy = what;
        actProc.command = cmd;
        actProc.running = true;
    }

    // La première ligne utile d'une erreur du CLI ; un refus de droits le note.
    function failed(text) {
        var t = text.trim();
        if (t === "")
            return;
        ts.denied = /access denied|permission denied|operator/i.test(t);
        ts.error = t.split("\n")[0].replace(/^(Error|error):\s*/, "");
    }

    Process {
        id: statusProc
        command: ["tailscale", "status", "--json"]
        stdout: StdioCollector { id: statusOut }
        stderr: StdioCollector { id: statusErr }
        onRunningChanged: {
            if (running)
                return;
            var r;
            try {
                r = JSON.parse(statusOut.text);
            } catch (e) {
                // Pas de JSON : pas de démon (ou pas de CLI).
                ts.missing = true;
                ts.backend = "";
                ts.known = true;
                return;
            }
            ts.missing = false;
            ts.known = true;
            ts.backend = r.BackendState || "";
            ts.authUrl = r.AuthURL || "";
            var self = r.Self || {};
            ts.hostName = self.HostName || "";
            ts.ip = (self.TailscaleIPs || []).find(a => a.indexOf(":") < 0) || "";
            ts.tailnet = r.CurrentTailnet ? r.CurrentTailnet.Name || "" : "";
            var u = r.User && self.UserID !== undefined ? r.User[self.UserID] : null;
            ts.login = u ? u.LoginName || "" : "";
            var peers = r.Peer || {};
            ts.peersOnline = Object.keys(peers).filter(k => peers[k].Online).length;
            // L'URL arrive par le statut aussi : ouverte une fois.
            if (ts.authUrl !== "" && loginProc.running && !loginProc.opened) {
                loginProc.opened = true;
                Qt.openUrlExternally(ts.authUrl);
            }
        }
    }

    Process {
        id: actProc
        stderr: StdioCollector { id: actErr }
        onRunningChanged: {
            if (running)
                return;
            ts.failed(actErr.text);
            ts.busy = "";
            ts.refresh();
        }
    }

    // `tailscale login` écrit l'URL d'autorisation sur stderr puis attend
    // qu'on la valide : elle s'ouvre dès qu'elle paraît.
    Process {
        id: loginProc
        property bool opened: false
        property string lastLine: ""
        command: ["tailscale", "login"]
        stderr: SplitParser {
            onRead: (line) => {
                var m = line.match(/https:\/\/\S+/);
                if (m && !loginProc.opened) {
                    loginProc.opened = true;
                    ts.authUrl = m[0];
                    Qt.openUrlExternally(m[0]);
                } else if (line.trim() !== "" && !m) {
                    loginProc.lastLine = line;
                }
            }
        }
        onRunningChanged: if (running) loginProc.lastLine = ""
        onExited: (exitCode, exitStatus) => { // qmllint disable signal-handler-parameters
            // Annulé (cancelLogin a déjà remis busy à "") : pas d'erreur.
            if (exitCode !== 0 && ts.busy === "login")
                ts.failed(loginProc.lastLine);
            ts.busy = "";
            ts.authUrl = "";
            ts.refresh();
        }
    }

    Timer {
        interval: ts.pendingLogin || ts.busy !== "" ? 1000 : 3000
        repeat: true
        running: ts.watchers > 0 || ts.pendingLogin
        triggeredOnStart: true
        onTriggered: ts.refresh()
    }

    Component.onCompleted: ts.refresh()
}
