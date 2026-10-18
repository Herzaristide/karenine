pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import QtCore
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io

// La langue de l'interface. Chaque langue est un fichier de i18n/ (`en.json`,
// `fr.json`…) : ajouter une langue, c'est déposer un fichier, rien d'autre.
// Son bloc `_meta` la nomme dans sa propre langue ; les autres clés sont les
// textes, lus par `I18n.tr(clé)`.
//
// Une clé absente de la langue choisie retombe sur l'anglais, puis sur la clé
// elle-même : une traduction partielle ne laisse jamais de trou.
//
// Le choix vit dans ~/.config/karenine/locale.json, partagé avec l'écran de
// verrouillage et avec anna (ses messages). KARENINE_LANG passe devant : le greeter tourne sous un autre utilisateur et
// reçoit sa langue de Nix.
//
// La langue de la voix est un réglage à part (on peut parler français à une
// interface en anglais) : celle de whisper et des réponses du pilote, lue par
// anna dans le même fichier. Vide : celle de l'interface ; "auto" : whisper la
// détecte.
Singleton {
    id: i18n

    readonly property string fallback: "en"

    readonly property string lang: Quickshell.env("KARENINE_LANG") || prefs.lang || i18n.fallback // qmllint disable unqualified

    // { code: dictionnaire }, rempli au fil du chargement des fichiers.
    property var dicts: ({})

    // Les langues proposées : [{ code, name }], triées par nom.
    readonly property var available: {
        var out = [];
        for (var code in i18n.dicts) {
            var meta = i18n.dicts[code]._meta || {};
            out.push({ code: code, name: meta.name || code });
        }
        out.sort(function (a, b) { return a.name.localeCompare(b.name); });
        return out;
    }

    readonly property var _strings: i18n.dicts[i18n.lang] || ({})
    readonly property var _fallbackStrings: i18n.dicts[i18n.fallback] || ({})

    // Pour les dates : `I18n.locale.toString(date, "dddd d MMMM")`.
    readonly property var locale: Qt.locale((i18n._strings._meta || {}).locale || "en_US")

    // Le texte de `key`, ses `{nom}` remplacés depuis `args`.
    function tr(key, args) {
        var s = i18n._strings[key];
        if (s === undefined)
            s = i18n._fallbackStrings[key];
        if (s === undefined)
            s = key;
        if (args)
            s = s.replace(/\{(\w+)\}/g, function (m, name) {
                return args[name] !== undefined ? String(args[name]) : m;
            });
        return s;
    }

    // `tr` avec un nombre : la forme `.one` de la clé pour 1, `.other` sinon.
    // `{n}` est le nombre.
    function trn(key, n, args) {
        var a = Object.assign({ n: n }, args || {});
        return i18n.tr(key + (Math.abs(n) === 1 ? ".one" : ".other"), a);
    }

    function setLang(code) {
        if (!i18n.dicts[code] || code === i18n.lang)
            return;
        prefs.lang = code; // qmllint disable unqualified
        mkdir.running = true;
    }

    // ── La langue de la voix ──────────────────────────────────────────────
    readonly property string voice: prefs.voice // qmllint disable unqualified

    // Les choix, dans l'ordre du sélecteur : [{ code, name }].
    readonly property var voiceChoices: {
        var current = i18n.available.find(l => l.code === i18n.lang);
        return [
            { code: "", name: i18n.tr("voice.sameAsInterface", { name: current ? current.name : i18n.lang }) },
            { code: "auto", name: i18n.tr("voice.auto") }
        ].concat(i18n.available);
    }

    function setVoice(code) {
        if (code === i18n.voice)
            return;
        prefs.voice = code; // qmllint disable unqualified
        mkdir.running = true;
    }

    // ── Les dictionnaires ─────────────────────────────────────────────────
    FolderListModel {
        id: files
        folder: "file://" + Quickshell.shellDir + "/i18n"
        nameFilters: ["*.json"]
        showDirs: false
    }

    Instantiator {
        model: files

        delegate: FileView {
            id: dict
            required property string fileName
            required property string filePath
            readonly property string code: fileName.replace(/\.json$/, "")

            path: filePath
            watchChanges: true
            onFileChanged: reload()
            onLoaded: {
                try {
                    var d = Object.assign({}, i18n.dicts);
                    d[dict.code] = JSON.parse(dict.text());
                    i18n.dicts = d;
                } catch (e) {
                    console.warn("i18n: " + dict.fileName + ": " + e);
                }
            }
        }
    }

    // ── Le choix ──────────────────────────────────────────────────────────
    readonly property string _dir: String(StandardPaths.writableLocation(StandardPaths.HomeLocation))
                                   .replace(/^file:\/\//, "") + "/.config/karenine"

    FileView {
        id: prefsFile
        path: i18n._dir + "/locale.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()

        JsonAdapter { // qmllint disable unresolved-type
            id: prefs
            property string lang: ""
            property string voice: ""
        }
    }

    // Le dossier n'existe peut-être pas encore : on le crée, puis on écrit.
    Process {
        id: mkdir
        command: ["mkdir", "-p", i18n._dir]
        onExited: prefsFile.writeAdapter() // qmllint disable signal-handler-parameters
    }
}
