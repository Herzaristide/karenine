pragma ComponentBehavior: Bound
import QtQuick
import "../services"

// Les actions du téléphone, au-dessus de son bouton dans la barre du bas :
// une colonne d'icônes qui sort de la barre (BarStack) — l'écran, la
// sonnerie, le presse-papier. Une action réussie change un instant son
// icône en coche ; une erreur s'écrit au-dessus. La carte complète (nom,
// réseau, jauge) reste dans l'onglet « Système » (widgets/PhoneWidget.qml) ;
// l'état vient de services/Phone.qml.
//
// Un téléphone qui demande à s'appairer propose ✓ et ✕, avec la clé
// au-dessus ; sans téléphone, la colonne dit ce qu'il faut faire.
BarStack {
    id: root

    readonly property var phone: Phone.phone
    // Ce que chaque action dit quand elle a réussi.
    readonly property var doneText: ({
        screen: I18n.tr("phone.openingScreen"), ring: I18n.tr("phone.ringing"),
        clipboard: I18n.tr("phone.clipboardSent"), accept: I18n.tr("phone.paired"), reject: ""
    })

    actions: Phone.connected ? [
        { name: "screen", glyph: "monitor.svg" },
        { name: "ring", glyph: "bell.svg" },
        { name: "clipboard", glyph: "clipboard.svg" }
    ] : root.phone !== null && !root.phone.paired ? [
        { name: "accept", glyph: "check.svg", success: true },
        { name: "reject", glyph: "close.svg" }
    ] : []

    message: root.phone === null
        ? (!Phone.loaded ? ""
           : !Phone.snapshot.running ? I18n.tr("phone.noDaemon")
           : I18n.tr("phone.nonePaired"))
        : Phone.failed && Phone.feedback !== "" ? Phone.feedback
        : Phone.hint
    messageColor: Phone.failed && Phone.feedback !== "" ? Theme.colorDanger : Theme.textDim

    // L'action en cours ; quand elle réussit, elle devient `done`.
    property string pending: ""
    onTriggered: (name) => {
        root.pending = name;
        Phone.act(name, "", root.doneText[name]);
    }
    Connections {
        target: Phone
        function onFeedbackChanged() {
            if (Phone.feedback !== "" && !Phone.failed && root.pending !== "") {
                root.done = root.pending;
                doneTimer.restart();
            }
            if (Phone.feedback !== "")
                root.pending = "";
        }
    }
    Timer {
        id: doneTimer
        interval: 1400
        onTriggered: root.done = ""
    }
}
