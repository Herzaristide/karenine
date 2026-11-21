pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Les aperçus de l'Explorer : vidéos, sons, modèles 3D, PDF, partitions,
// MIDI, livres. Ils sont faits par `anna previews` (anna/src/previews.rs),
// un processus lancé une fois, au repos (nice, ionice), qu'on nourrit
// d'une ligne par fichier et qui répond quand l'aperçu est prêt.
//
// Le cache : ~/.cache/karenine/previews/<md5 de chemin|date|taille>.png
// (ou .svg pour une waveform ou une piano-roll, teinte au thème par qui
// l'affiche). Un fichier retouché change de nom : jamais d'aperçu périmé.
// Un échec est retenu (.fail), on ne réessaie pas.
//
// Une tuile demande (want) en apparaissant, et lit `results[clé]` en
// suivant `revision` : "" tant que rien, l'URL de l'aperçu ensuite.
Singleton {
    id: previews

    readonly property string anna: Quickshell.env("KARENINE_ANNA") || "anna"
    readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache"))
                                       + "/karenine/previews"

    // clé → URL de l'aperçu ("" : aucun). Mutée sur place, `revision`
    // signale chaque réponse aux liaisons.
    property var results: ({})
    property int revision: 0
    // Les clés demandées, pas encore répondues.
    property var pending: ({})

    // Les extensions qu'anna sait montrer, et leur sorte (pour l'affichage :
    // une photo se rogne au carré, une page ou une partition tient entière).
    readonly property var kinds: ({
        "mp4": "video", "m4v": "video", "mkv": "video", "webm": "video", "mov": "video", "avi": "video",
        "mpg": "video", "mpeg": "video", "flv": "video", "ogv": "video", "wmv": "video", "ts": "video",
        "m2ts": "video", "3gp": "video",
        "mp3": "audio", "flac": "audio", "ogg": "audio", "oga": "audio", "opus": "audio", "wav": "audio",
        "m4a": "audio", "aac": "audio", "aif": "audio", "aiff": "audio", "ape": "audio", "wv": "audio",
        "wma": "audio", "mka": "audio",
        "glb": "model", "gltf": "model", "obj": "model", "stl": "model", "ply": "model", "fbx": "model",
        "3mf": "model", "dae": "model", "3ds": "model", "usd": "model", "usda": "model", "usdc": "model",
        "usdz": "model",
        "pdf": "page", "epub": "page",
        "ly": "score", "musicxml": "score", "mxl": "score",
        "mid": "midi", "midi": "midi"
    })

    function kindOf(suffix) {
        return previews.kinds[(suffix || "").toLowerCase()] || "";
    }

    // La clé d'un fichier : son chemin, sa date et sa taille.
    function keyFor(path, modified, size) {
        var t = modified && modified.getTime ? modified.getTime() : 0;
        return Qt.md5(path + "|" + t + "|" + size);
    }

    function want(key, path) {
        if (key === "" || previews.results[key] !== undefined || previews.pending[key])
            return;
        previews.pending[key] = true;
        if (worker.running)
            worker.write(previews.cacheDir + "/" + key + "\t" + path + "\n");
    }

    // Le dossier a changé : ce qui attend encore ne sert plus.
    function clear() {
        previews.pending = ({});
        if (worker.running)
            worker.write("clear\n");
    }

    Process {
        id: worker
        command: ["ionice", "-c3", "nice", "-n", "19", previews.anna, "previews"]
        running: true
        stdinEnabled: true
        stdout: SplitParser {
            onRead: (line) => {
                var tab = line.indexOf("\t");
                if (tab < 0)
                    return;
                var base = line.substring(0, tab);
                var file = line.substring(tab + 1);
                var key = base.substring(base.lastIndexOf("/") + 1);
                delete previews.pending[key];
                previews.results[key] = file === "" ? "" : "file://" + file;
                previews.revision++;
            }
        }
        // Tombé (anna mis à jour, tué) : on le relance, et les demandes en
        // vol repartiront quand les tuiles redemanderont. Tombé aussitôt
        // lancé (un anna trop ancien, sans `previews`) : de plus en plus
        // tard, jusqu'à cinq minutes, plutôt qu'en boucle.
        property double startedAt: 0
        onRunningChanged: {
            if (running) {
                worker.startedAt = Date.now();
                return;
            }
            var quick = Date.now() - worker.startedAt < 5000;
            restart.interval = quick ? Math.min(restart.interval * 2, 300000) : 3000;
            restart.start();
        }
    }
    Timer {
        id: restart
        interval: 1500
        onTriggered: {
            previews.pending = ({});
            worker.running = true;
        }
    }
}
