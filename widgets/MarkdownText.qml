import QtQuick
import "../services"

// Du Markdown à lire, dont les liens se voient : à la couleur d'accent et
// soulignés, avec la main et un fond au survol. Un clic les ouvre.
//
// Qt donne aux liens du Markdown le bleu de la palette, en ignorant
// `linkColor` : on les réécrit donc en <a>, avec leur couleur.
Text {
    id: root

    property string markdown: ""
    property bool links: true

    // Sans liaison : la couleur d'accent qui change ne doit pas réécrire le
    // texte en place, ce qui peut faire planter Qt 6.12.0 (QTBUG-151670).
    onMarkdownChanged: root._write()
    onLinksChanged: root._write()
    function _write() {
        root.text = root.links ? root.withLinks(root.markdown) : root.markdown;
    }
    textFormat: root.links ? Text.MarkdownText : Text.PlainText
    wrapMode: Text.Wrap
    onLinkActivated: (link) => Qt.openUrlExternally(link)

    function _escape(s) {
        return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }

    function _anchor(url, label, before) {
        // Le gras et le code d'un libellé ne passent pas dans le HTML ; ce
        // qui reste de ponctuation Markdown y est du texte.
        var mono = /^`[^`]+`$/.test(label);
        var plain = label.replace(/`/g, "").replace(/\*\*/g, "").replace(/\\([^\w\s])/g, "$1");
        // Le HTML ne prend pas le style de ce qui l'entoure : le titre, le gras.
        var title = /^ {0,3}(#{1,6})[ \t]/.exec(before);
        var bold = title || /\*\*$/.test(before) || /^\*\*[\s\S]*\*\*$/.test(label);
        var size = title ? ["xx-large", "x-large", "large"][title[1].length - 1] : "";
        var c = Theme.accentColor;
        var rgb = "#" + [c.r, c.g, c.b].map((v) => ("0" + Math.round(v * 255).toString(16)).slice(-2)).join("");
        var style = "color:" + rgb + ";text-decoration:underline"
            + (bold ? ";font-weight:bold" : "") + (size ? ";font-size:" + size : "");
        return "<a style=\"" + style + "\" href=\"" + root._escape(url) + "\">" + (mono ? "<tt>" : "")
            + root._escape(plain).replace(/([\\`*_~\[\]])/g, "\\$1") + (mono ? "</tt>" : "") + "</a>";
    }

    // Les liens de `md` en <a> ; le code, les images et le HTML restent.
    function withLinks(md) {
        var re = new RegExp([
            // Un bloc de code, fermé ou non ; un bloc indenté.
            "(^[ \\t]*(`{3,}|~{3,})[^\\n]*\\n[\\s\\S]*?(?:^[ \\t]*\\2[ \\t]*$|(?![\\s\\S])))",
            "(\\n[ \\t]*\\n(?: {4}|\\t)(?![ \\t]*(?:[-*+]|\\d+[.)])[ \\t])[^\\n]*(?:\\n(?: {4}|\\t)[^\\n]*)*)",
            // Du code dans le texte, une image, une balise.
            "((`+)(?!`)(?:(?!\\n[ \\t]*\\n)[\\s\\S])*?[^`]\\4(?!`))",
            "(!\\[[^\\]\\n]*\\]\\([^)\\n]*\\))",
            "(<a\\s[^>]*>[\\s\\S]*?</a>)",
            // [libellé](adresse "titre"), <adresse>, adresse nue.
            "\\[((?:\\\\.|`[^`\\n]*`|\\[[^\\[\\]\\n]*\\]|[^\\[\\]\\\\`])+)\\]\\((?:<([^>\\n]+)>|((?:[^\\s()<>]|\\([^\\s()]*\\))+))(?:\\s+(?:\"[^\"\\n]*\"|'[^'\\n]*'))?\\s*\\)",
            "<((?:https?|file|mailto):[^\\s<>]+)>",
            "(https?://(?:[^\\s<>()\\[\\]`\"'|*]|\\([^\\s<>()]*\\))*[^\\s<>()\\[\\]`\"'|*.,;:!?…»])"
        ].join("|"), "gm");
        return md.replace(re, (all, fence, f, indented, code, c, img, tag, label, urlA, urlB, auto, bare, offset) => {
            var before = md.slice(md.lastIndexOf("\n", offset - 1) + 1, offset);
            if (label !== undefined && label !== "")
                return root._anchor(urlA || urlB, label.replace(/\s+/g, " "), before);
            var u = auto || bare;
            return u ? root._anchor(u, u, before) : all;
        });
    }

    HoverHandler {
        id: hover
        cursorShape: root.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
    }

    // Le fond du lien survolé. Réécrire le texte pour le teinter ferait
    // planter Qt 6.12.0 (QTBUG-151670) : on cherche où le lien s'étend, sur
    // la ligne pointée, et on peint dessous.
    readonly property rect _linkRect: {
        var link = root.hoveredLink;
        if (link === "" || !hover.hovered)
            return Qt.rect(0, 0, 0, 0);
        var p = hover.point.position;
        var l = p.x, r = p.x, t = p.y, b = p.y;
        while (l > 0 && root.linkAt(l - 1, p.y) === link)
            l--;
        while (r < root.width && root.linkAt(r + 1, p.y) === link)
            r++;
        // Pas plus haut qu'une ligne : le lien peut continuer sur la suivante.
        var line = root.font.pixelSize * 1.6;
        while (b - t < line && root.linkAt(p.x, t - 1) === link)
            t--;
        while (b - t < line && root.linkAt(p.x, b + 1) === link)
            b++;
        return Qt.rect(l, t, r - l, b - t);
    }
    Rectangle {
        z: -1
        visible: width > 0
        x: root._linkRect.x - 3
        y: root._linkRect.y
        width: root._linkRect.width > 0 ? root._linkRect.width + 6 : 0
        height: root._linkRect.height
        radius: 4
        color: Qt.alpha(Theme.accentColor, 0.22)
    }
}
