import PebbleProtocol
import Foundation

extension PebbleCompanionRuntime {
    static func pageHTML(
        watchInfo: String,
        accountTokenLiteral: String,
        watchTokenLiteral: String,
        identifierLiteral: String,
        sourceLiteral: String
    ) -> String {
        """
        <!doctype html><meta charset="utf-8"><script>
        const listeners = {};
        const callbacks = {};
        let callbackID = 0;
        window.Pebble = {
          addEventListener: (name, callback) => (listeners[name] ||= []).push(callback),
          removeEventListener: (name, callback) => {
            listeners[name] = (listeners[name] || []).filter(fn => fn !== callback);
          },
          openURL: url => webkit.messageHandlers.pebble.postMessage({type:'openURL', url}),
          // WebKit hands a boolean over as a number that Swift cannot tell
          // from 1, so it is made one here.
          sendAppMessage: (message, success, failure) => {
            const id = ++callbackID; callbacks[id] = {success, failure};
            const values = {};
            for (const [key, value] of Object.entries(message || {}))
              values[key] = typeof value === 'boolean' ? (value ? 1 : 0) : value;
            webkit.messageHandlers.pebble.postMessage({type:'sendAppMessage', id, message: values});
            return id;
          },
          getActiveWatchInfo: () => (\(watchInfo)),
          getAccountToken: () => \(accountTokenLiteral),
          getWatchToken: () => \(watchTokenLiteral),
          // Refused honestly rather than answered with a made-up token: the
          // real one is the Locker's, and this app has no account (#20, not
          // planned). Deferred so the caller's own frame finishes first, the
          // way the real answer would arrive.
          getTimelineToken: (onSuccess, onFailure) => {
            webkit.messageHandlers.pebble.postMessage({type:'timelineToken'});
            setTimeout(() => onFailure && onFailure(), 0);
          },
          insertTimelinePin: pin =>
            webkit.messageHandlers.pebble.postMessage({
              type:'insertPin', pin: typeof pin === 'string' ? pin : JSON.stringify(pin)
            }),
          deleteTimelinePin: pin =>
            webkit.messageHandlers.pebble.postMessage({
              type:'deletePin', id: String(typeof pin === 'object' && pin ? pin.id : pin)
            }),
          // The launcher line, reloaded by the running app's own script (#92).
          // The callbacks get the slices back, which is the SDK's shape.
          appGlanceReload: (slices, onSuccess, onFailure) => {
            const id = ++callbackID;
            callbacks[id] = {
              success: onSuccess ? (() => onSuccess(slices)) : undefined,
              failure: onFailure ? (() => onFailure(slices)) : undefined
            };
            webkit.messageHandlers.pebble.postMessage({
              type:'appGlance', id, slices: JSON.stringify(slices == null ? [] : slices)
            });
          },
          // Refused honestly, like getTimelineToken above: subscriptions need
          // a timeline service and an account, and this app has neither (#20,
          // not planned). Defined at all so a caller falls to its failure
          // branch instead of dying on undefined.
          timelineSubscribe: (topic, onSuccess, onFailure) => {
            webkit.messageHandlers.pebble.postMessage({type:'timelineSubscription'});
            setTimeout(() => onFailure && onFailure(), 0);
          },
          timelineUnsubscribe: (topic, onSuccess, onFailure) => {
            webkit.messageHandlers.pebble.postMessage({type:'timelineSubscription'});
            setTimeout(() => onFailure && onFailure(), 0);
          },
          timelineSubscriptions: (onSuccess, onFailure) => {
            webkit.messageHandlers.pebble.postMessage({type:'timelineSubscription'});
            setTimeout(() => onFailure && onFailure(), 0);
          },
          // As text whatever was passed: a number or a missing body used to
          // fail the cast on the phone's side and the notification with it.
          showSimpleNotificationOnPebble: (title, body) =>
            webkit.messageHandlers.pebble.postMessage({
              type:'notification', title: String(title ?? ''), body: String(body ?? '')
            })
        };
        // `navigator.geolocation` is here but never answers: WebKit has no
        // public way for an app to grant it, on `WKUIDelegate` or on the newer
        // `WebPage.DeviceSensorAuthorization`, whose permissions are
        // `deviceOrientationAndMotion` and `mediaCapture` and nothing else. So
        // it is replaced by one that asks the app, which has the position
        // already for the weather it sends the watch.
        const positions = {};
        let positionID = 0;
        const ask = (success, failure) => {
          const id = ++positionID;
          positions[id] = {success, failure};
          webkit.messageHandlers.pebble.postMessage({type:'position', id});
          return id;
        };
        Object.defineProperty(navigator, 'geolocation', {configurable: true, value: {
          getCurrentPosition: (success, failure) => { ask(success, failure); },
          // Followed, not answered once: the entry stays and the app keeps
          // delivering into it until clearWatch (#90).
          watchPosition: (success, failure) => {
            const id = ++positionID;
            positions[id] = {success, failure, watching: true};
            webkit.messageHandlers.pebble.postMessage({type:'watchPosition', id});
            return id;
          },
          clearWatch: id => {
            if (positions[id] && positions[id].watching)
              webkit.messageHandlers.pebble.postMessage({type:'clearWatch', id});
            delete positions[id];
          }
        }});
        window.__pebblePosition = (id, position, error) => {
          const cb = positions[id]; if (!cb) return;
          if (!cb.watching) delete positions[id];
          if (position) cb.success?.(position); else cb.failure?.(error);
        };
        // `XMLHttpRequest`, answered by the app rather than by WebKit: PKJS
        // scripts were written for a runtime without the web's same-origin
        // rules, and the services they call (wikipedia, hobbyist APIs) offer
        // no CORS headers to a pebble.local origin — through WebKit their
        // requests died silently (#129).
        const xhrs = {};
        let xhrID = 0;
        class PebbleXMLHttpRequest {
          constructor() {
            this.readyState = 0; this.status = 0; this.statusText = '';
            this.responseText = ''; this.response = ''; this.responseType = '';
            this.timeout = 0; this._headers = {}; this._responseHeaders = '';
            this._listeners = {};
          }
          addEventListener(type, callback) { (this._listeners[type] ||= []).push(callback); }
          removeEventListener(type, callback) {
            this._listeners[type] = (this._listeners[type] || []).filter(fn => fn !== callback);
          }
          _fire(type) {
            const event = {type, target: this, currentTarget: this};
            if (typeof this['on' + type] === 'function') this['on' + type](event);
            (this._listeners[type] || []).slice().forEach(fn => fn.call(this, event));
          }
          open(method, url, async) {
            this._method = method; this._url = url; this._synchronous = async === false;
            this._aborted = false; this.readyState = 1; this._fire('readystatechange');
          }
          setRequestHeader(name, value) { this._headers[String(name)] = String(value); }
          getAllResponseHeaders() { return this._responseHeaders; }
          getResponseHeader(name) {
            const line = this._responseHeaders.split('\\r\\n')
              .find(l => l.toLowerCase().startsWith(String(name).toLowerCase() + ':'));
            return line ? line.slice(line.indexOf(':') + 1).trim() : null;
          }
          abort() {
            if (this._aborted || this.readyState === 0 || this.readyState === 4) return;
            this._aborted = true;
            this.readyState = 4; this.status = 0;
            this._fire('readystatechange'); this._fire('abort'); this._fire('loadend');
            this.readyState = 0;
          }
          // Refused rather than answered empty: the answer comes back through
          // a message, so a script reading responseText right after send()
          // would carry on with nothing and never learn why.
          send(body) {
            if (this._synchronous) {
              webkit.messageHandlers.pebble.postMessage({type: 'synchronousXHR', url: String(this._url)});
              throw new DOMException('Synchronous requests are not supported', 'InvalidAccessError');
            }
            const id = ++xhrID; xhrs[id] = this;
            webkit.messageHandlers.pebble.postMessage({
              type: 'xhr', id, method: String(this._method || 'GET'), url: String(this._url),
              headers: this._headers, body: body == null ? null : String(body),
              timeout: Number(this.timeout) || 0, responseType: String(this.responseType || '')
            });
          }
        }
        window.__pebbleXHRResult = (id, status, statusText, responseText, responseBase64, responseHeaders, failure) => {
          const x = xhrs[id]; if (!x) return;
          delete xhrs[id];
          if (x._aborted) return;
          x.readyState = 4;
          if (failure) {
            x._fire('readystatechange'); x._fire(failure); x._fire('loadend');
            return;
          }
          x.status = status; x.statusText = statusText;
          x.responseText = responseText; x._responseHeaders = responseHeaders;
          if (x.responseType === 'json') {
            try { x.response = JSON.parse(responseText); } catch (e) { x.response = null; }
          } else if (x.responseType === 'arraybuffer') {
            x.response = Uint8Array.from(atob(responseBase64 || ''), c => c.charCodeAt(0)).buffer;
          } else {
            x.response = responseText;
          }
          x._fire('readystatechange'); x._fire('load'); x._fire('loadend');
        };
        window.XMLHttpRequest = PebbleXMLHttpRequest;
        window.__pebbleDispatch = (name, detail) => (listeners[name] || []).forEach(fn => fn(detail));
        // The official runtime's shapes: `{data: {transactionId}}`, and on a
        // refusal the same with `error: "nack"`, passed again as the second
        // argument.
        window.__pebbleResult = (id, ok) => { const cb = callbacks[id]; if (!cb) return;
          delete callbacks[id];
          const e = ok ? {data: {transactionId: id}} : {data: {transactionId: id}, error: 'nack'};
          (ok ? cb.success : cb.failure)?.(e, e.error); };
        window.__pebbleApplicationID = \(identifierLiteral);
        eval(\(sourceLiteral));
        window.__pebbleDispatch('ready', {});
        </script>
        """
    }

    func javaScriptLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let literal = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return literal
    }

    /// The host a loaded application's page runs on, which is both where the
    /// page is loaded from and the only origin its messages are taken from.
    static func originHost(of applicationID: UUID) -> String {
        "\(applicationID.uuidString.lowercased()).pebble.local"
    }

    /// `Pebble.getActiveWatchInfo()`, as an object literal.
    ///
    /// The platform is the variant installed, not the watch's own: a script
    /// written for basalt alone branches on the names it knows, and handed
    /// "emery" takes none of them (`PrivatePKJSInterface.kt`
    /// `getActivePebbleWatchInfo`).
    static func watchInfoLiteral(
        for watch: ConnectedWatch?,
        running application: WatchApplication
    ) throws -> String {
        let info = ScriptWatchInfo(
            platform: watch?.model.map {
                (application.bestVariant(for: $0) ?? $0.platform).rawValue
            } ?? "unknown",
            model: watch?.model?.rawValue ?? "unknown",
            language: watch.map { $0.languageLocale.isEmpty ? "en_US" : $0.languageLocale } ?? "en_US",
            firmware: ScriptWatchInfo.Firmware(watch?.firmwareVersion)
        )
        let data = try JSONEncoder().encode(info)
        guard let literal = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return literal
    }
}

private struct ScriptWatchInfo: Encodable {
    struct Firmware: Encodable {
        var major = 0
        var minor = 0
        var patch = 0
        var suffix = ""

        /// `v4.36.2-rc1` as its numbers, the way the official runtime reads the
        /// tag (`FIRMWARE_VERSION_REGEX` in `SystemService.kt`). Zeros with the
        /// whole tag as the suffix made every `firmware.major >= 4` false.
        init(_ tag: String?) {
            guard let tag,
                  let match = tag.firstMatch(of: /v?([0-9]+)\.([0-9]+)(?:\.([0-9]+))?(?:-(.*))?/) else { return }
            major = Int(match.1) ?? 0
            minor = Int(match.2) ?? 0
            patch = match.3.flatMap { Int($0) } ?? 0
            suffix = match.4.map(String.init) ?? ""
        }
    }

    var platform: String
    var model: String
    var language: String
    var firmware: Firmware
}
