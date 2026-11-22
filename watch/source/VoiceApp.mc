import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

//! Голосовой ассистент: держишь START и говоришь -> сервер -> ответ текстом и голосом.
class VoiceApp extends Application.AppBase {
    var controller as VoiceController?;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
    }

    function onStop(state as Dictionary?) as Void {
        if (controller != null) {
            controller.shutdown();
        }
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        controller = new VoiceController();
        var view = new VoiceView(controller);
        controller.setView(view);
        return [view, new VoiceDelegate(controller, view)];
    }
}
