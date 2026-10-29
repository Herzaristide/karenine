//! The pilot and its voice.
//!
//! The pilot (pilot.rs) is a Claude session anna keeps warm, which acts on
//! the desktop through the desk tools (desk.rs, served to it by `anna mcp`).
//! It is spoken to (voice.rs, parakeet.rs, the wake word in wake.rs) and its
//! answers are read aloud (speech.rs).
//!
//! The Claude Code sessions themselves are left alone: they are started and
//! followed by hand, in a terminal.

pub mod desk;
pub mod mcp;
pub mod parakeet;
pub mod pilot;
pub mod speech;
pub mod voice;
pub mod wake;
