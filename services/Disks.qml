pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Les disques physiques tels qu'anna les relève (servers_watch : lsblk de
// node-extras, SMART de smartctl_exporter), ramenés à une forme commune pour
// leur affichage (DiskTiles), dans l'Explorer comme dans la flotte ; et
// l'éjection d'un disque amovible de cette machine.
//
//   { machine ("" : celle-ci), host, hostLabel, name ("sdb"), label,
//     model, kind, used, size (octets), mounted, main, removable, smart,
//     homes: [{ user, path }] }  les dossiers personnels qu'il porte
Singleton {
    id: root

    // Ni /boot, ni /efi, ni le store : ce qu'on montre d'un disque.
    function shown(m) {
        return m.indexOf("/boot") !== 0 && m.indexOf("/efi") !== 0 && m.indexOf("/nix/store") !== 0;
    }
    // Son point de montage principal, "" s'il n'en a pas à montrer.
    function mainMount(mounts) {
        return (mounts || []).find(root.shown) || "";
    }

    // "ok", "watch" (usure ≥ 80 %, ou plus de 70 °C), "failing" (SMART en
    // échec) ou "unknown" (pas de SMART : un disque USB, ou un exporteur
    // qui ne peut pas le lire).
    function health(s) {
        if (!s)
            return "unknown";
        if (!s.ok)
            return "failing";
        if (s.wear >= 80 || s.temp >= 70)
            return "watch";
        return "ok";
    }

    // Les disques d'une machine, triés par nom. `mountedOnly` : seulement
    // ceux qui portent un système de fichiers à montrer (l'Explorer, où
    // chacun mène quelque part) ; sinon tous, un disque nu avec sa taille.
    function fromDrives(drives, machine, host, hostLabel, mountedOnly) {
        var now = Date.now();
        return (drives || [])
            .filter(d => !mountedOnly || (d.fs_size > 0 && root.mainMount(d.mounts) !== ""))
            .filter(d => machine !== "" || !root.ejected.some(e => e.name === d.name && now - e.at < 60000))
            .sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
            .map(d => ({
                machine: machine, host: host || "", hostLabel: hostLabel || "", name: d.name,
                // « Micron 3400 MTFDKBA1T0TFH » → « Micron 3400 ».
                label: (d.model || "").trim().split(/\s+/).slice(0, 2).join(" ") || d.name,
                model: (d.model || "").trim() || d.name,
                kind: d.kind || "",
                used: d.fs_size > 0 ? d.fs_used : 0,
                size: d.fs_size > 0 ? d.fs_size : (d.size || 0),
                mounted: d.fs_size > 0,
                main: d.fs_size > 0 ? root.mainMount(d.mounts) : "",
                removable: !!d.removable,
                smart: d.smart || null,
                // Ceux des utilisateurs qui vivent sur ce disque (le disque
                // système, ou celui de /home), vus par node-extras.
                homes: d.fs_size > 0 ? (d.homes || []).map(h => ({ user: h.user, path: h.path })) : []
            }));
    }

    // ── Éjecter un disque amovible (clé USB, carte SD, disque externe) ──
    // Chaque système de fichiers du disque est démonté (les plus profonds
    // d'abord), un conteneur LUKS refermé, puis le disque mis hors tension
    // par udisks : on peut le débrancher. Un fichier encore ouvert dessus
    // fait échouer le démontage ; l'erreur d'udisks est alors rendue.
    // Seulement sur cette machine.

    // Le disque en cours d'éjection (son nom, « sdb »), ou "".
    property string ejecting: ""
    // Ceux qu'on vient d'éjecter : [{ name, at }]. Ils restent dans
    // extras.prom jusqu'au prochain passage de son timer (15 s) : cachés
    // une minute.
    property var ejected: []
    // La dernière éjection ratée : son disque et pourquoi.
    property string error: ""
    property string errorDisk: ""

    // Juste avant : qui montre un dossier du disque en sort.
    signal aboutToEject(var disk)
    signal ejectDone(var disk)
    signal ejectFailed(var disk, string why)

    function canEject(d) {
        return !!d && d.removable && d.machine === "" && d.mounted;
    }

    function eject(d) {
        if (!root.canEject(d) || proc.running)
            return;
        root.aboutToEject(d);
        root.error = "";
        root.errorDisk = "";
        root.ejecting = d.name;
        proc.disk = d;
        proc.command = ["sh", "-c", root._script, "--", "/dev/" + d.name];
        proc.running = true;
    }

    // Les mappers (LUKS, LVM) se démontent avant les partitions, le disque
    // nu en dernier ; un volume monté plusieurs fois (btrfs) l'est jusqu'au
    // bout. Puis chaque LUKS se referme sur sa partition.
    readonly property string _script:
        "d=$1; sync\n" +
        "list=$(lsblk -lnpo TYPE,NAME,PKNAME \"$d\") || exit 1\n" +
        "for t in crypt lvm part disk; do\n" +
        "  printf '%s\\n' \"$list\" | while read -r ty n p; do\n" +
        "    [ \"$ty\" = \"$t\" ] || continue\n" +
        "    i=0\n" +
        "    while [ -n \"$(findmnt -rno TARGET -S \"$n\")\" ] && [ $i -lt 8 ]; do\n" +
        "      udisksctl unmount --no-user-interaction -b \"$n\" >/dev/null || exit 1\n" +
        "      i=$((i + 1))\n" +
        "    done\n" +
        "  done || exit 1\n" +
        "done\n" +
        "printf '%s\\n' \"$list\" | while read -r ty n p; do\n" +
        "  [ \"$ty\" = crypt ] || continue\n" +
        "  udisksctl lock --no-user-interaction -b \"$p\" >/dev/null || exit 1\n" +
        "done || exit 1\n" +
        "udisksctl power-off --no-user-interaction -b \"$d\" >/dev/null 2>&1 || true\n"

    Process {
        id: proc
        property var disk: null
        stderr: StdioCollector { id: err }
        onExited: (code, status) => { // qmllint disable signal-handler-parameters
            var d = proc.disk;
            root.ejecting = "";
            if (code === 0) {
                var now = Date.now();
                root.ejected = root.ejected.filter(e => now - e.at < 60000)
                                   .concat([{ name: d.name, at: now }]);
                root.ejectDone(d);
            } else {
                var why = err.text.trim().split("\n").pop();
                root.error = I18n.tr("explorer.cannotEject", { name: d.label }) + (why ? " : " + why : "");
                root.errorDisk = d.name;
                root.ejectFailed(d, why);
            }
        }
    }
}
