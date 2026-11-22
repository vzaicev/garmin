import Toybox.Attention;
import Toybox.Audio;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Math;
import Toybox.StringUtil;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;
using Toybox.Audio.Capture;
using Toybox.Audio.Output;

//! Запись -> загрузка частями -> ожидание ответа -> текст + звук.
//! SERVER_URL и API_TOKEN — в Config.mc (генерируется build.sh, не в git).
class VoiceController {
    // состояние для экрана
    var status as String = "Держи START и говори";
    var heard as String = "";
    var reply as String = "";

    enum {
        S_IDLE, S_REC, S_UPLOAD, S_WAIT, S_AUDIO, S_PLAY
    }
    private var _state as Number = S_IDLE;
    private var _view as VoiceView?;

    // запись
    private var _fmt as Dictionary?;
    private var _fmtName as String = "ogg";
    private var _buf as ByteArray = []b;
    private var _maxMs as Number = 30000;
    private var _recTimer as Timer.Timer = new Timer.Timer();

    // загрузка
    private const CHUNK = 12000; // байт сырых данных на запрос (base64 ≈ 16 КБ)
    private var _sid as String = "";
    private var _chunkN as Number = 0;
    private var _jobId as String = "";
    private var _pollTimer as Timer.Timer = new Timer.Timer();
    private var _polls as Number = 0;
    private var _lastSt as String = "";
    private var _audioFmt as String = "ogg";
    private var _gen as Number = 0; // поколение запроса: отменённые колбэки игнорируются

    function initialize() {
        Math.srand(System.getTimer());
        chooseFormat();
    }

    function setView(v as VoiceView) as Void {
        _view = v;
    }

    function isRecording() as Boolean {
        return _state == S_REC;
    }

    function isBusy() as Boolean {
        return _state != S_IDLE;
    }

    // ---------- запись ----------
    private function chooseFormat() as Void {
        var opus = {
            :containerFormat => Audio.CONTAINER_OGG, :codec => Audio.CODEC_OPUS,
            :frequency => Audio.FREQ_16_KHZ, :channels => Audio.CHANNEL_MONO
        };
        var wav16 = {
            :containerFormat => Audio.CONTAINER_WAV, :codec => Audio.CODEC_LPCM,
            :frequency => Audio.FREQ_16_KHZ, :channels => Audio.CHANNEL_MONO
        };
        var wav8 = {
            :containerFormat => Audio.CONTAINER_WAV, :codec => Audio.CODEC_LPCM,
            :frequency => Audio.FREQ_8_KHZ, :channels => Audio.CHANNEL_MONO
        };
        if (Capture.isFormatSupported(opus)) {
            _fmt = opus; _fmtName = "ogg"; _maxMs = 30000;
        } else if (Capture.isFormatSupported(wav16)) {
            _fmt = wav16; _fmtName = "wav"; _maxMs = 12000; // 32 КБ/с — бережём память
        } else if (Capture.isFormatSupported(wav8)) {
            _fmt = wav8; _fmtName = "wav"; _maxMs = 20000;
        } else {
            _fmt = null;
        }
    }

    function startRecording() as Boolean {
        if (_state == S_PLAY) {
            Output.stop();
        } else if (_state != S_IDLE) {
            return false;
        }
        if (_fmt == null) {
            setStatus("Микрофон: формат не поддержан");
            return false;
        }
        _buf = []b;
        try {
            Capture.initializeAudioCapture(self, {
                :format => _fmt,
                :windowSize => 4096,
                :windowFilledBehavior => Capture.WINDOW_FILLED_CONTINUE,
                :filters => Capture.getSupportedFilters() // шумоподавление, если есть
            });
            Capture.start();
        } catch (e) {
            setStatus("Ошибка микрофона: " + e.getErrorMessage());
            return false;
        }
        _state = S_REC;
        heard = "";
        reply = "";
        if (_view != null) {
            _view.resetScroll();
        }
        _recTimer.start(method(:onRecTimeout), _maxMs, false);
        setStatus("Слушаю… (" + (_maxMs / 1000) + " с)");
        return true;
    }

    function onRecTimeout() as Void {
        if (_state == S_REC) {
            stopAndSend();
        }
    }

    function stopAndSend() as Void {
        if (_state != S_REC) {
            return;
        }
        _recTimer.stop();
        _state = S_UPLOAD;
        setStatus("Отправляю…");
        if (Capture.getState() == Capture.CAPTURE_CAPTURING) {
            Capture.stop(); // остаток придёт в onData, затем onComplete
        } else {
            onComplete();
        }
    }

    // Capture.Callbacks
    function onData(data as ByteArray) as Void {
        _buf = _buf.addAll(data);
    }

    function onError(err as Capture.Error) as Void {
        _recTimer.stop();
        _state = S_IDLE;
        setStatus("Ошибка записи " + err);
    }

    function onComplete() as Void {
        if (_state != S_UPLOAD) {
            return;
        }
        if (_buf.size() < 1000) {
            _state = S_IDLE;
            setStatus("Слишком коротко. Держи START");
            return;
        }
        _gen += 1;
        _sid = randomId();
        _chunkN = 0;
        sendNextChunk();
    }

    // ---------- загрузка ----------
    private function authHeaders() as Dictionary {
        return {
            "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
            "Authorization" => "Bearer " + API_TOKEN
        };
    }

    private function sendNextChunk() as Void {
        var from = _chunkN * CHUNK;
        if (from >= _buf.size()) {
            ask();
            return;
        }
        var to = from + CHUNK;
        if (to > _buf.size()) {
            to = _buf.size();
        }
        var b64 = StringUtil.convertEncodedString(_buf.slice(from, to), {
            :fromRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY,
            :toRepresentation => StringUtil.REPRESENTATION_STRING_BASE64
        });
        var total = (_buf.size() + CHUNK - 1) / CHUNK;
        setStatus("Отправляю " + (_chunkN + 1) + "/" + total);
        Communications.makeWebRequest(SERVER_URL + "/v1/chunk",
            {"sid" => _sid, "n" => _chunkN, "data" => b64},
            {:method => Communications.HTTP_REQUEST_METHOD_POST, :headers => authHeaders(),
             :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON, :context => _gen},
            method(:onChunk));
    }

    function onChunk(code as Number, data as Dictionary or String or Null, ctx as Object) as Void {
        if (ctx != _gen) { return; }
        if (code != 200) {
            fail("Загрузка", code);
            return;
        }
        _chunkN += 1;
        sendNextChunk();
    }

    private function ask() as Void {
        _buf = []b; // освобождаем память
        setStatus("Распознаю…");
        Communications.makeWebRequest(SERVER_URL + "/v1/ask",
            {"sid" => _sid, "fmt" => _fmtName},
            {:method => Communications.HTTP_REQUEST_METHOD_POST, :headers => authHeaders(),
             :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON, :context => _gen},
            method(:onAsk));
    }

    function onAsk(code as Number, data as Dictionary or String or Null, ctx as Object) as Void {
        if (ctx != _gen) { return; }
        if (code != 200 || !(data instanceof Dictionary)) {
            fail("Запрос", code);
            return;
        }
        _jobId = data["id"] as String;
        _state = S_WAIT;
        _polls = 0;
        _lastSt = "";
        poll();
    }

    // ---------- ожидание ответа ----------
    function poll() as Void {
        if (_state != S_WAIT) { return; }
        _polls += 1;
        // long-poll: сервер держит запрос до смены статуса (до 20 с)
        Communications.makeWebRequest(SERVER_URL + "/v1/result/" + _jobId, {"wait" => 20, "since" => _lastSt},
            {:method => Communications.HTTP_REQUEST_METHOD_GET,
             :headers => {"Authorization" => "Bearer " + API_TOKEN},
             :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON, :context => _gen},
            method(:onResult));
    }

    function onResult(code as Number, data as Dictionary or String or Null, ctx as Object) as Void {
        if (ctx != _gen || _state != S_WAIT) { return; }
        if (code != 200 || !(data instanceof Dictionary)) {
            if (_polls < 60 && code != 401 && code != 404) {
                _pollTimer.start(method(:poll), 2000, false); // сетевые сбои — пробуем дальше
                return;
            }
            fail("Ответ", code);
            return;
        }
        var st = data["status"] as String;
        _lastSt = st;
        var h = data["heard"];
        if (h instanceof String && h.length() > 0) {
            heard = h;
        }
        if (st.equals("done") || st.equals("error")) {
            reply = data["text"] as String;
            if (data["audio"] == true) {
                fetchAudio("ogg");
            } else {
                _state = S_IDLE;
                setStatus("Держи START и говори");
                WatchUi.requestUpdate();
            }
            buzz();
            return;
        }
        if (st.equals("listening")) {
            setStatus("Распознаю…");
        } else if (st.equals("thinking")) {
            setStatus("Думаю…");
        } else {
            setStatus("Озвучиваю…");
        }
        if (_polls < 60) {
            poll();
        } else {
            fail("Долго нет ответа", 0);
        }
    }

    // ---------- звук ----------
    private function fetchAudio(fmt as String) as Void {
        _state = S_AUDIO;
        _audioFmt = fmt;
        setStatus("Загружаю звук…");
        Communications.makeWebRequest(SERVER_URL + "/v1/audio/" + _jobId, {"fmt" => fmt},
            {:method => Communications.HTTP_REQUEST_METHOD_GET,
             :headers => {"Authorization" => "Bearer " + API_TOKEN},
             :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_OCTET_STREAM, :context => _gen},
            method(:onAudio));
    }

    function onAudio(code as Number, data as ByteArray or Null, ctx as Object) as Void {
        if (ctx != _gen || _state != S_AUDIO) { return; }
        if (code != 200 || data == null) {
            if (_audioFmt.equals("ogg")) {
                fetchAudio("wav");
                return;
            }
            fail("Звук", code); // текст уже на экране
            return;
        }
        var fmt = _audioFmt.equals("ogg")
            ? {:containerFormat => Audio.CONTAINER_OGG, :codec => Audio.CODEC_OPUS,
               :frequency => Audio.FREQ_16_KHZ, :channels => Audio.CHANNEL_MONO}
            : {:containerFormat => Audio.CONTAINER_WAV, :codec => Audio.CODEC_LPCM,
               :frequency => Audio.FREQ_16_KHZ, :channels => Audio.CHANNEL_MONO};
        try {
            var b = new Output.DynamicAudioSourceBuilder({:format => fmt});
            b.append(data);
            Output.registerStateChangeHandler(method(:onPlayState));
            Output.play(b.complete(), 0);
            _state = S_PLAY;
            setStatus("▶ START — новый вопрос");
        } catch (e) {
            if (_audioFmt.equals("ogg")) {
                fetchAudio("wav");
            } else {
                fail("Плеер", 0);
            }
        }
    }

    function onPlayState(st as Output.PlaybackState) as Void {
        if (st == Output.PLAYBACK_ERROR && _state == S_PLAY && _audioFmt.equals("ogg")) {
            fetchAudio("wav"); // Opus не завёлся — пробуем WAV
            return;
        }
        if (st == Output.PLAYBACK_STOPPED || st == Output.PLAYBACK_ERROR) {
            if (_state == S_PLAY) {
                _state = S_IDLE;
                setStatus("Держи START и говори");
            }
        }
    }

    // ---------- служебное ----------
    function cancel() as Void {
        _gen += 1;
        _recTimer.stop();
        _pollTimer.stop();
        if (_state == S_REC && Capture.getState() == Capture.CAPTURE_CAPTURING) {
            _state = S_IDLE; // onComplete увидит S_IDLE и ничего не отправит
            Capture.stop();
        }
        if (_state == S_PLAY) {
            Output.stop();
        }
        _state = S_IDLE;
        _buf = []b;
        setStatus("Отменено");
    }

    function shutdown() as Void {
        cancel();
        Output.registerStateChangeHandler(null);
    }

    private function fail(what as String, code as Number) as Void {
        _pollTimer.stop();
        _state = S_IDLE;
        var hint = "";
        if (code == -104 || code == -2) {
            hint = " (нет связи с телефоном)";
        } else if (code == 401 || code == 403) {
            hint = " (токен)";
        } else if (code == -102) {
            hint = " (слишком большой запрос)";
        }
        setStatus(what + ": ошибка " + code + hint);
    }

    private function setStatus(s as String) as Void {
        status = s;
        WatchUi.requestUpdate();
    }

    private function buzz() as Void {
        if (Attention has :vibrate) {
            Attention.vibrate([new Attention.VibeProfile(50, 150)]);
        }
    }

    private function randomId() as String {
        var s = "";
        var abc = "abcdefghijklmnopqrstuvwxyz0123456789";
        for (var i = 0; i < 16; i++) {
            var r = Math.rand() % 36;
            if (r < 0) { r = -r; }
            s += abc.substring(r, r + 1);
        }
        return s + System.getTimer();
    }
}
