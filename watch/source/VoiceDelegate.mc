import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! START: держать = рация (отпустил -> отправка); короткое нажатие = старт/стоп.
//! Тап по экрану = старт/стоп. UP/DOWN = прокрутка ответа. BACK = стоп звука / выход.
class VoiceDelegate extends WatchUi.BehaviorDelegate {
    private var _c as VoiceController;
    private var _v as VoiceView;
    private var _pressedAt as Number = 0;
    private var _startedByPress as Boolean = false;
    private const HOLD_MS = 600;

    function initialize(c as VoiceController, v as VoiceView) {
        BehaviorDelegate.initialize();
        _c = c;
        _v = v;
    }

    function onKeyPressed(evt as WatchUi.KeyEvent) as Boolean {
        if (evt.getKey() != WatchUi.KEY_ENTER) {
            return false;
        }
        _pressedAt = System.getTimer();
        if (_c.isRecording()) {
            _c.stopAndSend();
            _startedByPress = false;
        } else {
            _startedByPress = _c.startRecording();
        }
        return true;
    }

    function onKeyReleased(evt as WatchUi.KeyEvent) as Boolean {
        if (evt.getKey() != WatchUi.KEY_ENTER) {
            return false;
        }
        if (_startedByPress && _c.isRecording() && System.getTimer() - _pressedAt >= HOLD_MS) {
            _c.stopAndSend(); // режим рации
        }
        _startedByPress = false;
        return true;
    }

    // START уже обработан в onKeyPressed/onKeyReleased — гасим повтор через onSelect/onKey
    function onSelect() as Boolean {
        return true;
    }

    function onTap(evt as WatchUi.ClickEvent) as Boolean {
        if (_c.isRecording()) {
            _c.stopAndSend();
        } else {
            _c.startRecording();
        }
        return true;
    }

    function onNextPage() as Boolean {
        _v.scroll(1);
        return true;
    }

    function onPreviousPage() as Boolean {
        _v.scroll(-1);
        return true;
    }

    function onBack() as Boolean {
        if (_c.isBusy()) {
            _c.cancel();
            return true;
        }
        return false; // выход из приложения
    }
}
