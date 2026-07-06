//! Thin CLI client for the `anna` daemon.
//!
//! Usage:
//!   anna set "#5277c3"   — change accent color
//!   anna mode dark       — switch to dark palette
//!   anna mode light      — switch to light palette
//!   anna get             — print current state as JSON
//!   anna watch           — stream state changes as JSON lines (Ctrl-C to stop)
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;

/// Handle a client subcommand. `args` is the full process argv
/// (`args[1]` is the subcommand, `args[2..]` its parameters).
pub fn run(args: &[String]) {
    let (cmd_json, is_watch) = match args.get(1).map(String::as_str) {
        Some("set") => {
            let color = args.get(2).cloned().unwrap_or_else(|| usage());
            (format!(r#"{{"cmd":"set_accent","color":"{color}"}}"#), false)
        }
        Some("mode") => {
            let mode = args.get(2).cloned().unwrap_or_else(|| usage());
            (format!(r#"{{"cmd":"set_mode","mode":"{mode}"}}"#), false)
        }
        Some("palette-color") => {
            let key = args.get(2).cloned().unwrap_or_else(|| usage());
            let color = args.get(3).cloned().unwrap_or_else(|| usage());
            let mode_part = match args.get(4) {
                Some(m) => format!(r#","mode":"{m}""#),
                None => String::new(),
            };
            (
                format!(
                    r#"{{"cmd":"set_palette_color","key":"{key}","color":"{color}"{mode_part}}}"#
                ),
                false,
            )
        }
        Some("get") => (r#"{"cmd":"get_state"}"#.into(), false),
        Some("watch") => (r#"{"cmd":"watch"}"#.into(), true),
        _ => usage(),
    };

    let socket_path = crate::socket_path();
    let mut stream = UnixStream::connect(&socket_path).unwrap_or_else(|e| {
        eprintln!("anna: cannot connect to {socket_path}: {e}");
        eprintln!("anna: is the daemon running?");
        std::process::exit(1);
    });

    writeln!(stream, "{cmd_json}").unwrap_or_else(|e| {
        eprintln!("anna: write error: {e}");
        std::process::exit(1);
    });

    let reader = BufReader::new(stream);
    for line in reader.lines() {
        match line {
            Ok(l) => println!("{l}"),
            Err(_) => break,
        }
        if !is_watch {
            break; // single-response commands read exactly one line
        }
    }
}

fn usage() -> ! {
    eprintln!(
        "Usage: anna <command> [args]\n\
         \n\
         Client commands:\n\
           set \"#rrggbb\"                          Change accent color\n\
           mode dark|light                         Switch dark/light palette\n\
           palette-color <key> \"#rrggbb\" [mode]    Set a base16 palette entry\n\
           get                                     Print current state as JSON\n\
           watch                                   Stream state changes as JSON lines"
    );
    std::process::exit(2);
}
