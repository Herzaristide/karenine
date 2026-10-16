pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Greetd
import "auth"
import "greeter"

// Écran de connexion (remplace regreet), lancé par greetd dans un Hyprland
// dédié :
//   quickshell -p <karenine>/greeter.qml
//
// Même carte que le lockscreen (auth/AuthCard) ; ici l'authentification passe
// par le socket greetd ($GREETD_SOCK) et non par PAM en direct, et la réussite
// lance la session au lieu de déverrouiller.
//
// Hors greetd (pas de $GREETD_SOCK), le fichier tourne en aperçu : rien n'est
// envoyé nulle part, et Échap quitte. Pratique pour retoucher le visuel depuis
// la session sans se déconnecter.
//
// Les trois valeurs ci-dessous sont des défauts substitués par la config Nix.
ShellRoot {
    id: root

    readonly property string primaryScreen: "DP-1"
    readonly property string defaultUser: "aristide"
    readonly property list<string> sessionCommand: ["start-hyprland"]
    readonly property string sessionName: "Hyprland"

    readonly property bool preview: !Greetd.available

    property string userName: root.defaultUser
    property string message: root.preview ? "Aperçu — greetd absent, Échap pour quitter" : ""
    property bool messageIsError: false
    property bool busy: false

    // Mot de passe saisi, remis à greetd à sa première demande.
    property string pendingSecret: ""
    // greetd réclame une réponse de plus (second facteur…) : la prochaine
    // saisie lui est envoyée telle quelle, avec son invite à la place du
    // « Mot de passe… ».
    property bool awaitingResponse: false
    property string prompt: "Mot de passe…"
    property bool echoInput: false

    // L'écran qui reçoit la carte : le primaire s'il est branché, sinon le
    // premier — un greeter sans carte nulle part serait une impasse.
    readonly property string cardScreen: {
        const screens = Quickshell.screens;
        for (let i = 0; i < screens.length; ++i) {
            if (screens[i].name === root.primaryScreen)
                return root.primaryScreen;
        }
        return screens.length > 0 ? screens[0].name : "";
    }

    function resetPrompt(): void {
        root.awaitingResponse = false;
        root.prompt = "Mot de passe…";
        root.echoInput = false;
    }

    function fail(text: string): void {
        root.busy = false;
        root.pendingSecret = "";
        root.resetPrompt();
        root.messageIsError = true;
        root.message = text;
    }

    function submit(user: string, secret: string): void {
        if (root.busy || secret.length === 0)
            return;

        if (root.preview) {
            root.fail("Aperçu : aucune session à ouvrir");
            return;
        }

        root.messageIsError = false;
        root.message = "";
        root.busy = true;

        if (root.awaitingResponse) {
            root.resetPrompt();
            Greetd.respond(secret);
            return;
        }

        root.userName = user;
        root.pendingSecret = secret;
        Greetd.createSession(user);
    }

    Connections {
        target: Greetd

        function onAuthMessage(message: string, error: bool, responseRequired: bool, echoResponse: bool): void {
            if (responseRequired) {
                if (root.pendingSecret.length > 0) {
                    const secret = root.pendingSecret;
                    root.pendingSecret = "";
                    Greetd.respond(secret);
                } else {
                    root.busy = false;
                    root.awaitingResponse = true;
                    root.prompt = message.trim() || "Réponse…";
                    root.echoInput = echoResponse;
                }
                return;
            }

            if (message.length > 0) {
                root.message = message;
                root.messageIsError = error;
            }
        }

        function onAuthFailure(message: string): void {
            root.fail("Mauvais mot de passe");
        }

        function onReadyToLaunch(): void {
            root.messageIsError = false;
            root.message = "Ouverture de la session…";
            Greetd.launch(root.sessionCommand, [], true);
        }

        function onError(error: string): void {
            root.fail("greetd : " + error);
            Greetd.cancelSession();
        }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow { // qmllint disable uncreatable-type
            id: window

            required property ShellScreen modelData
            readonly property bool hasCard: window.modelData.name === root.cardScreen

            screen: window.modelData
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "karenine-greeter"
            WlrLayershell.keyboardFocus: window.hasCard ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            // Transparente : le fond d'écran est la vidéo que mpvpaper joue
            // dessous, dans le Hyprland du greeter (modules/greetd.nix). Rien
            // à cacher ici, aucune session n'est encore ouverte.
            color: "transparent"

            GreeterSurface {
                id: surface

                anchors.fill: parent
                visible: window.hasCard

                userName: root.userName
                sessionName: root.sessionName
                message: root.message
                messageIsError: root.messageIsError
                busy: root.busy
                prompt: root.prompt
                echoInput: root.echoInput

                onSubmitted: (user, secret) => {
                    root.submit(user, secret);
                    surface.clearPassword();
                }

                Keys.onEscapePressed: {
                    if (root.preview)
                        Qt.quit();
                }

                Component.onCompleted: {
                    if (window.hasCard)
                        surface.focusPassword();
                }

                // L'écran à carte peut changer (moniteur branché tard) : le
                // focus suit la carte.
                Connections {
                    target: window
                    function onHasCardChanged(): void {
                        if (window.hasCard)
                            surface.focusPassword();
                    }
                }
            }

            // Les autres écrans gardent le fond, sans carte.
            AuthBackdrop {
                anchors.fill: parent
                visible: !window.hasCard
                seeThrough: true
            }
        }
    }
}
