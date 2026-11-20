{ writers }:

# node_extras.py as a command, for node_exporter's textfile collector:
# `node-extras <directory>`, run by a systemd timer of the NixOS
# configuration. Its tools (lsblk, ip, systemctl) come from that service.
writers.writePython3Bin "node-extras" {
  flakeIgnore = [ "E501" ];
} (builtins.readFile ./node_extras.py)
