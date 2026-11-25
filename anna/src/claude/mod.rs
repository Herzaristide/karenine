//! The pilot and its voice, and the Claude Code sessions.
//!
//! The pilot (pilot.rs) is the conversation anna holds with a model (local
//! through Ollama, or an API), which acts on the desktop through the desk
//! tools (desk.rs).
//! It is spoken to (voice.rs, parakeet.rs, the wake word in wake.rs).
//!
//! The Claude Code sessions are followed (sessions.rs), their conversations
//! read (transcript.rs) and summed up — context, changes, outputs,
//! subagents and background jobs (summary.rs) —, and driven from the « Claude » tab as Claude
//! Desktop does (drive.rs): anna then runs a `claude` of its own on the
//! conversation. One started in a terminal stays the terminal's until the
//! tab takes it over.

pub mod desk;
pub mod drive;
pub mod mcp;
pub mod outputs;
pub mod parakeet;
pub mod pilot;
pub mod reglages;
pub mod sessions;
pub mod summary;
pub mod transcript;
pub mod voice;
pub mod wake;
