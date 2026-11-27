"""What node_exporter does not tell of a server, for anna (servers.rs).

Prometheus text for node_exporter's textfile collector, in `extras.prom` in
the directory given as argument:

- the physical disks, with the filesystems they hold (through partitions,
  LUKS, LVM), and the users whose home directory lies on each;
- the MAC and LAN broadcast of the default interface, for Wake-on-LAN.

The GPUs are not here: each machine reads its own (`gpu.prom`), in its NixOS
configuration, since an NVIDIA card in offload and an AMD card are not read
alike. Run by a systemd timer next to node_exporter. Each part may fail
alone: it is then left out. The file is replaced atomically, so
node_exporter never serves half of it.
"""

import json
import os
import pwd
import subprocess
import sys


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def num(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def run(*args):
    try:
        return subprocess.run(
            args, capture_output=True, text=True, timeout=5, check=False
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


class Out:
    """The lines to write, grouped by metric (the text format wants each
    metric's samples together)."""

    def __init__(self):
        self.metrics = {}

    def add(self, metric, value, /, **labels):
        if value is None:
            return
        text = ",".join(
            '%s="%s"' % (k, str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n"))
            for k, v in labels.items()
        )
        self.metrics.setdefault(metric, []).append(
            "%s{%s} %s" % (metric, text, repr(float(value)))
        )

    def text(self):
        return "".join(line + "\n" for lines in self.metrics.values() for line in lines)


# ── Disks ───────────────────────────────────────────────────────────────────


def drives(out):
    """The physical disks of lsblk, each with the filesystems found under it.
    Swap in RAM, loops and optical drives are left out."""
    raw = run(
        "lsblk", "-b", "-J", "-l", "-o",
        "NAME,PKNAME,TYPE,SIZE,FSSIZE,FSUSED,MODEL,ROTA,TRAN,RM,HOTPLUG,MOUNTPOINTS",
    )
    try:
        nodes = json.loads(raw).get("blockdevices") or []
    except ValueError:
        return
    by_name = {n.get("name"): n for n in nodes}
    disks = {}
    for n in nodes:
        name = n.get("name") or ""
        if n.get("type") != "disk" or name.startswith(("zram", "loop", "ram", "sr")):
            continue
        tran = n.get("tran") or ""
        if tran == "nvme" or name.startswith("nvme"):
            kind = "NVMe"
        elif tran == "usb":
            kind = "USB"
        elif n.get("rota") in (True, "1", 1):
            kind = "HDD"
        else:
            kind = "SSD"
        model = (n.get("model") or "").replace("_", " ").strip() or name
        # One you unplug (USB key, SD card, external drive): it can be ejected.
        removable = tran == "usb" or any(
            n.get(k) in (True, "1", 1) for k in ("rm", "hotplug"))
        disks[name] = {"model": model, "kind": kind, "size": num(n.get("size")) or 0,
                       "removable": removable, "fs_size": 0, "fs_used": 0, "mounts": []}

    # Each filesystem counts once, on the disk it sits on.
    for n in nodes:
        fs_size = num(n.get("fssize"))
        if not fs_size:
            continue
        root = n.get("name") if n.get("type") == "disk" else None
        cur = n.get("pkname")
        for _ in range(16):
            parent = by_name.get(cur)
            if parent is None:
                break
            if parent.get("type") == "disk":
                root = cur
                break
            cur = parent.get("pkname")
        d = disks.get(root)
        if d is None:
            continue
        d["fs_size"] += fs_size
        d["fs_used"] += num(n.get("fsused")) or 0
        # Every mount of it (a btrfs volume has one per subvolume).
        for mount in n.get("mountpoints") or []:
            if mount and mount != "[SWAP]" and mount not in d["mounts"]:
                d["mounts"].append(mount)

    for name, d in disks.items():
        out.add("drive_info", 1, name=name, model=d["model"], kind=d["kind"],
                removable="1" if d["removable"] else "0")
        out.add("drive_size_bytes", d["size"], name=name)
        out.add("drive_fs_size_bytes", d["fs_size"], name=name)
        out.add("drive_fs_used_bytes", d["fs_used"], name=name)
        # The shortest mounts name the disk best (`/` before `/boot`); the
        # rest are often bind mounts of the same volume.
        for mount in sorted(d["mounts"], key=lambda m: (len(m), m))[:4]:
            out.add("drive_mount", 1, name=name, mount=mount)

    # Each user's home, on the disk of the longest mount that holds it.
    for user, home in users():
        best, length = None, -1
        for name, d in disks.items():
            for mount in d["mounts"]:
                prefix = mount.rstrip("/") + "/"
                if (home == mount or home.startswith(prefix)) and len(mount) > length:
                    best, length = name, len(mount)
        if best is not None:
            out.add("drive_home", 1, name=best, user=user, home=home)


def users():
    """The people who log in: a uid of a normal user (from 1000, below the
    systemd dynamic ones), a real shell and a home of their own. Read from
    the passwd database only: the service cannot see /home (ProtectHome)."""
    found = []
    for p in pwd.getpwall():
        shell = os.path.basename(p.pw_shell or "")
        if not 1000 <= p.pw_uid < 60000 or shell in ("nologin", "false", ""):
            continue
        home = p.pw_dir or ""
        if not home.startswith("/") or home in ("/", "/var/empty", "/nonexistent"):
            continue
        found.append((p.pw_name, home))
    return sorted(found, key=lambda u: u[1])


# ── Wake-on-LAN ─────────────────────────────────────────────────────────────


def wake(out):
    """The MAC and LAN broadcast of the interface that holds the default
    route: a sleeping machine cannot tell them, so anna keeps the last ones."""
    try:
        dev = json.loads(run("ip", "-j", "route", "get", "1.1.1.1"))[0]["dev"]
        link = json.loads(run("ip", "-j", "addr", "show", "dev", dev))[0]
    except (ValueError, IndexError, KeyError, TypeError):
        return
    if link.get("link_type") != "ether" or not link.get("address"):
        return
    broadcast = next(
        (a.get("broadcast") for a in link.get("addr_info") or []
         if a.get("family") == "inet" and a.get("broadcast")),
        "",
    )
    out.add("wake_info", 1, mac=link["address"], broadcast=broadcast)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: node-extras <textfile directory>")
    out = Out()
    for part in (drives, wake):
        try:
            part(out)
        except Exception as e:  # one part failing leaves the others
            print("%s: %s" % (part.__name__, e), file=sys.stderr)
    path = os.path.join(sys.argv[1], "extras.prom")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(out.text())
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


if __name__ == "__main__":
    main()
