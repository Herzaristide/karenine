//! Where gestures land: uinput devices for the cursor and the window grab,
//! hyprctl for workspaces.
//!
//! Wayland gives no client the right to move the cursor, so the pointer is a
//! virtual input device — an absolute one, like a VM's USB tablet. Hyprland
//! maps absolute motion onto the bounding box of the whole monitor layout,
//! which is exactly the area the fingertip is meant to cover.
//!
//! A pinch grabs the window under the cursor rather than clicking: it holds
//! F24 on a second, keyboard-only virtual device, and Hyprland binds F24 as a
//! mouse bind to `hl.dsp.window.drag()` — the same interactive move as
//! Super + left drag. No button reaches the client, so nothing gets selected;
//! and no Super is involved, so the Super-tap bind (karenine's conversation
//! bar) can't fire on release.

use evdev::uinput::VirtualDevice;
use evdev::{
    AbsInfo, AbsoluteAxisCode, AttributeSet, EventType, InputEvent, KeyCode, UinputAbsSetup,
};
use serde::Deserialize;
use std::process::{Command, Stdio};

const ABS_MAX: i32 = 65535;

/// The key Hyprland binds to the window drag (see the module docs).
const GRAB_KEY: KeyCode = KeyCode::KEY_F24;

pub struct Pointer {
    dev: VirtualDevice,
    keys: VirtualDevice,
}

impl Pointer {
    pub fn new() -> std::io::Result<Self> {
        let axis = AbsInfo::new(0, 0, ABS_MAX, 0, 0, 1);
        // Never emitted, but libinput only takes an absolute device for a
        // pointer if it has a button.
        let mut buttons = AttributeSet::<KeyCode>::new();
        buttons.insert(KeyCode::BTN_LEFT);
        let dev = VirtualDevice::builder()?
            .name("anna gesture pointer")
            .with_keys(&buttons)?
            .with_absolute_axis(&UinputAbsSetup::new(AbsoluteAxisCode::ABS_X, axis))?
            .with_absolute_axis(&UinputAbsSetup::new(AbsoluteAxisCode::ABS_Y, axis))?
            .build()?;

        let mut grab = AttributeSet::<KeyCode>::new();
        grab.insert(GRAB_KEY);
        let keys = VirtualDevice::builder()?
            .name("anna gesture keys")
            .with_keys(&grab)?
            .build()?;
        Ok(Self { dev, keys })
    }

    /// Move to a point of the layout, in logical pixels.
    pub fn move_to(&mut self, layout: &Layout, x: f32, y: f32) -> std::io::Result<()> {
        let ax = ((x - layout.min_x) / layout.width() * ABS_MAX as f32).round() as i32;
        let ay = ((y - layout.min_y) / layout.height() * ABS_MAX as f32).round() as i32;
        self.dev.emit(&[
            InputEvent::new(
                EventType::ABSOLUTE.0,
                AbsoluteAxisCode::ABS_X.0,
                ax.clamp(0, ABS_MAX),
            ),
            InputEvent::new(
                EventType::ABSOLUTE.0,
                AbsoluteAxisCode::ABS_Y.0,
                ay.clamp(0, ABS_MAX),
            ),
        ])
    }

    /// Hold (or let go of) the window under the cursor.
    pub fn grab(&mut self, down: bool) -> std::io::Result<()> {
        self.keys
            .emit(&[InputEvent::new(EventType::KEY.0, GRAB_KEY.0, down as i32)])
    }
}

// ── Hyprland ────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct HyprMonitor {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    scale: f32,
    transform: u32,
    #[serde(default)]
    disabled: bool,
}

/// Bounding box of all monitors, in logical pixels. It is not necessarily
/// covered everywhere (monitors of different sizes leave holes): Hyprland
/// clamps a cursor aimed at a hole onto the nearest monitor.
#[derive(Clone, Debug)]
pub struct Layout {
    pub min_x: f32,
    pub min_y: f32,
    pub max_x: f32,
    pub max_y: f32,
}

impl Layout {
    pub fn width(&self) -> f32 {
        (self.max_x - self.min_x).max(1.0)
    }
    pub fn height(&self) -> f32 {
        (self.max_y - self.min_y).max(1.0)
    }

    /// Current layout from `hyprctl monitors -j`.
    pub fn query() -> Option<Self> {
        let out = Command::new("hyprctl")
            .args(["monitors", "-j"])
            .stderr(Stdio::null())
            .output()
            .ok()?;
        let mons: Vec<HyprMonitor> = serde_json::from_slice(&out.stdout).ok()?;

        let mut layout: Option<Layout> = None;
        for m in mons.iter().filter(|m| !m.disabled) {
            let (mut w, mut h) = (m.width / m.scale, m.height / m.scale);
            // Odd transforms are the 90°/270° ones.
            if m.transform % 2 == 1 {
                std::mem::swap(&mut w, &mut h);
            }
            let l = layout.get_or_insert(Layout {
                min_x: m.x,
                min_y: m.y,
                max_x: m.x + w,
                max_y: m.y + h,
            });
            l.min_x = l.min_x.min(m.x);
            l.min_y = l.min_y.min(m.y);
            l.max_x = l.max_x.max(m.x + w);
            l.max_y = l.max_y.max(m.y + h);
        }
        layout
    }
}

#[derive(Deserialize)]
struct HyprFocus {
    name: String,
    description: String,
    focused: bool,
    #[serde(rename = "activeWorkspace")]
    active: HyprWorkspaceRef,
}

#[derive(Deserialize)]
struct HyprWorkspaceRef {
    id: i64,
}

#[derive(Deserialize)]
struct HyprWorkspaceRule {
    #[serde(rename = "workspaceString")]
    workspace: String,
    monitor: Option<String>,
}

fn hyprctl_json<T: serde::de::DeserializeOwned>(what: &str) -> Option<T> {
    let out = Command::new("hyprctl")
        .args([what, "-j"])
        .stderr(Stdio::null())
        .output()
        .ok()?;
    serde_json::from_slice(&out.stdout).ok()
}

/// Step to the previous/next workspace *of the focused monitor*, as the config
/// assigns them: the numbered workspace rules bound to that monitor, by name
/// or by `desc:`. Relative targets (`r+1`) won't do — they walk every number
/// and create workspaces nobody asked for. A monitor with a single workspace
/// has nowhere to go; otherwise the ends wrap around (5 → 1, 1 → 5).
///
/// Lua dispatch syntax: under Hyprland's Lua parser the legacy
/// `dispatch workspace N` form is rejected, silently from a script.
pub fn switch_workspace(step: i32) {
    let Some(mons) = hyprctl_json::<Vec<HyprFocus>>("monitors") else {
        return;
    };
    let Some(mon) = mons.into_iter().find(|m| m.focused) else {
        return;
    };
    let Some(rules) = hyprctl_json::<Vec<HyprWorkspaceRule>>("workspacerules") else {
        return;
    };

    let mut ids: Vec<i64> = rules
        .iter()
        .filter(|r| match r.monitor.as_deref() {
            Some(m) => match m.strip_prefix("desc:") {
                Some(desc) => mon.description.starts_with(desc),
                None => m == mon.name,
            },
            None => false,
        })
        .filter_map(|r| r.workspace.parse().ok())
        .collect();
    ids.sort_unstable();
    ids.dedup();
    if ids.len() < 2 {
        return;
    }

    let current = mon.active.id;
    let target = match ids.iter().position(|&id| id == current) {
        // Wraps around: past the last comes the first, and back.
        Some(i) => ids[(i as i64 + step.signum() as i64).rem_euclid(ids.len() as i64) as usize],
        // On a workspace outside the monitor's set: land on the nearest end.
        None if step > 0 => ids[0],
        None => ids[ids.len() - 1],
    };

    let _ = Command::new("hyprctl")
        .args([
            "dispatch",
            &format!("hl.dsp.focus({{ workspace = {target} }})"),
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}
