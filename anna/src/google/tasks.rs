//! The account's tasks (Google Tasks), for the « Agenda » tab and the
//! pilot's `agenda`.
//!
//!   anna tasks [list]                  → {"ok":true,"lists":[List…],"tasks":[Task…]}
//!   anna tasks done <list> <id> [no]   → checked off (or back to do)
//!   anna tasks create <list> <json>        → {"ok":true,"task":Task}
//!   anna tasks update <list> <id> <json>   → {"ok":true,"task":Task}
//!   anna tasks delete <list> <id>          → {"ok":true}
//!
//! `<list>`: an id, a list's title, or "" for the default one. `<json>`: a
//! `TaskInput` — on an update, only what changes; moving a task is giving it
//! a new `due` day ("" takes its date away).
//!
//! Every list, and in each its tasks: those to do, and those done but not
//! yet cleared in Google. Google keeps a task's due date only, never its
//! time: `due` is that day (`2026-10-22`), "" for a task without one.

use super::{encode, Account};
use serde::{Deserialize, Serialize};
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

// ── Writing ─────────────────────────────────────────────────────────────────

/// A new task, or what changes in one (every field may be left out of a
/// change). `due` is a day (`2026-11-20`), or "" for none.
#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct TaskInput {
    pub title: Option<String>,
    pub notes: Option<String>,
    pub due: Option<String>,
    pub done: Option<bool>,
}

/// Google keeps the day of `due` only, given as midnight UTC.
fn due_value(day: &str) -> Result<Value, String> {
    let d = day.trim();
    if d.is_empty() {
        return Ok(Value::Null);
    }
    match super::calendar::Stamp::day(d).filter(|s| s.time.is_none() && d.len() == 10) {
        Some(s) => Ok(json!(format!("{}T00:00:00.000Z", s.iso()))),
        None => Err(crate::i18n::tr("google.bad_dates")),
    }
}

fn body_of(input: &TaskInput) -> Result<Value, String> {
    let mut body = serde_json::Map::new();
    if let Some(t) = &input.title {
        body.insert("title".into(), json!(t));
    }
    if let Some(n) = &input.notes {
        body.insert("notes".into(), json!(n));
    }
    if let Some(d) = &input.due {
        body.insert("due".into(), due_value(d)?);
    }
    match input.done {
        Some(true) => {
            body.insert("status".into(), json!("completed"));
        }
        Some(false) => {
            body.insert("status".into(), json!("needsAction"));
            body.insert("completed".into(), Value::Null);
        }
        None => {}
    }
    Ok(Value::Object(body))
}

/// The list `text` names: its id, its title (any case), or the default one
/// when empty.
fn list_id(account: &mut Account, text: &str) -> Result<String, String> {
    let t = text.trim();
    if t.is_empty() || t == "@default" {
        return Ok("@default".into());
    }
    lists(&account.list(&format!("{API}/users/@me/lists?maxResults=100"))?)
        .into_iter()
        .find(|l| l.id == t || l.title.eq_ignore_ascii_case(t))
        .map(|l| l.id)
        .ok_or_else(|| crate::i18n::tr_args("google.unknown_list", &[("name", t)]))
}

pub fn create_task(list: &str, input: &TaskInput) -> Result<Task, String> {
    let mut account = Account::load()?;
    let list = list_id(&mut account, list)?;
    let url = format!("{API}/lists/{}/tasks", encode(&list));
    let v = account.call("POST", &url, Some(&body_of(input)?))?;
    tasks(&[v], &list)
        .pop()
        .ok_or_else(|| crate::i18n::tr("google.unknown_task"))
}

pub fn update_task(list: &str, id: &str, input: &TaskInput) -> Result<Task, String> {
    if id.is_empty() {
        return Err(crate::i18n::tr("google.unknown_task"));
    }
    let mut account = Account::load()?;
    let list = list_id(&mut account, list)?;
    let url = format!("{API}/lists/{}/tasks/{}", encode(&list), encode(id));
    let v = account.call("PATCH", &url, Some(&body_of(input)?))?;
    tasks(&[v], &list)
        .pop()
        .ok_or_else(|| crate::i18n::tr("google.unknown_task"))
}

pub fn delete_task(list: &str, id: &str) -> Result<(), String> {
    if id.is_empty() {
        return Err(crate::i18n::tr("google.unknown_task"));
    }
    let mut account = Account::load()?;
    let list = list_id(&mut account, list)?;
    let url = format!("{API}/lists/{}/tasks/{}", encode(&list), encode(id));
    account.call("DELETE", &url, None)?;
    Ok(())
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
        "create" => serde_json::from_str::<TaskInput>(arg(4))
            .map_err(|e| format!("tasks : {e}"))
            .and_then(|i| create_task(arg(3), &i))
            .map(|t| json!({ "ok": true, "task": t })),
        "update" => serde_json::from_str::<TaskInput>(arg(5))
            .map_err(|e| format!("tasks : {e}"))
            .and_then(|i| update_task(arg(3), arg(4), &i))
            .map(|t| json!({ "ok": true, "task": t })),
        "delete" => delete_task(arg(3), arg(4)).map(|()| json!({ "ok": true })),
        other => Err(format!("tasks : action inconnue « {other} »")),
    };
    let line = result.unwrap_or_else(|e| json!({ "ok": false, "error": e }));
    println!("{line}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_bodies_send_only_what_changes() {
        let moved = TaskInput {
            due: Some("2026-11-21".into()),
            ..Default::default()
        };
        assert_eq!(
            body_of(&moved).unwrap(),
            json!({ "due": "2026-11-21T00:00:00.000Z" })
        );
        let undated = TaskInput {
            due: Some(String::new()),
            ..Default::default()
        };
        assert_eq!(body_of(&undated).unwrap(), json!({ "due": null }));
        let reopened = TaskInput {
            done: Some(false),
            ..Default::default()
        };
        assert_eq!(
            body_of(&reopened).unwrap(),
            json!({ "status": "needsAction", "completed": null })
        );
        assert!(due_value("21/11").is_err());
    }

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
