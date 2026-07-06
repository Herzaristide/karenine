import QtQuick

// Multi-series sparkline canvas
// series: [{values: [0-100, oldest→newest], color: Qt.color | "#rrggbb"}]
// Legacy single-series API: values + lineColor (used when series is empty)
Canvas {
    id: graph

    property var series: []
    property var values: []
    property color lineColor: Theme.accentColor

    // implicitHeight (not height) is what ColumnLayout reads to allocate space
    implicitHeight: 42

    onSeriesChanged:  requestPaint()
    onValuesChanged:  requestPaint()
    onWidthChanged:   requestPaint()
    onHeightChanged:  requestPaint()
    onVisibleChanged: if (visible) requestPaint()

    onPaint: {
        const ctx = getContext("2d");
        if (!ctx) return;
        ctx.clearRect(0, 0, width, height);

        // Resolve series list: prefer explicit series, fall back to legacy values
        const allSeries = (series && series.length > 0)
            ? series
            : (values && values.length > 0 ? [{ values: values, color: lineColor }] : []);
        if (allSeries.length === 0 || width <= 0) return;

        const w = width;
        const h = height;
        const multi = allSeries.length > 1;

        function yOf(v) {
            return h - (Math.min(Math.max(v, 0), 100) / 100) * (h - 3) - 1;
        }

        // Accept both QML color objects {r,g,b ∈ [0,1]} and "#rrggbb" strings
        function toRgba(c, a) {
            let r, g, b;
            if (c && typeof c === "object" && "r" in c) {
                r = Math.round(c.r * 255);
                g = Math.round(c.g * 255);
                b = Math.round(c.b * 255);
            } else {
                const hex = String(c).replace("#", "");
                r = parseInt(hex.substr(0, 2), 16) || 0;
                g = parseInt(hex.substr(2, 2), 16) || 0;
                b = parseInt(hex.substr(4, 2), 16) || 0;
            }
            return "rgba(" + r + "," + g + "," + b + "," + a + ")";
        }

        for (let s = 0; s < allSeries.length; s++) {
            const ser  = allSeries[s];
            const vals = ser.values;
            if (!vals || vals.length < 2) continue;

            const n    = vals.length;
            const step = w / (n - 1);
            const col  = ser.color;

            // Filled area under the curve (subtle in multi mode)
            const fillAlpha = multi ? 0.08 : 0.28;
            const grad = ctx.createLinearGradient(0, 0, 0, h);
            grad.addColorStop(0, toRgba(col, fillAlpha));
            grad.addColorStop(1, toRgba(col, 0.0));
            ctx.beginPath();
            ctx.moveTo(0, h);
            for (let i = 0; i < n; i++) ctx.lineTo(i * step, yOf(vals[i]));
            ctx.lineTo((n - 1) * step, h);
            ctx.closePath();
            ctx.fillStyle = grad;
            ctx.fill();

            // Stroke line
            ctx.beginPath();
            ctx.moveTo(0, yOf(vals[0]));
            for (let i = 1; i < n; i++) ctx.lineTo(i * step, yOf(vals[i]));
            ctx.strokeStyle = toRgba(col, 1.0);
            ctx.lineWidth   = 1.5;
            ctx.lineJoin    = "round";
            ctx.lineCap     = "round";
            ctx.stroke();

            // Latest-value dot
            ctx.beginPath();
            ctx.arc((n - 1) * step, yOf(vals[n - 1]), 2.5, 0, Math.PI * 2);
            ctx.fillStyle = toRgba(col, 1.0);
            ctx.fill();
        }
    }
}
