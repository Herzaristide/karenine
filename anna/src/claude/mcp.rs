//! `anna mcp` — the MCP server (stdio) through which the pilot acts.
//!
//! Claude Code starts it for the pilot session (see pilot.rs) and talks
//! JSON-RPC 2.0 to it, one message per line. It lists the desk tools and
//! forwards each call to the daemon (`desk` command), which carries it out:
//! this process holds no state and runs no action itself.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

/// Revision announced when the client doesn't name one.
const PROTOCOL: &str = "2025-06-18";

/// A desk call may wait for the user's yes in the bar.
const CALL_TIMEOUT: Duration = Duration::from_secs(180);

fn call_daemon(tool: &str, args: &Value) -> (bool, String) {
    let attempt = || -> std::io::Result<Value> {
        let mut sock = UnixStream::connect(crate::paths::socket_path())?;
        sock.set_read_timeout(Some(CALL_TIMEOUT))?;
        let msg = json!({ "cmd": "desk", "tool": tool, "args": args });
        writeln!(sock, "{msg}")?;
        let mut line = String::new();
        BufReader::new(&sock).read_line(&mut line)?;
        serde_json::from_str(&line).map_err(std::io::Error::other)
    };
    match attempt() {
        Ok(r) => (
            r.get("ok").and_then(Value::as_bool).unwrap_or(false),
            r.get("text")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        ),
        Err(e) => (false, format!("anna injoignable : {e}")),
    }
}

/// The answer to one JSON-RPC message, or `None` for a notification.
pub fn handle(msg: &Value, call: impl Fn(&str, &Value) -> (bool, String)) -> Option<Value> {
    let id = msg.get("id")?.clone();
    let method = msg.get("method").and_then(Value::as_str).unwrap_or("");
    let result = match method {
        "initialize" => {
            let version = msg
                .pointer("/params/protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or(PROTOCOL);
            json!({
                "protocolVersion": version,
                "capabilities": { "tools": {} },
                "serverInfo": { "name": "anna", "version": env!("CARGO_PKG_VERSION") },
            })
        }
        "ping" => json!({}),
        "tools/list" => json!({ "tools": super::desk::tools() }),
        "tools/call" => {
            let name = msg
                .pointer("/params/name")
                .and_then(Value::as_str)
                .unwrap_or("");
            let args = msg
                .pointer("/params/arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            let (ok, text) = call(name, &args);
            json!({
                "content": [{ "type": "text", "text": text }],
                "isError": !ok,
            })
        }
        _ => {
            return Some(json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": -32601, "message": format!("méthode inconnue : {method}") },
            }))
        }
    };
    Some(json!({ "jsonrpc": "2.0", "id": id, "result": result }))
}

pub fn run() {
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let Ok(msg) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if let Some(reply) = handle(&msg, call_daemon) {
            if writeln!(stdout, "{reply}")
                .and_then(|()| stdout.flush())
                .is_err()
            {
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rpc(method: &str, params: Value) -> Value {
        json!({ "jsonrpc": "2.0", "id": 7, "method": method, "params": params })
    }

    #[test]
    fn speaks_the_mcp_handshake() {
        let r = handle(
            &rpc("initialize", json!({"protocolVersion": "2024-11-05"})),
            |_, _| unreachable!(),
        )
        .unwrap();
        assert_eq!(r["id"], 7);
        assert_eq!(r["result"]["protocolVersion"], "2024-11-05");
        assert!(r["result"]["capabilities"]["tools"].is_object());

        // Notifications get no answer.
        let n = json!({ "jsonrpc": "2.0", "method": "notifications/initialized" });
        assert!(handle(&n, |_, _| unreachable!()).is_none());
    }

    #[test]
    fn lists_and_forwards_tools() {
        let r = handle(&rpc("tools/list", json!({})), |_, _| unreachable!()).unwrap();
        assert!(r["result"]["tools"].as_array().unwrap().len() > 10);

        let r = handle(
            &rpc(
                "tools/call",
                json!({"name": "volume", "arguments": {"pourcentage": 30}}),
            ),
            |tool, args| {
                assert_eq!((tool, args["pourcentage"].as_i64()), ("volume", Some(30)));
                (true, "Volume: 0.30".into())
            },
        )
        .unwrap();
        assert_eq!(r["result"]["content"][0]["text"], "Volume: 0.30");
        assert_eq!(r["result"]["isError"], false);
    }

    #[test]
    fn unknown_methods_are_errors() {
        let r = handle(&rpc("resources/list", json!({})), |_, _| unreachable!()).unwrap();
        assert_eq!(r["error"]["code"], -32601);
    }
}
