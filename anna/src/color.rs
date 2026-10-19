/// A 24-bit RGB color with hex parsing, HSL math, and derived variants.
#[derive(Debug, Clone, PartialEq)]
pub struct Color {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl Color {
    pub fn from_hex(s: &str) -> Option<Self> {
        let s = s.trim().trim_start_matches('#');
        if s.len() != 6 {
            return None;
        }
        let r = u8::from_str_radix(&s[0..2], 16).ok()?;
        let g = u8::from_str_radix(&s[2..4], 16).ok()?;
        let b = u8::from_str_radix(&s[4..6], 16).ok()?;
        Some(Self { r, g, b })
    }

    /// `#rrggbb`
    pub fn to_hex(&self) -> String {
        format!("#{:02x}{:02x}{:02x}", self.r, self.g, self.b)
    }

    /// `rrggbb` (no `#`)
    pub fn hex_no_hash(&self) -> String {
        format!("{:02x}{:02x}{:02x}", self.r, self.g, self.b)
    }

    /// `r,g,b` decimal
    pub fn to_rgb_str(&self) -> String {
        format!("{},{},{}", self.r, self.g, self.b)
    }

    /// `38;2;r;g;b` ANSI escape sequence component
    pub fn to_ansi(&self) -> String {
        format!("38;2;{};{};{}", self.r, self.g, self.b)
    }

    /// Approximates Qt.darker(c, 1.8): each component divided by 1.8.
    pub fn darker(&self) -> Self {
        let darken = |v: u8| -> u8 { (v as f64 / 1.8 + 0.5) as u8 };
        Self {
            r: darken(self.r),
            g: darken(self.g),
            b: darken(self.b),
        }
    }

    /// HSL mutation: S * 0.75, L * 1.35 clamped to 0.75.
    pub fn muted(&self) -> Self {
        let (h, s, l) = self.to_hsl();
        let new_s = s * 0.75;
        let new_l = (l * 1.35_f64).min(0.75);
        Self::from_hsl(h, new_s, new_l)
    }

    /// "Mono" recolouring toward `accent`, used on icons: the accent hue, the
    /// lightness kept (so relief and gradients survive), the saturation scaled
    /// to the accent's by how saturated the original was. Near-white and
    /// near-black are left alone.
    pub fn mono_toward(&self, accent: &Color) -> Self {
        let (_, s, l) = self.to_hsl();
        if !(0.04..=0.96).contains(&l) {
            return self.clone();
        }
        let (ah, a_sat, _) = accent.to_hsl();
        let s = (a_sat * (0.35 + 0.65 * (s / 0.5).min(1.0))).min(1.0);
        Self::from_hsl(ah, s, l)
    }

    // ── Internal helpers ──────────────────────────────────────────────────

    fn to_hsl(&self) -> (f64, f64, f64) {
        let r = self.r as f64 / 255.0;
        let g = self.g as f64 / 255.0;
        let b = self.b as f64 / 255.0;

        let mx = r.max(g).max(b);
        let mn = r.min(g).min(b);
        let d = mx - mn;
        let l = (mx + mn) / 2.0;

        if d == 0.0 {
            return (0.0, 0.0, l);
        }

        let s = if l > 0.5 {
            d / (2.0 - mx - mn)
        } else {
            d / (mx + mn)
        };

        let h = if (mx - r).abs() < f64::EPSILON {
            (g - b) / d + if g < b { 6.0 } else { 0.0 }
        } else if (mx - g).abs() < f64::EPSILON {
            (b - r) / d + 2.0
        } else {
            (r - g) / d + 4.0
        } * 60.0;

        (h, s, l)
    }

    fn from_hsl(h: f64, s: f64, l: f64) -> Self {
        if s == 0.0 {
            let v = (l * 255.0 + 0.5) as u8;
            return Self { r: v, g: v, b: v };
        }

        let q = if l < 0.5 {
            l * (1.0 + s)
        } else {
            l + s - l * s
        };
        let p = 2.0 * l - q;
        let hh = h / 360.0;

        fn hue2rgb(p: f64, q: f64, mut t: f64) -> f64 {
            if t < 0.0 {
                t += 1.0;
            }
            if t > 1.0 {
                t -= 1.0;
            }
            if t < 1.0 / 6.0 {
                return p + (q - p) * 6.0 * t;
            }
            if t < 0.5 {
                return q;
            }
            if t < 2.0 / 3.0 {
                return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
            }
            p
        }

        let r = (hue2rgb(p, q, hh + 1.0 / 3.0) * 255.0 + 0.5) as u8;
        let g = (hue2rgb(p, q, hh) * 255.0 + 0.5) as u8;
        let b = (hue2rgb(p, q, hh - 1.0 / 3.0) * 255.0 + 0.5) as u8;
        Self { r, g, b }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_hex() {
        let c = Color::from_hex("#5277c3").unwrap();
        assert_eq!(c.r, 0x52);
        assert_eq!(c.g, 0x77);
        assert_eq!(c.b, 0xc3);
        assert_eq!(c.to_hex(), "#5277c3");
    }

    #[test]
    fn darker_matches_awk() {
        // 0x52 / 1.8 + 0.5 = 82 / 1.8 + 0.5 ≈ 46.1 → 46
        let c = Color::from_hex("#5277c3").unwrap();
        let d = c.darker();
        assert_eq!(d.r, (0x52u16 as f64 / 1.8 + 0.5) as u8);
        assert_eq!(d.g, (0x77u16 as f64 / 1.8 + 0.5) as u8);
        assert_eq!(d.b, (0xc3u16 as f64 / 1.8 + 0.5) as u8);
    }

    #[test]
    fn accepts_hex_without_hash_and_whitespace() {
        assert_eq!(Color::from_hex("  5277C3\n").unwrap().to_hex(), "#5277c3");
        assert!(Color::from_hex("#5277c3ff").is_none());
        assert!(Color::from_hex("#é277c").is_none());
    }

    #[test]
    fn hsl_round_trips() {
        for hex in [
            "#5277c3", "#ff0000", "#00ff00", "#0000ff", "#808080", "#000000", "#ffffff", "#c0ffee",
        ] {
            let c = Color::from_hex(hex).unwrap();
            let (h, s, l) = c.to_hsl();
            let back = Color::from_hsl(h, s, l);
            for (a, b) in [(c.r, back.r), (c.g, back.g), (c.b, back.b)] {
                assert!(a.abs_diff(b) <= 1, "{hex} -> {}", back.to_hex());
            }
        }
    }

    #[test]
    fn variants_keep_the_hue() {
        let c = Color::from_hex("#5277c3").unwrap();
        let hue = c.to_hsl().0;
        let red = Color::from_hex("#f05050").unwrap();
        for v in [c.muted(), red.mono_toward(&c)] {
            assert!((v.to_hsl().0 - hue).abs() < 2.0, "{}", v.to_hex());
        }
        // mono keeps the lightness and leaves white alone.
        assert!((red.mono_toward(&c).to_hsl().2 - red.to_hsl().2).abs() < 0.01);
        let white = Color::from_hex("#ffffff").unwrap();
        assert_eq!(white.mono_toward(&c), white);
        assert!(c.muted().to_hsl().2 <= 0.75 + 0.01);
    }

    #[test]
    fn string_forms() {
        let c = Color::from_hex("#0a141e").unwrap();
        assert_eq!(c.hex_no_hash(), "0a141e");
        assert_eq!(c.to_rgb_str(), "10,20,30");
        assert_eq!(c.to_ansi(), "38;2;10;20;30");
    }

    #[test]
    fn rejects_short_hex() {
        assert!(Color::from_hex("#527").is_none());
        assert!(Color::from_hex("zzzzzz").is_none());
    }
}
