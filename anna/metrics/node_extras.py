"""What node_exporter does not tell of a server, for anna (servers.rs).

Prometheus text for node_exporter's textfile collector, in `extras.prom` in
the directory given as argument:

- the physical disks, with the filesystems they hold (through partitions,
  LUKS, LVM);
- the AI services (ComfyUI, Ollama) and what they are doing;
- the MAC and LAN broadcast of the default interface, for Wake-on-LAN.

The GPUs are not here: each machine reads its own (`gpu.prom`), in its NixOS
configuration, since an NVIDIA card in offload and an AMD card are not read
alike. Run by a systemd timer next to node_exporter. Each part may fail
alone: it is then left out. The file is replaced atomically, so
node_exporter never serves half of it.
"""

import json
import os
import subprocess
import sys
import urllib.request

# The services worth showing, as systemd names them (SERVICES in servers.rs).
SERVICES = ("comfyui", "ollama")


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


def fetch(url):
    try:
        with urllib.request.urlopen(url, timeout=1) as r:
            return json.load(r)
    except (OSError, ValueError):
        return None


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
        "NAME,PKNAME,TYPE,SIZE,FSSIZE,FSUSED,MODEL,ROTA,TRAN,MOUNTPOINTS",
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
        disks[name] = {"model": model, "kind": kind, "size": num(n.get("size")) or 0,
                       "fs_size": 0, "fs_used": 0, "mounts": []}

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
        out.add("drive_info", 1, name=name, model=d["model"], kind=d["kind"])
        out.add("drive_size_bytes", d["size"], name=name)
        out.add("drive_fs_size_bytes", d["fs_size"], name=name)
        out.add("drive_fs_used_bytes", d["fs_used"], name=name)
        # The shortest mounts name the disk best (`/` before `/boot`); the
        # rest are often bind mounts of the same volume.
        for mount in sorted(d["mounts"], key=lambda m: (len(m), m))[:4]:
            out.add("drive_mount", 1, name=name, mount=mount)


# ── Services ────────────────────────────────────────────────────────────────


def services(out):
    """The installed ones, with ComfyUI's queue and Ollama's loaded models
    when their API answers."""
    show = run(
        "systemctl", "show", "-p", "Id,LoadState,ActiveState",
        *(s + ".service" for s in SERVICES),
    )
    for block in show.split("\n\n"):
        field = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        name = field.get("Id", "").removesuffix(".service")
        if name not in SERVICES or field.get("LoadState") != "loaded":
            continue
        out.add("service_info", 1, name=name, state=field.get("ActiveState", ""))
        if name == "comfyui":
            q = fetch("http://127.0.0.1:8188/queue")
            if isinstance(q, dict):
                n = len(q.get("queue_running") or []) + len(q.get("queue_pending") or [])
                out.add("service_queue", n, name=name)
        elif name == "ollama":
            ps = fetch("http://127.0.0.1:11434/api/ps")
            for m in (ps or {}).get("models") or []:
                if m.get("name"):
                    out.add("service_model", 1, name=name, model=m["name"])


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
    for part in (drives, services, wake):
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
