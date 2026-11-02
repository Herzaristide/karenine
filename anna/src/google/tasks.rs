//! The account's tasks (Google Tasks), for the « Agenda » tab and the
//! pilot's `agenda`.
//!
//!   anna tasks [list]                  → {"ok":true,"lists":[List…],"tasks":[Task…]}
//!   anna tasks done <list> <id> [no]   → checked off (or back to do)
//!
//! Every list, and in each its tasks: those to do, and those done but not
//! yet cleared in Google. Google keeps a task's due date only, never its
//! time: `due` is that day (`2026-10-22`), "" for a task without one.

use super::{encode, Account};
use serde::Serialize;
use serde_json::{json, Value};

const API: &str = "https://tasks.googleapis.com/tasks/v1";

#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct List {
    pub id: String,
    pub title: String,
}

#[derive(Serialize, Debug, Clone, PartialEq, Default)]
pub struct Task {
    pub list: String,
    pub id: String,
    pub title: String,
    pub notes: String,
    pub due: String,
    pub done: bool,
    /// The task it is a subtask of, "" for a top one.
    pub parent: String,
    /// Its place among its siblings, as Google orders them.
    pub position: String,
}

fn s(v: &Value, k: &str) -> String {
    v.get(k).and_then(Value::as_str).unwrap_or("").to_string()
}

pub fn lists(items: &[Value]) -> Vec<List> {
    items
        .iter()
        .map(|l| List {
            id: s(l, "id"),
            title: s(l, "title"),
        })
        .collect()
}

/// One list's tasks, as Google lists them. Deleted ones are left out.
pub fn tasks(items: &[Value], list: &str) -> Vec<Task> {
    items
        .iter()
        .filter(|t| t.get("deleted").and_then(Value::as_bool) != Some(true))
        .map(|t| Task {
            list: list.to_string(),
            id: s(t, "id"),
            title: s(t, "title"),
            notes: s(t, "notes"),
            // `2026-10-22T00:00:00.000Z`: only the day means something.
            due: s(t, "due").chars().take(10).collect(),
            done: s(t, "status") == "completed",
            parent: s(t, "parent"),
            position: s(t, "position"),
        })
        .collect()
}

/// Every list, and every task of each.
pub fn all() -> Result<(Vec<List>, Vec<Task>), String> {
    let mut account = Account::load()?;
    let lists = lists(&account.list(&format!("{API}/users/@me/lists?maxResults=100"))?);
    let mut out = Vec::new();
    for l in &lists {
        let url = format!(
            "{API}/lists/{}/tasks?maxResults=100&showCompleted=true&showHidden=false",
            encode(&l.id)
        );
        out.extend(tasks(&account.list(&url)?, &l.id));
    }
    Ok((lists, out))
}

/// A task checked off, or back to do.
pub fn set_done(list: &str, id: &str, done: bool) -> Result<Task, String> {
    if list.is_empty() || id.is_empty() {
        return Err(crate::i18n::tr("google.unknown_task"));
    }
    let mut account = Account::load()?;
    let body = if done {
        json!({ "status": "completed" })
    } else {
        json!({ "status": "needsAction", "completed": null })
    };
    let url = format!("{API}/lists/{}/tasks/{}", encode(list), encode(id));
    let v = account.call("PATCH", &url, Some(&body))?;
    tasks(&[v], list)
        .pop()
        .ok_or_else(|| crate::i18n::tr("google.unknown_task"))
}

// ── The command line ────────────────────────────────────────────────────────

/// `anna tasks …`: one JSON line on stdout.
pub fn run(args: &[String]) {
    let arg = |i: usize| args.get(i).map(String::as_str).unwrap_or("");
    let result = match arg(2) {
        "" | "list" => {
            all().map(|(lists, tasks)| json!({ "ok": true, "lists": lists, "tasks": tasks }))
        }
        "done" => {
            set_done(arg(3), arg(4), arg(5) != "no").map(|t| json!({ "ok": true, "task": t }))
        }
        other => Err(format!("tasks : action inconnue « {other} »")),
    };
    let line = result.unwrap_or_else(|e| json!({ "ok": false, "error": e }));
    println!("{line}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tasks_are_read() {
        let items = vec![
            json!({ "id": "t1", "title": "Payer le loyer", "status": "needsAction",
                    "due": "2026-11-05T00:00:00.000Z", "position": "00000000000000000001" }),
            json!({ "id": "t2", "title": "Fait", "status": "completed", "notes": "ok",
                    "completed": "2026-11-01T10:00:00.000Z", "parent": "t1" }),
            json!({ "id": "t3", "title": "Effacé", "status": "needsAction", "deleted": true }),
        ];
        let ts = tasks(&items, "L1");
        assert_eq!(ts.len(), 2);
        assert_eq!(ts[0].due, "2026-11-05");
        assert!(!ts[0].done);
        assert_eq!(ts[0].list, "L1");
        assert!(ts[1].done);
        assert_eq!(ts[1].due, "");
        assert_eq!(ts[1].parent, "t1");
        assert_eq!(ts[1].notes, "ok");
    }

    #[test]
    fn lists_are_read() {
        let ls = lists(&[json!({ "id": "MDE", "title": "Mes tâches", "kind": "tasks#taskList" })]);
        assert_eq!(
            ls,
            vec![List {
                id: "MDE".into(),
                title: "Mes tâches".into()
            }]
        );
    }
}
