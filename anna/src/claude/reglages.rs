//! The pilot's `reglage` tool: what the bar's panels and the settings tab
//! set by hand, by voice. Each setting goes through what the shell itself
//! uses — NetworkManager (`nmcli`), BlueZ (`bluetoothctl`), PipeWire
//! (`wpctl`, `pactl`), logind — so that the panels show the change at once.
//! The interface's language lives in the shell: it is sent over the FIFO.
//!
//! The theme and the wake word belong to the daemon itself: main.rs
//! `run_desk` handles them before calling `apply`.
//!
//! Rebooting and shutting down are never done by voice alone: a misheard
//! « éteins l'écran » must not power the machine off. They open the power
//! panel, whose buttons ask for a click.

use serde_json::Value;
use std::process::{Command, Stdio};

/// The settings, as the tool names them.
pub const NAMES: [&str; 13] = [
    "theme",
    "mot_activation",
    "langue",
    "langue_voix",
    "micro",
    "sortie_son",
    "entree_son",
    "wifi",
    "bluetooth",
    "bluetooth_connecter",
    "bluetooth_deconnecter",
    "bluetooth_profil",
    "alimentation",
];

fn run(cmd: &str, args: &[&str]) -> Result<String, String> {
    let out = Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("{cmd} : {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        Err(if err.is_empty() {
            format!("{cmd} a échoué")
        } else {
            err
        })
    }
}

/// Lowercase, without accents: how a spoken name is matched to a device.
fn fold(text: &str) -> String {
    text.to_lowercase()
        .chars()
        .map(|c| match c {
            'é' | 'è' | 'ê' | 'ë' => 'e',
            'à' | 'â' | 'ä' => 'a',
            'î' | 'ï' => 'i',
            'ô' | 'ö' => 'o',
            'ù' | 'û' | 'ü' => 'u',
            'ç' => 'c',
            '-' | '_' => ' ',
            c => c,
        })
        .collect()
}

/// Yes or no, however said.
fn yes_no(value: &str) -> Option<bool> {
    match fold(value.trim()).as_str() {
        "oui" | "on" | "active" | "activer" | "allume" | "allumer" | "true" | "1" => Some(true),
        "non" | "off" | "desactive" | "desactiver" | "eteint" | "eteindre" | "coupe" | "couper"
        | "false" | "0" => Some(false),
        _ => None,
    }
}

/// Words said for a kind of device, and what its name, id or type holds
/// then (« casque » for « JBL Endurance Peak 3 (audio-headset) »).
const KINDS: [(&str, &[&str]); 8] = [
    ("casque", &["casque", "headphone", "headset", "bluez"]),
    (
        "ecouteur",
        &["ecouteur", "headphone", "headset", "bluez", "buds"],
    ),
    ("parleur", &["haut parleur", "speaker"]),
    ("enceinte", &["enceinte", "speaker", "audio card"]),
    ("carte", &["usb"]),
    ("interface", &["usb"]),
    ("souris", &["mouse"]),
    ("clavier", &["keyboard"]),
];

/// Words that name no device in particular: « connecte mon Bluetooth ».
const VAGUE: [&str; 14] = [
    "oui",
    "mon",
    "ma",
    "mes",
    "le",
    "la",
    "les",
    "de",
    "du",
    "haut",
    "son",
    "bluetooth",
    "appareil",
    "peripherique",
];

/// What a device is called, without the id or type added for matching.
fn shown(label: &str) -> &str {
    label.split(" (").next().unwrap_or(label)
}

/// The labels of `items`, for a pilot that must name one of them.
fn labels<'a, T: 'a>(items: impl IntoIterator<Item = &'a (String, T)>) -> String {
    items
        .into_iter()
        .map(|(l, _)| format!("« {} »", shown(l)))
        .collect::<Vec<_>>()
        .join(", ")
}

/// The one of `items` (label: its name, then its id or type; value) meant
/// by `asked`: every word said is in its label, literally or — a word for a
/// kind of device (`KINDS`) — by one of its forms. Named literally wins.
/// Asked vaguely, or for none of them, the only item there is; several that
/// fit, the pilot is told which, to ask the user.
fn pick<'a, T>(items: &'a [(String, T)], asked: &str) -> Result<&'a T, String> {
    let words: Vec<String> = fold(asked)
        .split_whitespace()
        .filter(|w| !VAGUE.contains(w))
        .map(str::to_string)
        .collect();
    let by_kind = |label: &str, word: &str| {
        KINDS
            .iter()
            .any(|(w, forms)| word.contains(w) && forms.iter().any(|f| label.contains(f)))
    };
    let fits = |literal: bool| -> Vec<&'a (String, T)> {
        items
            .iter()
            .filter(|(label, _)| {
                let l = fold(label);
                words
                    .iter()
                    .all(|w| l.contains(w.as_str()) || (!literal && by_kind(&l, w)))
            })
            .collect()
    };
    let found = if words.is_empty() {
        Vec::new()
    } else {
        let literal = fits(true);
        if literal.is_empty() {
            fits(false)
        } else {
            literal
        }
    };
    match found.as_slice() {
        [] => match items {
            [(_, only)] => Ok(only),
            [] => Err("aucun appareil".into()),
            _ if words.is_empty() => Err(format!("lequel ? il y a : {}", labels(items))),
            _ => Err(format!(
                "aucun appareil « {asked} » ; il y a : {}",
                labels(items)
            )),
        },
        [(_, one)] => Ok(one),
        // The same device twice (a keyboard paired on two channels).
        [(first, v), rest @ ..] if rest.iter().all(|(l, _)| shown(l) == shown(first)) => Ok(v),
        several => Err(format!(
            "plusieurs appareils pour « {asked} » : {} — demande lequel",
            labels(several.iter().copied())
        )),
    }
}

/// Apply setting `name` to `value`; what to tell the pilot.
pub fn apply(
    name: &str,
    value: &str,
    shell_send: impl Fn(&str) -> Result<(), String>,
) -> Result<String, String> {
    let value = value.trim();
    match name {
        "langue" => {
            let code = fold(value);
            let known = crate::i18n::available();
            if !known.contains(&code) {
                return Err(format!("langue « {value} » : {}", known.join(", ")));
            }
            shell_send(&format!("reglage:langue:{code}\n"))?;
            Ok(format!("interface en {code}"))
        }
        "langue_voix" => {
            let code = match fold(value).as_str() {
                "interface" | "meme" | "" => String::new(),
                c => c.to_string(),
            };
            let known = crate::i18n::available();
            if !code.is_empty() && code != "auto" && !known.contains(&code) {
                return Err(format!(
                    "langue de la voix « {value} » : interface, auto, {}",
                    known.join(", ")
                ));
            }
            shell_send(&format!("reglage:langue_voix:{code}\n"))?;
            Ok(match code.as_str() {
                "" => "la voix suit la langue de l'interface".into(),
                "auto" => "langue de la voix détectée".into(),
                c => format!("voix en {c}"),
            })
        }
        "micro" => {
            let mute = match fold(value).as_str() {
                "muet" | "coupe" | "couper" | "off" | "non" => true,
                "actif" | "active" | "allume" | "on" | "oui" | "remettre" => false,
                _ => return Err("micro : « muet » ou « actif »".into()),
            };
            run(
                "wpctl",
                &[
                    "set-mute",
                    "@DEFAULT_AUDIO_SOURCE@",
                    if mute { "1" } else { "0" },
                ],
            )?;
            Ok(if mute { "micro coupé" } else { "micro actif" }.into())
        }
        "sortie_son" | "entree_son" => {
            let (kind, set) = if name == "sortie_son" {
                ("sinks", "set-default-sink")
            } else {
                ("sources", "set-default-source")
            };
            let list: Value = serde_json::from_str(&run("pactl", &["-f", "json", "list", kind])?)
                .map_err(|e| format!("pactl : {e}"))?;
            let devices: Vec<(String, String)> = list
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|d| {
                    let id = d["name"].as_str()?.to_string();
                    // Not the monitors of the outputs, nor the echo canceller's
                    // inner nodes.
                    if id.ends_with(".monitor") || id.starts_with("capture.") {
                        return None;
                    }
                    let label = d["description"].as_str().unwrap_or(&id).to_string();
                    // Its id too: « bluez_output… » says it is a headset.
                    Some((format!("{label} ({id})"), id))
                })
                .collect();
            let id = pick(&devices, value)?;
            run("pactl", &[set, id])?;
            let label = devices
                .iter()
                .find(|(_, i)| i == id)
                .map_or("", |(l, _)| shown(l));
            Ok(format!(
                "{} : {label}",
                if name == "sortie_son" {
                    "sortie"
                } else {
                    "entrée"
                }
            ))
        }
        "wifi" => match yes_no(value) {
            Some(on) => {
                run("nmcli", &["radio", "wifi", if on { "on" } else { "off" }])?;
                Ok(if on { "Wi-Fi activé" } else { "Wi-Fi coupé" }.into())
            }
            // A network's name: join it, if it is known (its password saved).
            None => match run("nmcli", &["device", "wifi", "connect", value]) {
                Ok(_) => Ok(format!("connecté à {value}")),
                Err(e) => {
                    // A password to type: the Wi-Fi panel, where it is asked.
                    let _ = shell_send("widget:wifi:ouvrir\n");
                    Err(format!(
                        "{e} — le volet Wi-Fi est ouvert pour s'y connecter"
                    ))
                }
            },
        },
        "bluetooth" => {
            let on = yes_no(value).ok_or("bluetooth : oui ou non")?;
            run("bluetoothctl", &["power", if on { "on" } else { "off" }])?;
            Ok(if on {
                "Bluetooth activé"
            } else {
                "Bluetooth coupé"
            }
            .into())
        }
        "bluetooth_connecter" | "bluetooth_deconnecter" => {
            let connect = name == "bluetooth_connecter";
            let listed = run(
                "bluetoothctl",
                &["devices", if connect { "Paired" } else { "Connected" }],
            )?;
            // « Device AA:BB:CC:DD:EE:FF Name with spaces »
            let devices: Vec<(String, String)> = listed
                .lines()
                .filter_map(|l| {
                    let rest = l.strip_prefix("Device ")?;
                    let (addr, label) = rest.split_once(' ')?;
                    // Its type as BlueZ says it (audio-headset, input-mouse…):
                    // « mon casque » finds a device whose name doesn't say so.
                    let icon = run("bluetoothctl", &["info", addr])
                        .ok()
                        .and_then(|info| {
                            info.lines()
                                .find_map(|l| l.trim().strip_prefix("Icon: ").map(str::to_string))
                        })
                        .unwrap_or_default();
                    Some((format!("{label} ({icon})"), addr.to_string()))
                })
                .collect();
            let addr = if !connect && (value.is_empty() || fold(value) == "tout") {
                None
            } else {
                if devices.is_empty() {
                    return Err(format!(
                        "aucun appareil {}",
                        if connect { "appairé" } else { "connecté" }
                    ));
                }
                Some(pick(&devices, value)?)
            };
            if connect {
                let addr = addr.expect("connect names one");
                run("timeout", &["20", "bluetoothctl", "connect", addr])?;
            } else {
                for (_, a) in devices.iter().filter(|(_, a)| addr.is_none_or(|x| x == a)) {
                    run("timeout", &["10", "bluetoothctl", "disconnect", a])?;
                }
            }
            let label = addr
                .and_then(|a| devices.iter().find(|(_, x)| x == a))
                .map_or("tout", |(l, _)| shown(l));
            Ok(format!(
                "{label} {}",
                if connect { "connecté" } else { "déconnecté" }
            ))
        }
        "bluetooth_profil" => {
            let call = match fold(value).as_str() {
                "appel" | "appels" | "call" | "micro" => true,
                "musique" | "music" | "audio" => false,
                _ => return Err("profil : « musique » ou « appel »".into()),
            };
            let cards: Value =
                serde_json::from_str(&run("pactl", &["-f", "json", "list", "cards"])?)
                    .map_err(|e| format!("pactl : {e}"))?;
            let (card, profile, addr) = bluetooth_profile(&cards, call)
                .ok_or("aucun appareil Bluetooth connecté qui ait ce profil")?;
            if call {
                // As the Bluetooth panel does (BluetoothMenu.qml): the
                // headset's microphone becomes the default input once
                // PipeWire has created it.
                run("sh", &["-c", CALL_SCRIPT, "sh", &card, &profile, &addr])?;
            } else {
                run("pactl", &["set-card-profile", &card, &profile])?;
            }
            Ok(if call {
                "profil appel"
            } else {
                "profil musique"
            }
            .into())
        }
        "alimentation" => match fold(value).as_str() {
            "verrouiller" | "verrouille" | "lock" => {
                run("loginctl", &["lock-session"])?;
                Ok("session verrouillée".into())
            }
            "veille" | "mettre en veille" | "suspend" => {
                run("systemctl", &["suspend"])?;
                Ok("mise en veille".into())
            }
            "redemarrer" | "eteindre" | "reboot" | "poweroff" => {
                shell_send("widget:alimentation:ouvrir\n")?;
                Ok("le volet d'alimentation est ouvert : à confirmer d'un clic".into())
            }
            _ => Err("alimentation : verrouiller, veille, redemarrer ou eteindre".into()),
        },
        _ => Err(format!("réglage inconnu « {name} » : {}", NAMES.join(", "))),
    }
}

/// BluetoothMenu.qml's `callScript`: the profile, then the headset's
/// microphone as the default input, waited for (5 s at most).
const CALL_SCRIPT: &str = "pactl set-card-profile \"$1\" \"$2\" || exit 1; \
    a=$(printf %s \"$3\" | tr : _); i=0; \
    while [ $i -lt 20 ]; do \
    n=$(pactl list short sources | awk -v p=\"bluez_input.$a\" \
    'index($2, p) == 1 && $2 !~ /\\.monitor$/ { print $2; exit }'); \
    [ -n \"$n\" ] && exec pactl set-default-source \"$n\"; \
    sleep 0.25; i=$((i + 1)); done";

/// The Bluetooth card to switch, its best available profile of the kind
/// asked (music: A2DP; call: a headset unit with a microphone), and the
/// device's address — the first connected device that has one.
fn bluetooth_profile(cards: &Value, call: bool) -> Option<(String, String, String)> {
    cards.as_array()?.iter().find_map(|c| {
        let addr = c["properties"]["api.bluez5.address"].as_str()?;
        let best = c["profiles"]
            .as_object()?
            .iter()
            .filter(|(key, p)| {
                p["available"].as_bool().unwrap_or(false)
                    && if call {
                        key.starts_with("headset-head-unit") && p["sources"].as_u64() > Some(0)
                    } else {
                        key.starts_with("a2dp-sink")
                    }
            })
            .max_by_key(|(_, p)| p["priority"].as_i64().unwrap_or(0))?;
        Some((
            c["name"].as_str()?.to_string(),
            best.0.clone(),
            addr.to_string(),
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_device_is_found_by_the_words_said() {
        let p = |items: &[(String, &'static str)], asked: &str| pick(items, asked).ok().copied();
        // This machine's outputs (21/11/2026), name and id.
        let sinks: Vec<(String, &str)> = [
            ("Steinberg UR242 Analog Stereo (alsa_output.usb-Yamaha_Corporation_Steinberg_UR242-00.analog-stereo)", "ur242"),
            ("500 Series Chipset Family HD Audio HDMI / DisplayPort 1 Output (Stereo) (alsa_output.pci.HiFi__HDMI1__sink)", "hdmi1"),
            ("500 Series Chipset Family HD Audio Speaker (alsa_output.pci.HiFi__Speaker__sink)", "speaker"),
            ("GA104 High Definition Audio Controller Digital Stereo (HDMI) [C27R50x] (alsa_output.pci-0000_01_00.1.hdmi-stereo)", "c27"),
        ]
        .into_iter()
        .map(|(l, v)| (l.to_string(), v))
        .collect();
        assert_eq!(p(&sinks, "haut-parleurs"), Some("speaker"));
        assert_eq!(p(&sinks, "les enceintes"), Some("speaker"));
        assert_eq!(p(&sinks, "UR242"), Some("ur242"));
        assert_eq!(p(&sinks, "la carte son"), Some("ur242"));
        assert_eq!(p(&sinks, "C27R50x"), Some("c27"));
        // Two HDMI outputs: the pilot is told to ask which.
        let several = pick(&sinks, "hdmi").unwrap_err();
        assert!(several.contains("plusieurs"), "{several}");
        assert!(pick(&sinks, "").is_err());

        // This machine's paired Bluetooth devices, with BlueZ's type.
        let paired: Vec<(String, &str)> = [
            ("MEGABOOM 3 (audio-headphones)", "megaboom"),
            ("KATAR PRO Wireless (input-mouse)", "katar"),
            ("MX Keys Mini B (input-keyboard)", "mx1"),
            ("JBL Endurance Peak 3 (audio-headset)", "jbl"),
            ("MX Keys Mini B (input-keyboard)", "mx2"),
        ]
        .into_iter()
        .map(|(l, v)| (l.to_string(), v))
        .collect();
        assert_eq!(p(&paired, "JBL"), Some("jbl"));
        assert_eq!(p(&paired, "la Megaboom"), Some("megaboom"));
        assert_eq!(p(&paired, "ma souris"), Some("katar"));
        assert_eq!(p(&paired, "katar"), Some("katar"));
        assert_eq!(p(&paired, "le clavier MX Keys"), Some("mx1"));
        assert_eq!(p(&paired, "MX Keys"), Some("mx1"));
        // « mon casque » fits two of them: ask.
        assert!(pick(&paired, "mon casque").unwrap_err().contains("JBL"));
        // Said vaguely with a single device: that one.
        let one = vec![("JBL Endurance Peak 3 (audio-headset)".to_string(), "jbl")];
        assert_eq!(p(&one, "oui"), Some("jbl"));
        assert_eq!(p(&one, "mon casque bluetooth"), Some("jbl"));
    }

    #[test]
    fn yes_and_no_however_said() {
        assert_eq!(yes_no("Oui"), Some(true));
        assert_eq!(yes_no("désactiver"), Some(false));
        assert_eq!(yes_no("Livebox-1234"), None);
    }

    #[test]
    fn the_best_profile_of_the_kind_asked() {
        let cards = json!([
            { "name": "alsa_card.pci", "properties": {}, "profiles": {} },
            { "name": "bluez_card.B4_84", "properties": { "api.bluez5.address": "B4:84" },
              "profiles": {
                "a2dp-sink-sbc": { "available": true, "priority": 10, "sources": 0 },
                "a2dp-sink-aac": { "available": true, "priority": 20, "sources": 0 },
                "headset-head-unit": { "available": true, "priority": 5, "sources": 1 },
                "headset-head-unit-cvsd": { "available": false, "priority": 9, "sources": 1 }
              } }
        ]);
        assert_eq!(
            bluetooth_profile(&cards, false),
            Some((
                "bluez_card.B4_84".into(),
                "a2dp-sink-aac".into(),
                "B4:84".into()
            ))
        );
        assert_eq!(
            bluetooth_profile(&cards, true).map(|p| p.1),
            Some("headset-head-unit".into())
        );
    }

    #[test]
    fn rebooting_by_voice_only_opens_the_power_panel() {
        let sent = std::cell::RefCell::new(String::new());
        let send = |l: &str| {
            sent.borrow_mut().push_str(l);
            Ok(())
        };
        assert!(apply("alimentation", "éteindre", send).is_ok());
        assert_eq!(sent.borrow().as_str(), "widget:alimentation:ouvrir\n");
        assert!(apply("alimentation", "formater", |_| Ok(())).is_err());
        assert!(apply("inconnu", "x", |_| Ok(())).is_err());
    }
}
