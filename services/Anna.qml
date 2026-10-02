pragma Singleton
import QtQuick
import Quickshell

// Où joindre le daemon anna (anna/src/paths.rs côté Rust) : un seul endroit
// pour les widgets qui ouvrent un Socket dessus.
//
// XDG_RUNTIME_DIR est toujours posé dans une session Wayland — sans lui, ni
// le compositeur ni Quickshell ne tourneraient. Pas de repli sur un UID en dur.
Singleton {
    readonly property string socketPath: Quickshell.env("XDG_RUNTIME_DIR") + "/anna.sock"
}
