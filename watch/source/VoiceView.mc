import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

class VoiceView extends WatchUi.View {
    private var _c as VoiceController;
    private var _scroll as Number = 0;
    private var _lines as Array<String> = [];
    private var _lastText as String = "";

    function initialize(c as VoiceController) {
        View.initialize();
        _c = c;
    }

    function scroll(delta as Number) as Void {
        _scroll += delta;
        if (_scroll < 0) {
            _scroll = 0;
        }
        WatchUi.requestUpdate();
    }

    function resetScroll() as Void {
        _scroll = 0;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        // статус + индикатор записи
        var color = Graphics.COLOR_LT_GRAY;
        if (_c.isRecording()) {
            color = Graphics.COLOR_RED;
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(w / 2, h / 7, 10);
        }
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h / 7 + 16, Graphics.FONT_XTINY, _c.status, Graphics.TEXT_JUSTIFY_CENTER);

        // распознанная фраза (серым) и ответ (белым)
        var text = _c.reply;
        if (_c.heard.length() > 0) {
            text = "«" + _c.heard + "»\n" + text;
        }
        if (!text.equals(_lastText)) {
            _lastText = text;
            _lines = wrap(dc, text, Graphics.FONT_TINY, (w * 0.80).toNumber());
        }
        var font = Graphics.FONT_TINY;
        var lh = dc.getFontHeight(font);
        var top = h / 4 + 10;
        var maxLines = (h - top - h / 10) / lh;
        if (_scroll > _lines.size() - maxLines) {
            _scroll = _lines.size() - maxLines;
            if (_scroll < 0) {
                _scroll = 0;
            }
        }
        var heardLines = _c.heard.length() > 0 ? countHeardLines(dc, font, (w * 0.80).toNumber()) : 0;
        for (var i = 0; i < maxLines && i + _scroll < _lines.size(); i++) {
            var idx = i + _scroll;
            dc.setColor(idx < heardLines ? Graphics.COLOR_LT_GRAY : Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, top + i * lh, font, _lines[idx], Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    private function countHeardLines(dc as Graphics.Dc, font as Graphics.FontType, width as Number) as Number {
        return wrap(dc, "«" + _c.heard + "»", font, width).size();
    }

    //! Перенос по словам с учётом ширины в пикселях
    private function wrap(dc as Graphics.Dc, text as String, font as Graphics.FontType, width as Number) as Array<String> {
        var out = [] as Array<String>;
        var paragraphs = split(text, '\n');
        for (var p = 0; p < paragraphs.size(); p++) {
            var words = split(paragraphs[p], ' ');
            var line = "";
            for (var i = 0; i < words.size(); i++) {
                var cand = line.length() == 0 ? words[i] : line + " " + words[i];
                if (dc.getTextWidthInPixels(cand, font) <= width || line.length() == 0) {
                    line = cand;
                } else {
                    out.add(line);
                    line = words[i];
                }
            }
            out.add(line);
        }
        return out;
    }

    private function split(s as String, sep as Char) as Array<String> {
        var out = [] as Array<String>;
        var chars = s.toCharArray();
        var cur = "";
        for (var i = 0; i < chars.size(); i++) {
            if (chars[i] == sep) {
                out.add(cur);
                cur = "";
            } else {
                cur += chars[i];
            }
        }
        out.add(cur);
        return out;
    }
}
