//! The pilot and its voice.
//!
//! The pilot (pilot.rs) is the conversation anna holds with a model (local
//! through Ollama, or an API), which acts on the desktop through the desk
//! tools (desk.rs).
//! It is spoken to (voice.rs, parakeet.rs, the wake word in wake.rs).
//!
//! The Claude Code sessions themselves are left alone: they are started and
//! followed by hand, in a terminal.

pub mod desk;
pub mod mcp;
pub mod parakeet;
pub mod pilot;
pub mod reglages;
pub mod sessions;
pub mod voice;
pub mod wake;
