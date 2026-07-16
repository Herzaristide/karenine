pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pam
import "lock"
import "services"

// Écran de verrouillage (remplace hyprlock).
//
// Instance Quickshell distincte de shell.qml, lancée par hypridle/loginctl :
//   quickshell -p ~/.config/quickshell/lock.qml
//
// Elle est délibérément séparée de la barre — le shell peut planter ou être
// rechargé sans que la session se déverrouille, et inversement.
//
// ⚠ ext-session-lock-v1 garantit que le compositeur reste verrouillé si ce
// client meurt sans avoir déverrouillé. C'est la propriété de sécurité du
// protocole, mais elle implique qu'un plantage ici laisse un écran bleu
// irrécupérable autrement que par TTY (Ctrl+Alt+F2) ou SSH. Tester tout
// changement de ce fichier avec un TTY ouvert à côté.
ShellRoot {
    id: root

    readonly property string userName: Quickshell.env("USER") || "utilisateur"
    readonly property string primaryScreen: "DP-1"

    // Repassé aux surfaces : l'échec vient de PAM, mais le message d'accueil
    // par défaut vient d'ici.
    property string message: ""
    property bool messageIsError: false
    property bool busy: false

    // Mot de passe en attente d'être remis à PAM lors du prompt.
    property string pendingPassword: ""

    PamContext {
        id: pam

        // Correspond à security.pam.services.quickshell côté NixOS.
        config: "quickshell"
        user: root.userName

        onPamMessage: {
            // PAM réclame le mot de passe : on lui donne celui saisi.
            if (pam.responseRequired)
                pam.respond(root.pendingPassword);
            else if (pam.message.length > 0) {
                root.message = pam.message;
                root.messageIsError = pam.messageIsError;
            }
        }

        onCompleted: (result) => {
            root.busy = false;
            root.pendingPassword = "";

            if (result === PamResult.Success) {
                root.message = "";
                root.messageIsError = false;
                lock.locked = false;
                return;
            }

            root.messageIsError = true;
            root.message = result === PamResult.MaxTries ? "Trop de tentatives" : "Mauvais mot de passe";
        }

        onError: (error) => {
            root.busy = false;
            root.pendingPassword = "";
            root.messageIsError = true;
            root.message = "Erreur PAM : " + PamError.toString(error);
        }
    }

    function authenticate(password: string): void {
        if (root.busy || password.length === 0)
            return;

        root.pendingPassword = password;
        root.messageIsError = false;
        root.message = "";
        root.busy = true;

        if (!pam.start()) {
            root.busy = false;
            root.pendingPassword = "";
            root.messageIsError = true;
            root.message = "Impossible de démarrer PAM";
        }
    }

    WlSessionLock {
        id: lock

        locked: true

        // Le compositeur a confirmé le déverrouillage : ce process n'a plus de
        // raison d'être. Quitter avant la confirmation risquerait de laisser la
        // session verrouillée.
        onLockStateChanged: {
            if (!lock.locked)
                Qt.quit();
        }

        WlSessionLockSurface {
            id: surfaceWindow

            // Opaque dès la création, avant même que LockSurface ne soit monté :
            // une surface transparente laisserait voir le bureau si le QML
            // échouait à charger. L'input resterait bloqué par le compositeur,
            // mais le contenu de l'écran fuiterait.
            color: Theme.bgDeep

            LockSurface {
                anchors.fill: parent

                userName: root.userName
                message: root.message
                messageIsError: root.messageIsError
                busy: root.busy
                showWidgets: surfaceWindow.screen !== null && surfaceWindow.screen.name === root.primaryScreen

                onSubmitted: (password) => {
                    root.authenticate(password);
                    clearPassword();
                }

                Component.onCompleted: focusPassword()
            }
        }
    }
}
