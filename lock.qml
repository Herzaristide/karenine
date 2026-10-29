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

    readonly property string userName: Quickshell.env("USER") || I18n.tr("auth.user")
    readonly property string primaryScreen: "DP-1"

    // Vidéo de fond, posée par le lanceur (lock-session côté NixOS). Absente,
    // le fond reste uni.
    readonly property string wallpaper: Quickshell.env("KARENINE_WALLPAPER") || ""

    // Repassé aux surfaces : l'échec vient de PAM, mais le message d'accueil
    // par défaut vient d'ici.
    property string message: ""
    property bool messageIsError: false
    property bool busy: false

    // Mot de passe saisi avant que PAM ne le demande (howdy cherche encore le
    // visage) : remis à pam_unix dès son prompt.
    property string pendingPassword: ""

    // pam_unix attend le mot de passe et rien n'a encore été saisi.
    property bool awaitingPassword: false

    // La conversation PAM s'ouvre dès le verrouillage, sans attendre de saisie :
    // le premier module de security.pam.services.quickshell est howdy
    // (« sufficient »), qui allume la caméra IR et déverrouille si le visage
    // correspond. Sinon il passe la main à pam_unix, dont le prompt reste en
    // suspens jusqu'à ce qu'un mot de passe soit saisi. Sans howdy dans la
    // pile, pam_unix demande tout de suite : même comportement qu'avant.
    PamContext {
        id: pam

        // Correspond à security.pam.services.quickshell côté NixOS.
        config: "quickshell"
        user: root.userName

        onPamMessage: {
            if (pam.responseRequired) {
                faceHint.stop();
                if (root.pendingPassword.length > 0) {
                    const password = root.pendingPassword;
                    root.pendingPassword = "";
                    pam.respond(password);
                    return;
                }
                root.awaitingPassword = true;
                if (root.message === I18n.tr("lock.face"))
                    root.message = "";
                return;
            }

            if (pam.message.length > 0) {
                root.message = pam.message;
                // Un échec de howdy n'est pas une faute de frappe : la carte ne
                // tremble que pour un mot de passe soumis.
                root.messageIsError = root.busy && pam.messageIsError;
            }
        }

        onCompleted: (result) => {
            faceHint.stop();
            const tried = root.busy;
            root.busy = false;
            root.awaitingPassword = false;
            root.pendingPassword = "";

            if (result === PamResult.Success) {
                root.message = "";
                root.messageIsError = false;
                lock.locked = false;
                return;
            }

            root.messageIsError = true;
            root.message = result === PamResult.MaxTries ? I18n.tr("auth.tooManyTries") : I18n.tr("auth.wrongPassword");

            // Conversation suivante prête pour le prochain essai (et nouveau
            // passage de howdy). Pas si l'échec est venu sans saisie : on
            // bouclerait sur PAM.
            if (tried)
                root.begin();
        }

        onError: (error) => {
            faceHint.stop();
            root.busy = false;
            root.awaitingPassword = false;
            root.pendingPassword = "";
            root.messageIsError = true;
            root.message = I18n.tr("auth.pamError", { error: PamError.toString(error) });
        }
    }

    // « Reconnaissance faciale… » n'apparaît que si PAM ne réclame pas le mot
    // de passe aussitôt : sans howdy, le message ne clignote pas.
    Timer {
        id: faceHint
        interval: 400
        onTriggered: {
            if (pam.active && !root.awaitingPassword && !root.busy) {
                root.messageIsError = false;
                root.message = I18n.tr("lock.face");
            }
        }
    }

    // Ouvre une conversation PAM, donc un essai de visage.
    function begin(): void {
        if (pam.active)
            return;

        root.awaitingPassword = false;
        if (!pam.start()) {
            root.busy = false;
            root.pendingPassword = "";
            root.messageIsError = true;
            root.message = I18n.tr("auth.pamStart");
            return;
        }
        faceHint.restart();
    }

    // Retour devant l'écran : howdy a abandonné pendant l'absence et PAM attend
    // le mot de passe, on rouvre une conversation pour retenter le visage.
    // abort() ne déclenche pas onCompleted.
    function retryFace(): void {
        if (!root.awaitingPassword || root.busy)
            return;

        pam.abort();
        root.message = "";
        root.messageIsError = false;
        root.begin();
    }

    function authenticate(password: string): void {
        if (root.busy || password.length === 0)
            return;

        root.messageIsError = false;
        root.message = "";
        root.busy = true;
        faceHint.stop();

        if (root.awaitingPassword) {
            root.awaitingPassword = false;
            pam.respond(password);
            return;
        }

        // howdy cherche encore, ou pas de conversation : remis au prompt.
        root.pendingPassword = password;
        root.begin();
    }

    Component.onCompleted: root.begin()

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
                wallpaper: root.wallpaper
                showWidgets: surfaceWindow.screen !== null && surfaceWindow.screen.name === root.primaryScreen

                onWoke: root.retryFace()

                onSubmitted: (password) => {
                    root.authenticate(password);
                    clearPassword();
                }

                Component.onCompleted: focusPassword()
            }
        }
    }
}
