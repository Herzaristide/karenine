//! Just enough XML for WebDAV's answers (caldav.rs): a tree of elements, by
//! their local names, with their attributes and text.
//!
//! Namespaces are dropped: `d:href`, `D:href` and `href` are the same
//! element. Comments, processing instructions and the doctype are skipped;
//! CDATA is text. That is all a `multistatus` needs, and it keeps the crate
//! list short.

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Node {
    /// Without its prefix.
    pub name: String,
    pub attrs: Vec<(String, String)>,
    pub children: Vec<Node>,
    /// The text directly inside, unescaped.
    pub text: String,
}

impl Node {
    pub fn child(&self, name: &str) -> Option<&Node> {
        self.children.iter().find(|c| c.name == name)
    }

    /// Every element of that name below this one, at any depth.
    pub fn descendants<'a>(&'a self, name: &str, out: &mut Vec<&'a Node>) {
        for c in &self.children {
            if c.name == name {
                out.push(c);
            }
            c.descendants(name, out);
        }
    }

    /// The first element of that name below this one, at any depth.
    pub fn find(&self, name: &str) -> Option<&Node> {
        let mut found = Vec::new();
        self.descendants(name, &mut found);
        found.into_iter().next()
    }

    pub fn attr(&self, name: &str) -> Option<&str> {
        self.attrs
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }
}

fn local(name: &str) -> String {
    name.rsplit(':').next().unwrap_or(name).to_string()
}

/// `&lt;`, `&#233;`… back to their characters. An unknown entity is kept
/// as written.
pub fn unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(at) = rest.find('&') {
        out.push_str(&rest[..at]);
        rest = &rest[at..];
        let Some(end) = rest.find(';').filter(|&e| e <= 12) else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };
        let entity = &rest[1..end];
        let ch = match entity {
            "lt" => Some('<'),
            "gt" => Some('>'),
            "amp" => Some('&'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            _ => entity
                .strip_prefix("#x")
                .or_else(|| entity.strip_prefix("#X"))
                .map(|h| u32::from_str_radix(h, 16).ok())
                .unwrap_or_else(|| entity.strip_prefix('#').and_then(|d| d.parse().ok()))
                .and_then(char::from_u32),
        };
        match ch {
            Some(c) => {
                out.push(c);
                rest = &rest[end + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// The attributes of a start tag, after its name.
fn attributes(s: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut rest = s.trim();
    while let Some(eq) = rest.find('=') {
        let key = rest[..eq].trim();
        let after = rest[eq + 1..].trim_start();
        let Some(quote) = after.chars().next().filter(|q| *q == '"' || *q == '\'') else {
            break;
        };
        let Some(close) = after[1..].find(quote) else {
            break;
        };
        out.push((local(key), unescape(&after[1..1 + close])));
        rest = after[close + 2..].trim_start();
    }
    out
}

/// The root element of a document.
pub fn parse(doc: &str) -> Result<Node, String> {
    let bad = |what: &str| format!("XML invalide : {what}");
    // The open elements; the bottom one collects the root.
    let mut stack: Vec<Node> = vec![Node::default()];
    let mut rest = doc;
    while !rest.is_empty() {
        let Some(lt) = rest.find('<') else {
            push_text(&mut stack, &unescape(rest));
            break;
        };
        if lt > 0 {
            push_text(&mut stack, &unescape(&rest[..lt]));
        }
        rest = &rest[lt..];
        if let Some(body) = rest.strip_prefix("<![CDATA[") {
            let end = body.find("]]>").ok_or_else(|| bad("CDATA"))?;
            push_text(&mut stack, &body[..end]);
            rest = &body[end + 3..];
        } else if let Some(body) = rest.strip_prefix("<!--") {
            let end = body.find("-->").ok_or_else(|| bad("commentaire"))?;
            rest = &body[end + 3..];
        } else if rest.starts_with("<?") || rest.starts_with("<!") {
            let end = rest.find('>').ok_or_else(|| bad("déclaration"))?;
            rest = &rest[end + 1..];
        } else if let Some(body) = rest.strip_prefix("</") {
            let end = body.find('>').ok_or_else(|| bad("balise fermante"))?;
            let name = local(body[..end].trim());
            let node = stack.pop().filter(|n| n.name == name);
            let (Some(node), Some(parent)) = (node, stack.last_mut()) else {
                return Err(bad(&format!("</{name}> inattendue")));
            };
            parent.children.push(node);
            rest = &body[end + 1..];
        } else {
            let end = tag_end(rest).ok_or_else(|| bad("balise"))?;
            let inner = &rest[1..end];
            let (inner, closed) = match inner.strip_suffix('/') {
                Some(i) => (i, true),
                None => (inner, false),
            };
            let split = inner
                .find(|c: char| c.is_whitespace())
                .unwrap_or(inner.len());
            let node = Node {
                name: local(&inner[..split]),
                attrs: attributes(&inner[split..]),
                ..Default::default()
            };
            if closed {
                stack
                    .last_mut()
                    .ok_or_else(|| bad("racine"))?
                    .children
                    .push(node);
            } else {
                stack.push(node);
            }
            rest = &rest[end + 1..];
        }
    }
    if stack.len() != 1 {
        return Err(bad("élément non fermé"));
    }
    stack
        .pop()
        .and_then(|doc| doc.children.into_iter().next())
        .ok_or_else(|| bad("document vide"))
}

/// The `>` closing the tag that starts `s`, past any quoted attribute.
fn tag_end(s: &str) -> Option<usize> {
    let mut quote: Option<char> = None;
    for (i, c) in s.char_indices() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (None, '"' | '\'') => quote = Some(c),
            (None, '>') => return Some(i),
            _ => {}
        }
    }
    None
}

fn push_text(stack: &mut [Node], text: &str) {
    if let Some(node) = stack.last_mut() {
        node.text.push_str(text);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_multistatus_without_its_prefixes() {
        let doc = r#"<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
  <!-- a comment -->
  <d:response>
    <d:href>/remote.php/dav/calendars/u/perso/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>Perso &amp; pro</d:displayname>
        <cal:supported-calendar-component-set>
          <cal:comp name="VEVENT"/><cal:comp name='VTODO' />
        </cal:supported-calendar-component-set>
        <cal:calendar-data><![CDATA[BEGIN:VCALENDAR]]>&#13;&#x41;</cal:calendar-data>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>"#;
        let root = parse(doc).unwrap();
        assert_eq!(root.name, "multistatus");
        let r = root.child("response").unwrap();
        assert_eq!(
            r.child("href").unwrap().text,
            "/remote.php/dav/calendars/u/perso/"
        );
        assert_eq!(root.find("displayname").unwrap().text, "Perso & pro");
        let mut comps = Vec::new();
        root.descendants("comp", &mut comps);
        let names: Vec<&str> = comps.iter().filter_map(|c| c.attr("name")).collect();
        assert_eq!(names, ["VEVENT", "VTODO"]);
        assert_eq!(
            root.find("calendar-data").unwrap().text,
            "BEGIN:VCALENDAR\rA"
        );
    }

    #[test]
    fn broken_documents_are_errors() {
        assert!(parse("<a><b></a>").is_err());
        assert!(parse("<a>").is_err());
        assert!(parse("").is_err());
        assert!(parse("<a x=\"1 > 2\"/>").is_ok());
    }

    #[test]
    fn entities_unescape() {
        assert_eq!(
            unescape("a &lt;b&gt; &amp;&#233;&#xE9; &bogus; & x"),
            "a <b> &éé &bogus; & x"
        );
    }
}
