pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Choix des écrans : celui qui porte l'interface (barre, panneaux, réglages)
// et celui du dock, qui suit le focus.
//
// Un écran est désigné par son modèle, pas par son connecteur : le même
// moniteur s'appelle DP-4 sur une machine et DP-3 sur l'autre, alors que son
// modèle ne change pas. Le numéro de série serait plus précis, mais Qt ne le
// remonte pas sous Wayland (il arrive vide) — deux moniteurs du même modèle
// se confondraient donc, ce qui ne se présente pas ici.
Singleton {
    id: display

    // Connecteur par défaut, fixé par shell.qml (substitué par la config Nix).
    property string defaultName: ""

    // Préférence de l'utilisateur, persistée : la clé d'un écran (cf.
    // screenKey), ou "" pour s'en remettre au défaut.
    readonly property string preferred: prefs.screen // qmllint disable unqualified

    FileView {
        path: Quickshell.dataPath("display.json")
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onAdapterUpdated: writeAdapter()

        JsonAdapter { // qmllint disable unresolved-type
            id: prefs
            property string screen: ""
        }
    }

    function screenKey(s) {
        return s ? (s.model || s.name) : "";
    }

    function setPreferred(key) {
        prefs.screen = key; // qmllint disable unqualified
    }

    function _byKey(key) {
        var ss = Quickshell.screens;
        for (var i = 0; i < ss.length; i++)
            if (ss[i] && display.screenKey(ss[i]) === key)
                return ss[i];
        return null;
    }

    function _byName(name) {
        var ss = Quickshell.screens;
        for (var i = 0; i < ss.length; i++)
            if (ss[i] && ss[i].name === name)
                return ss[i];
        return null;
    }

    // L'écran de l'interface. Repli en cascade : la préférence si l'écran est
    // branché, sinon le défaut, sinon le premier écran — il y a toujours une
    // barre, même quand l'écran attendu est absent (capot fermé, autre bureau).
    readonly property var primary: {
        var s = display.preferred !== "" ? display._byKey(display.preferred) : null;
        if (!s)
            s = display._byName(display.defaultName);
        if (!s && Quickshell.screens.length > 0)
            s = Quickshell.screens[0];
        return s;
    }

    // L'écran qui a le focus côté Hyprland, repli sur celui de l'interface.
    readonly property var focused: {
        var m = Hyprland.focusedMonitor;
        return (m ? display._byName(m.name) : null) || display.primary;
    }

    // ── Les workspaces principaux suivent l'écran de l'interface ─────────
    // La config Nix attache les workspaces principaux (1-5) à primaryMonitor,
    // par son connecteur — defaultName ici. Quand l'interface est ailleurs,
    // ils la suivent : leurs règles sont rattachées à cet écran (hyprctl eval
    // remplace la règle d'un workspace, il ne l'empile pas) et ceux qui
    // existent déjà y sont déplacés. Les autres écrans sont attachés par
    // `desc:` et ne sont pas concernés.
    //
    // Un `hyprctl reload` — anna en fait un à chaque changement d'accent —
    // remet les règles de la config : on les réapplique à chaque rechargement.

    onPrimaryChanged: Qt.callLater(display._syncWorkspaces)
    onDefaultNameChanged: Qt.callLater(display._syncWorkspaces)

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "configreloaded")
                Qt.callLater(display._syncWorkspaces);
        }
    }

    function _syncWorkspaces() {
        if (!display.primary || display.defaultName === "" || rulesProc.running)
            return;
        rulesProc.running = true;
    }

    Process {
        id: rulesProc
        command: ["hyprctl", "workspacerules", "-j"]
        stdout: StdioCollector {
            onStreamFinished: display._rebind(text)
        }
    }

    function _rebind(json) {
        var rules;
        try {
            rules = JSON.parse(json);
        } catch (e) {
            return;
        }
        var target = display.primary ? display.primary.name : "";
        if (target === "")
            return;

        // Les workspaces principaux : ceux attachés à defaultName. S'il n'y en
        // a plus, c'est qu'une instance précédente les a déjà déplacés — on les
        // retrouve alors comme les règles numérotées attachées par connecteur
        // (par opposition à `desc:`).
        var numbered = rules.filter(function (r) {
            return /^[0-9]+$/.test(r.workspaceString) && r.monitor;
        });
        var ours = numbered.filter(function (r) {
            return r.monitor === display.defaultName;
        });
        if (ours.length === 0)
            ours = numbered.filter(function (r) {
                return r.monitor.indexOf("desc:") !== 0;
            });

        var evals = [];
        var moves = [];
        ours.forEach(function (r) {
            if (r.monitor === target)
                return;
            evals.push("hl.workspace_rule({ workspace = \"" + r.workspaceString
                       + "\", monitor = \"" + target + "\""
                       + (r["default"] ? ", default = true" : "") + " })");
            moves.push("hyprctl dispatch 'hl.dsp.workspace.move({ workspace = \""
                       + r.workspaceString + "\", monitor = \"" + target + "\" })'");
        });
        if (evals.length === 0)
            return;

        // Les workspaces qui n'existent pas encore font échouer leur move sans
        // conséquence : la règle suffit à les créer au bon endroit.
        Quickshell.execDetached(["sh", "-c",
            "hyprctl eval '" + evals.join(" ") + "' >/dev/null; "
            + moves.map(function (m) { return m + " >/dev/null 2>&1"; }).join("; ")]);
    }
}
