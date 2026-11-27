//! `anna askpass <prompt>` (installed as `anna-askpass`): the askpass of
//! ssh, git and sudo, answered in karenine (prompts.rs).
//!
//! The program is pointed to by `SSH_ASKPASS`, `GIT_ASKPASS` and
//! `SUDO_ASKPASS`. They run it without a terminal to ask, with the question
//! as first argument, and read the answer on stdout. ssh says through
//! `SSH_ASKPASS_PROMPT` what it wants:
//!   - unset: a secret (a key's passphrase, a password), or for a host key
//!     « yes/no/[fingerprint] »;
//!   - `confirm`: yes or no, by the exit status (`ssh-add -c`);
//!   - `none`: nothing, a notice (« touch your security key ») that ssh
//!     kills once done.
//!
//! When anna or the shell cannot show it, the question goes to
//! `ANNA_ASKPASS_FALLBACK` (e.g. ksshaskpass), else the askpass fails.
//! The answer is written to stdout only, never logged.

use crate::i18n;
use crate::prompts::{wipe, Action, Field};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;

#[derive(Debug, PartialEq)]
enum Ask {
    /// A secret, hidden while typed.
    Secret,
    /// A visible text (a user name).
    Text,
    /// ssh's « Are you sure you want to continue connecting (yes/no/…)? »:
    /// the answer is the word.
    HostKey,
    /// Yes or no, by the exit status.
    Confirm,
    /// A notice, no answer.
    Notice,
}

fn classify(question: &str, mode: Option<&str>) -> Ask {
    match mode {
        Some("confirm") => return Ask::Confirm,
        Some("none") => return Ask::Notice,
        _ => {}
    }
    let q = question.to_lowercase();
    if q.contains("(yes/no") {
        Ask::HostKey
    } else if q.starts_with("username") {
        Ask::Text
    } else {
        Ask::Secret
    }
}

/// Who asks: "ssh", "git" or "sudo", from the programs above us.
fn who(chain: &[String], question: &str) -> &'static str {
    if chain.first().is_some_and(|c| c == "sudo") {
        "sudo"
    } else if chain.iter().any(|c| c.starts_with("git")) || question.contains("for 'http") {
        "git"
    } else {
        "ssh"
    }
}

/// The parent's name, then its parent's: `["ssh", "git"]`.
fn parents() -> Vec<String> {
    let mut out = Vec::new();
    let mut pid = std::process::id();
    for _ in 0..2 {
        let Some(ppid) = parent_of(pid) else { break };
        if ppid <= 1 {
            break;
        }
        match std::fs::read_to_string(format!("/proc/{ppid}/comm")) {
            Ok(c) => out.push(c.trim().to_string()),
            Err(_) => break,
        }
        pid = ppid;
    }
    out
}

fn parent_of(pid: u32) -> Option<u32> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // « pid (comm) state ppid … » — comm may hold spaces and parentheses.
    stat.rsplit_once(')')?
        .1
        .split_whitespace()
        .nth(1)?
        .parse()
        .ok()
}

/// What anna is sent to show `question`.
fn spec(question: &str, ask: &Ask, chain: &[String]) -> Value {
    let program = who(chain, question);
    let shown = question.trim().trim_end_matches(':').trim();
    let source = chain.iter().rev().cloned().collect::<Vec<_>>().join(" › ");
    let action = |id: &str, label: String, primary: bool| Action {
        id: id.into(),
        label,
        primary,
        danger: false,
    };
    let (title, fields, actions, kind) = match ask {
        Ask::Secret | Ask::Text => (
            match program {
                "git" => i18n::tr("askpass.git.title"),
                "sudo" => i18n::tr("askpass.sudo.title"),
                _ => i18n::tr("askpass.ssh.title"),
            },
            vec![Field {
                key: "answer".into(),
                kind: if *ask == Ask::Text {
                    "text"
                } else {
                    "password"
                }
                .into(),
                label: String::new(),
                value: String::new(),
                options: Vec::new(),
            }],
            vec![action("ok", i18n::tr("askpass.ok"), true)],
            program,
        ),
        Ask::HostKey => (
            i18n::tr("askpass.hostkey.title"),
            Vec::new(),
            vec![
                action("no", i18n::tr("askpass.no"), false),
                action("yes", i18n::tr("askpass.trust"), true),
            ],
            "confirm",
        ),
        Ask::Confirm => (
            i18n::tr("askpass.confirm.title"),
            Vec::new(),
            vec![
                action("no", i18n::tr("askpass.no"), false),
                action("yes", i18n::tr("askpass.yes"), true),
            ],
            "confirm",
        ),
        Ask::Notice => (
            i18n::tr("askpass.notice.title"),
            Vec::new(),
            Vec::new(),
            "notice",
        ),
    };
    json!({
        "cmd": "prompt_open",
        "prompt": {
            "kind": kind,
            "source": source,
            "title": title,
            "text": shown,
            "fields": fields,
            "actions": actions,
            "timeout": if *ask == Ask::Notice { 60 } else { 300 },
        }
    })
}

/// anna's answer, or None when it could not show the question.
fn ask_anna(request: &Value) -> Option<Value> {
    let mut stream = UnixStream::connect(crate::paths::socket_path()).ok()?;
    stream.write_all(format!("{request}\n").as_bytes()).ok()?;
    let mut line = String::new();
    BufReader::new(&stream).read_line(&mut line).ok()?;
    let reply: Option<Value> = serde_json::from_str(&line).ok();
    wipe(&mut line);
    let reply = reply?;
    if reply["ok"] == json!(false) && reply["error"] == json!("no_shell") {
        return None;
    }
    Some(reply)
}

/// Hand the question to the fallback askpass, or fail.
fn fallback(args: &[String]) -> ! {
    if let Some(prog) = std::env::var_os("ANNA_ASKPASS_FALLBACK").filter(|p| !p.is_empty()) {
        let err = std::process::Command::new(&prog).args(args).exec();
        eprintln!("anna askpass: {}: {err}", prog.to_string_lossy());
    }
    std::process::exit(1);
}

pub fn run(args: &[String]) -> ! {
    let rest = &args[2.min(args.len())..];
    let question = rest.join(" ");
    let mode = std::env::var("SSH_ASKPASS_PROMPT").ok();
    let ask = classify(&question, mode.as_deref());
    let chain = parents();

    let Some(reply) = ask_anna(&spec(&question, &ask, &chain)) else {
        fallback(rest);
    };
    let action = reply["action"].as_str().unwrap_or("cancel");
    if reply["ok"] != json!(true) || action == "cancel" {
        std::process::exit(1);
    }
    match ask {
        Ask::Secret | Ask::Text => {
            let mut answer = reply["values"]["answer"].as_str().unwrap_or("").to_string();
            let mut out = std::io::stdout().lock();
            let written = writeln!(out, "{answer}").and_then(|_| out.flush());
            wipe(&mut answer);
            std::process::exit(if written.is_ok() { 0 } else { 1 });
        }
        Ask::HostKey => {
            println!("{action}");
            std::process::exit(0);
        }
        Ask::Confirm => std::process::exit(if action == "yes" { 0 } else { 1 }),
        Ask::Notice => std::process::exit(0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn questions_are_told_apart() {
        assert_eq!(
            classify("Enter passphrase for key '/home/a/.ssh/id_ed25519': ", None),
            Ask::Secret
        );
        assert_eq!(
            classify("Username for 'https://github.com': ", None),
            Ask::Text
        );
        assert_eq!(
            classify(
                "Are you sure you want to continue connecting (yes/no/[fingerprint])? ",
                None
            ),
            Ask::HostKey
        );
        assert_eq!(classify("Allow use of key?", Some("confirm")), Ask::Confirm);
        assert_eq!(classify("Confirm user presence", Some("none")), Ask::Notice);
    }

    #[test]
    fn the_asker_is_found() {
        let c = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            who(&c(&["sudo", "fish"]), "[sudo] password for a: "),
            "sudo"
        );
        assert_eq!(who(&c(&["ssh", "git"]), "Enter passphrase"), "git");
        assert_eq!(
            who(&c(&["git-remote-http"]), "Password for 'https://a@b': "),
            "git"
        );
        assert_eq!(who(&c(&["ssh", "zed"]), "Enter passphrase"), "ssh");
    }

    #[test]
    fn a_secret_prompt_has_a_hidden_field() {
        let s = spec("Enter passphrase for key 'k': ", &Ask::Secret, &[]);
        assert_eq!(s["cmd"], "prompt_open");
        assert_eq!(s["prompt"]["text"], "Enter passphrase for key 'k'");
        assert_eq!(s["prompt"]["fields"][0]["kind"], "password");
        let parsed: crate::prompts::Spec = serde_json::from_value(s["prompt"].clone()).unwrap();
        assert_eq!(parsed.actions[0].id, "ok");
    }
}
