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
    /// HSL hue-to-RGB channel helper.
    pub fn muted(&self) -> Self {
        let (h, s, l) = self.to_hsl();
        let new_s = s * 0.75;
        let new_l = (l * 1.35_f64).min(0.75);
        Self::from_hsl(h, new_s, new_l)
    }

    /// Bright accent for the Arcanum icon theme: same hue, S=100%, L=70%.
    /// Replaces #ff6666 (the bright red highlight) when recoloring icons.
    pub fn arcanum_bright(&self) -> Self {
        let (h, _, _) = self.to_hsl();
        Self::from_hsl(h, 1.0, 0.70)
    }

    /// Dark accent for the Arcanum icon theme: same hue, S=75%, L=20%.
    /// Replaces #5a0d0d (the dark red shadow) when recoloring icons.
    pub fn arcanum_dark(&self) -> Self {
        let (h, _, _) = self.to_hsl();
        Self::from_hsl(h, 0.75, 0.20)
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
    fn rejects_short_hex() {
        assert!(Color::from_hex("#527").is_none());
        assert!(Color::from_hex("zzzzzz").is_none());
    }
}
