import QtQuick
import Quickshell
import Quickshell.Io

// La position du curseur, demandée à Hyprland sur son socket de requêtes :
// la même réponse que `hyprctl -j cursorpos`, sans lancer de processus. Une
// surface layer ne voit le curseur que quand il la survole ; ailleurs, c'est
// ici qu'on le lit (la barre de conversation, le dock IA).
//
//   probe()  →  measured(x, y), en coordonnées logiques comme celles des écrans
//
// Une requête par connexion : Hyprland répond puis ferme. On ferme dès la
// dernière ligne reçue, avant lui (sinon Quickshell journalise une erreur à
// chaque mesure).
QtObject {
    id: probe

    signal measured(real x, real y)

    readonly property bool running: sock.connected

    function probe() {
        if (!sock.connected) {
            probe._reply = "";
            sock.connected = true;
        }
    }

    property string _reply: ""

    property Socket _sock: Socket {
        id: sock
        path: Quickshell.env("XDG_RUNTIME_DIR") + "/hypr/"
              + Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") + "/.socket.sock"
        parser: SplitParser {
            onRead: (line) => {
                probe._reply += line;
                if (line.trim() !== "}")
                    return;
                sock.connected = false;
                try {
                    var p = JSON.parse(probe._reply);
                    probe.measured(p.x, p.y);
                } catch (e) { /* réponse inattendue : mesure perdue */ }
            }
        }
        onConnectedChanged: {
            if (connected) {
                write("j/cursorpos");
                flush();
            }
        }
    }
}
