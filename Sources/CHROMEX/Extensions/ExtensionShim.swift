import Foundation

/// The JavaScript bridge injected into content scripts, popups, options pages and
/// background pages.
///
/// Three properties matter more than the API surface:
///
/// 1. The capability `token` is substituted into the shim's closure at injection
///    time. Page JavaScript cannot read the token, so it cannot impersonate an
///    extension or reach another extension's storage.
/// 2. Everything returns a callback *and* a promise, and failures surface as a
///    rejected promise rather than a thrown string.
/// 3. The shim fills the gaps a custom URL scheme creates — `crypto.randomUUID`,
///    `crypto.subtle.digest`, `navigator.clipboard` — so a React/Vue extension page
///    boots instead of dying on its first fingerprinting call.
enum ExtensionShim {
    static func source(token: String, extensionID: String, context: String, manifestJSON: String = "{}") -> String {
        let template = #"""
        (function () {
          "use strict";
          var TOKEN = "__CHROMEX_TOKEN__";
          var EXT_ID = "__CHROMEX_EXT_ID__";
          var CONTEXT = "__CHROMEX_CONTEXT__";
          var UI_LANGUAGE = "__CHROMEX_UI_LANGUAGE__";
          var MANIFEST = {};
          try { MANIFEST = JSON.parse(__CHROMEX_MANIFEST__ || "{}"); } catch (error) {}
          var BASE = "chromex-extension://" + EXT_ID + "/";
          var pending = {};
          var nextID = 1;
          var runtimeListeners = [];
          var storageListeners = [];
          var actionListeners = [];
          var alarmListeners = [];
          var installedListeners = [];
          var startupListeners = [];
          var tabUpdatedListeners = [];
          var tabRemovedListeners = [];
          var navigationListeners = [];
          var messageListeners = {};

          function report(message) {
            try { post("log", { level: "error", message: String(message) }); } catch (error) {}
          }

          function post(api, payload, callback) {
            var id = nextID++;
            if (callback) { pending[id] = callback; }
            try {
              webkit.messageHandlers.chromexBridge.postMessage({
                token: TOKEN,
                id: id,
                api: api,
                ctx: CONTEXT,
                payload: payload || {}
              });
            } catch (error) {
              if (callback) { delete pending[id]; callback(undefined, String(error)); }
            }
            return id;
          }

          function nativePost(payload, callback) {
            try {
              webkit.messageHandlers.chromexNative.postMessage(payload);
            } catch (error) {
              if (callback) { callback(null); }
            }
          }

          window.__chromexNativeReply = function (id, value) {
            var callback = pending["native-" + id];
            if (!callback) { return; }
            delete pending["native-" + id];
            callback(value);
          };

          window.__chromexReply = function (id, json, errorMessage) {
            var callback = pending[id];
            if (!callback) { return; }
            delete pending[id];
            var value;
            if (json) {
              try { value = JSON.parse(json); } catch (error) { value = undefined; }
            }
            callback(value, errorMessage || undefined);
          };

          function request(api, payload) {
            return new Promise(function (resolve, reject) {
              post(api, payload, function (value, errorMessage) {
                if (errorMessage) {
                  reject(new Error(errorMessage));
                } else {
                  resolve(value);
                }
              });
            });
          }

          function withCallback(promise, callback) {
            if (typeof callback === "function") {
              promise.then(function (value) { callback(value); },
                           function (error) {
                             chrome.runtime.lastError = { message: String(error && error.message || error) };
                             callback(undefined);
                           });
              return undefined;
            }
            return promise;
          }

          // ---------------------------------------------------------------
          // Secure-context gaps on a custom scheme.
          // ---------------------------------------------------------------

          try {
            Object.defineProperty(window, "isSecureContext", {
              get: function () { return true; },
              configurable: true
            });
          } catch (error) {}

          if (typeof crypto !== "undefined") {
            if (!crypto.randomUUID) {
              crypto.randomUUID = function () {
                var bytes = new Uint8Array(16);
                crypto.getRandomValues(bytes);
                bytes[6] = (bytes[6] & 0x0f) | 0x40;
                bytes[8] = (bytes[8] & 0x3f) | 0x80;
                var hex = [];
                for (var i = 0; i < 16; i++) {
                  hex.push((bytes[i] + 0x100).toString(16).substr(1));
                }
                return hex.slice(0, 4).join("") + "-" + hex.slice(4, 6).join("") + "-" +
                  hex.slice(6, 8).join("") + "-" + hex.slice(8, 10).join("") + "-" + hex.slice(10).join("");
              };
            }
            if (!crypto.subtle) {
              crypto.subtle = shimSubtle();
            }
          }

          function shimSubtle() {
            var K = [
              0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
              0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
              0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
              0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
              0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
              0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
              0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
              0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
            ];
            var H0 = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];

            function rotr(x, n) { return ((x >>> n) | (x << (32 - n))) >>> 0; }

            function digest(bytes) {
              var length = bytes.length;
              var bitLength = length * 8;
              var withPadding = new Uint8Array((((length + 8) >> 6) + 1) * 64);
              withPadding.set(bytes);
              withPadding[length] = 0x80;
              var view = new DataView(withPadding.buffer);
              view.setUint32(withPadding.length - 4, bitLength >>> 0, false);
              view.setUint32(withPadding.length - 8, Math.floor(bitLength / 0x100000000), false);

              var H = H0.slice();
              var W = new Array(64);
              for (var offset = 0; offset < withPadding.length; offset += 64) {
                for (var i = 0; i < 16; i++) {
                  W[i] = view.getUint32(offset + i * 4, false);
                }
                for (i = 16; i < 64; i++) {
                  var s0 = rotr(W[i - 15], 7) ^ rotr(W[i - 15], 18) ^ (W[i - 15] >>> 3);
                  var s1 = rotr(W[i - 2], 17) ^ rotr(W[i - 2], 19) ^ (W[i - 2] >>> 10);
                  W[i] = (W[i - 16] + s0 + W[i - 7] + s1) >>> 0;
                }
                var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
                for (i = 0; i < 64; i++) {
                  var S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
                  var ch = (e & f) ^ ((~e) & g);
                  var temp1 = (h + S1 + ch + K[i] + W[i]) >>> 0;
                  var S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
                  var maj = (a & b) ^ (a & c) ^ (b & c);
                  var temp2 = (S0 + maj) >>> 0;
                  h = g; g = f; f = e; e = (d + temp1) >>> 0;
                  d = c; c = b; b = a; a = (temp1 + temp2) >>> 0;
                }
                H[0] = (H[0] + a) >>> 0; H[1] = (H[1] + b) >>> 0;
                H[2] = (H[2] + c) >>> 0; H[3] = (H[3] + d) >>> 0;
                H[4] = (H[4] + e) >>> 0; H[5] = (H[5] + f) >>> 0;
                H[6] = (H[6] + g) >>> 0; H[7] = (H[7] + h) >>> 0;
              }
              var out = new Uint8Array(32);
              var outView = new DataView(out.buffer);
              for (i = 0; i < 8; i++) { outView.setUint32(i * 4, H[i], false); }
              return out;
            }

            function toBytes(data) {
              if (data instanceof ArrayBuffer) { return new Uint8Array(data); }
              if (data && data.buffer instanceof ArrayBuffer) {
                return new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength);
              }
              if (typeof data === "string") { return new TextEncoder().encode(data); }
              return new Uint8Array(0);
            }

            function hmacSha256(keyBytes, messageBytes) {
              var key = keyBytes;
              if (key.length > 64) { key = digest(key); }
              var padded = new Uint8Array(64);
              padded.set(key);
              var inner = new Uint8Array(64 + messageBytes.length);
              for (var i = 0; i < 64; i++) { inner[i] = padded[i] ^ 0x36; }
              inner.set(messageBytes, 64);
              var innerHash = digest(inner);
              var outer = new Uint8Array(64 + 32);
              for (var j = 0; j < 64; j++) { outer[j] = padded[j] ^ 0x5c; }
              outer.set(innerHash, 64);
              return digest(outer);
            }

            function unsupported(name) {
              return function () {
                return Promise.reject(new Error("chromex: crypto.subtle." + name + " is not implemented"));
              };
            }

            return {
              digest: function (algorithm, data) {
                var name = typeof algorithm === "string" ? algorithm : (algorithm && algorithm.name);
                return new Promise(function (resolve, reject) {
                  if (String(name).toUpperCase() !== "SHA-256") {
                    reject(new Error("chromex: only SHA-256 is implemented"));
                    return;
                  }
                  var result = digest(toBytes(data));
                  resolve(result.buffer);
                });
              },
              importKey: function (format, keyData, algorithm) {
                var name = typeof algorithm === "string" ? algorithm : (algorithm && algorithm.name);
                return new Promise(function (resolve, reject) {
                  if (String(name).toUpperCase() !== "HMAC") {
                    reject(new Error("chromex: crypto.subtle.importKey supports HMAC only"));
                    return;
                  }
                  resolve({ __chromexKey: true, bytes: toBytes(keyData), algorithm: algorithm });
                });
              },
              sign: function (algorithm, key, data) {
                return new Promise(function (resolve, reject) {
                  if (!key || !key.__chromexKey) {
                    reject(new Error("chromex: crypto.subtle.sign needs an imported HMAC key"));
                    return;
                  }
                  var algorithmName = typeof algorithm === "string" ? algorithm : (algorithm && algorithm.name);
                  if (String(algorithmName).toUpperCase() !== "HMAC") {
                    reject(new Error("chromex: crypto.subtle.sign supports HMAC only"));
                    return;
                  }
                  resolve(hmacSha256(key.bytes, toBytes(data)).buffer);
                });
              },
              verify: function (algorithm, key, signature, data) {
                return Promise.resolve(false);
              },
              generateKey: unsupported("generateKey"),
              deriveKey: unsupported("deriveKey"),
              deriveBits: unsupported("deriveBits"),
              encrypt: unsupported("encrypt"),
              decrypt: unsupported("decrypt"),
              wrapKey: unsupported("wrapKey"),
              unwrapKey: unsupported("unwrapKey"),
              exportKey: unsupported("exportKey")
            };
          }

          var clipboard = {
            writeText: function (text) {
              return new Promise(function (resolve) {
                var id = nextID++;
                pending["native-" + id] = function () { resolve(); };
                nativePost({ kind: "clipboardWrite", text: String(text), id: id });
              });
            },
            readText: function () {
              return new Promise(function (resolve) {
                var id = nextID++;
                pending["native-" + id] = function (value) { resolve(value); };
                nativePost({ kind: "clipboardRead", id: id });
              });
            }
          };
          try {
            Object.defineProperty(navigator, "clipboard", { value: clipboard, configurable: true });
          } catch (error) {}

          // ---------------------------------------------------------------
          // Chrome host-permission networking
          //
          // Extension pages in Chrome are not subject to CORS for hosts they
          // were granted. A WebKit page is, so absolute http(s) requests are
          // routed through native URLSession, gated by the same grant list.
          // ---------------------------------------------------------------

          function chromeBase64ToBytes(b64) {
            var binary = atob(b64 || "");
            var bytes = new Uint8Array(binary.length);
            for (var i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i); }
            return bytes;
          }

          function chromeBytesToBase64(bytes) {
            var binary = "";
            for (var i = 0; i < bytes.length; i++) { binary += String.fromCharCode(bytes[i]); }
            return btoa(binary);
          }

          function chromeTextToBase64(text) {
            return chromeBytesToBase64(new TextEncoder().encode(text));
          }

          function chromeIsAbsoluteHttp(url) {
            return /^https?:\/\//i.test(String(url || ""));
          }

          function chromeNativeFetch(url, init) {
            init = init || {};
            var headers = {};
            if (init.headers) {
              if (typeof init.headers.forEach === "function" && !Array.isArray(init.headers)) {
                init.headers.forEach(function (value, key) { headers[key] = value; });
              } else if (Array.isArray(init.headers)) {
                init.headers.forEach(function (pair) { headers[pair[0]] = pair[1]; });
              } else {
                Object.keys(init.headers).forEach(function (key) { headers[key] = init.headers[key]; });
              }
            }

            var bodyPromise = Promise.resolve(null);
            if (init.body != null) {
              if (typeof init.body === "string") {
                bodyPromise = Promise.resolve(chromeTextToBase64(init.body));
              } else if (init.body instanceof Blob) {
                bodyPromise = new Promise(function (resolve) {
                  var reader = new FileReader();
                  reader.onload = function () { resolve(String(reader.result).split(",")[1] || ""); };
                  reader.readAsDataURL(init.body);
                });
              } else if (init.body instanceof ArrayBuffer) {
                bodyPromise = Promise.resolve(chromeBytesToBase64(new Uint8Array(init.body)));
              } else if (ArrayBuffer.isView(init.body)) {
                bodyPromise = Promise.resolve(chromeBytesToBase64(new Uint8Array(
                  init.body.buffer, init.body.byteOffset, init.body.byteLength
                )));
              } else {
                bodyPromise = Promise.resolve(chromeTextToBase64(String(init.body)));
              }
            }

            return bodyPromise.then(function (bodyBase64) {
              return new Promise(function (resolve, reject) {
                post("network.fetch", {
                  url: url,
                  method: (init.method || "GET").toUpperCase(),
                  headers: headers,
                  body: bodyBase64
                }, function (value, errorMessage) {
                  if (errorMessage) {
                    reject(new TypeError(errorMessage));
                    return;
                  }
                  var responseHeaders = new Headers();
                  Object.keys(value.headers || {}).forEach(function (key) {
                    try { responseHeaders.append(key, value.headers[key]); } catch (error) {}
                  });
                  var body = chromeBase64ToBytes(value.body || "");
                  resolve(new Response(body, {
                    status: value.status || 200,
                    statusText: "",
                    headers: responseHeaders
                  }));
                });
              });
            });
          }

          if (typeof window.fetch === "function") {
            var chromeOriginalFetch = window.fetch.bind(window);
            window.fetch = function (input, init) {
              var url = typeof input === "string" ? input : (input && input.url);
              if (!chromeIsAbsoluteHttp(url)) {
                return chromeOriginalFetch(input, init);
              }
              return chromeNativeFetch(url, init);
            };
          }

          if (typeof window.XMLHttpRequest === "function") {
            var ChromeXHR = function () {
              this.readyState = 0;
              this.status = 0;
              this.statusText = "";
              this.responseText = "";
              this.response = "";
              this.responseType = "";
              this.onreadystatechange = null;
              this.onload = null;
              this.onerror = null;
              this._headers = {};
              this._url = "";
              this._method = "GET";
              this._native = null;
            };
            ChromeXHR.prototype.open = function (method, url) {
              this._method = method || "GET";
              this._url = url;
              this.readyState = 1;
              if (this.onreadystatechange) { try { this.onreadystatechange(); } catch (error) {} }
            };
            ChromeXHR.prototype.setRequestHeader = function (key, value) {
              this._headers[key] = value;
            };
            ChromeXHR.prototype.getAllResponseHeaders = function () {
              var self = this;
              return Object.keys(this._responseHeaders || {}).map(function (key) {
                return key + ": " + self._responseHeaders[key];
              }).join("\r\n");
            };
            ChromeXHR.prototype.getResponseHeader = function (key) {
              var headers = this._responseHeaders || {};
              var found = Object.keys(headers).filter(function (name) {
                return name.toLowerCase() === String(key).toLowerCase();
              })[0];
              return found ? headers[found] : null;
            };
            ChromeXHR.prototype.abort = function () {
              this._native = null;
            };
            ChromeXHR.prototype.send = function (body) {
              var self = this;
              var init = { method: this._method, headers: this._headers, body: body };
              chromeNativeFetch(this._url, init).then(function (response) {
                return response.text().then(function (text) {
                  self.status = response.status;
                  self.statusText = response.statusText;
                  self._responseHeaders = {};
                  response.headers.forEach(function (value, key) { self._responseHeaders[key] = value; });
                  self.responseText = text;
                  self.response = text;
                  self.readyState = 4;
                  if (self.onreadystatechange) { try { self.onreadystatechange(); } catch (error) {} }
                  if (self.onload) { try { self.onload(); } catch (error) {} }
                });
              }).catch(function (error) {
                self.readyState = 4;
                self.status = 0;
                if (self.onerror) { try { self.onerror(error); } catch (caught) {} }
                if (self.onreadystatechange) { try { self.onreadystatechange(); } catch (caught) {} }
              });
            };
            window.XMLHttpRequest = ChromeXHR;
          }

          // Extension pages are designed for Chrome's popup window, not a phone.
          // If the page is wider than the WebKit viewport, widen the layout
          // viewport so WebKit scales the whole UI to fit instead of clipping it.
          if (CONTEXT === "popup" || CONTEXT === "options") {
            var fitOnce = function () {
              try {
                var doc = document.documentElement;
                var overflow = doc.scrollWidth - window.innerWidth;
                if (overflow <= 8) { return; }
                if (sessionStorage.getItem("chromex-fitted") === "1") { return; }
                sessionStorage.setItem("chromex-fitted", "1");
                var width = Math.min(1200, Math.max(doc.scrollWidth, window.innerWidth));
                var meta = document.querySelector('meta[name="viewport"]');
                if (!meta) {
                  meta = document.createElement("meta");
                  meta.name = "viewport";
                  document.head.appendChild(meta);
                }
                meta.setAttribute("content", "width=" + width + ", initial-scale=1");
                window.location.reload();
              } catch (error) {}
            };
            window.addEventListener("load", function () { window.setTimeout(fitOnce, 120); });
          }

          // ---------------------------------------------------------------
          // chrome.*
          // ---------------------------------------------------------------

          var chrome = window.chrome || {};
          window.chrome = chrome;

          chrome.runtime = chrome.runtime || {};
          chrome.runtime.id = EXT_ID;
          chrome.runtime.lastError = undefined;
          chrome.runtime.getURL = function (path) {
            return BASE + String(path || "").replace(/^\/+/, "");
          };
          chrome.runtime.getManifest = function () {
            return MANIFEST;
          };
          chrome.runtime.getPlatformInfo = function (callback) {
            return withCallback(request("runtime.getPlatformInfo", {}), callback);
          };
          chrome.runtime.setUninstallURL = function () {};
          chrome.runtime.reload = function () {};
          chrome.runtime.getBackgroundPage = function (callback) {
            if (callback) { callback(window); }
          };
          chrome.runtime.sendMessage = function (a, b, c, d) {
            var message, callback;
            if (typeof a === "string") {
              message = b;
              callback = typeof c === "function" ? c : (typeof d === "function" ? d : null);
            } else {
              message = a;
              callback = typeof b === "function" ? b : (typeof c === "function" ? c : null);
            }
            return withCallback(request("runtime.sendMessage", { message: message }), callback);
          };
          chrome.runtime.onMessage = makeEvent(runtimeListeners);
          chrome.runtime.onMessageExternal = makeEvent([]);
          chrome.runtime.onConnect = makeEvent([]);
          chrome.runtime.onInstalled = makeEvent(installedListeners);
          chrome.runtime.onStartup = makeEvent(startupListeners);
          chrome.runtime.onSuspend = makeEvent([]);

          function makeEvent(list) {
            return {
              addListener: function (listener) {
                if (typeof listener === "function" && list.indexOf(listener) < 0) { list.push(listener); }
              },
              removeListener: function (listener) {
                var index = list.indexOf(listener);
                if (index >= 0) { list.splice(index, 1); }
              },
              hasListener: function (listener) { return list.indexOf(listener) >= 0; },
              dispatch: function () {
                var args = arguments;
                list.slice().forEach(function (listener) {
                  try { listener.apply(null, args); } catch (error) { report(error); }
                });
              }
            };
          }

          window.__chromexRuntimeEvent = function (name, detailJson) {
            var detail = {};
            try { detail = JSON.parse(detailJson || "{}"); } catch (error) {}
            if (name === "installed") { chrome.runtime.onInstalled.dispatch(detail); }
            if (name === "startup") { chrome.runtime.onStartup.dispatch(); }
          };

          chrome.storage = chrome.storage || {};
          function makeArea(area) {
            return {
              get: function (keys, callback) {
                return withCallback(request("storage.get", { area: area, keys: keys }), callback);
              },
              getBytesInUse: function (keys, callback) {
                return withCallback(request("storage.bytes", { area: area }), callback);
              },
              set: function (items, callback) {
                return withCallback(request("storage.set", { area: area, items: items }), callback);
              },
              remove: function (keys, callback) {
                return withCallback(request("storage.remove", { area: area, keys: keys }), callback);
              },
              clear: function (callback) {
                return withCallback(request("storage.clear", { area: area }), callback);
              }
            };
          }
          chrome.storage.local = makeArea("local");
          chrome.storage.sync = makeArea("local");
          chrome.storage.session = makeArea("local");
          chrome.storage.managed = { get: function (keys, callback) { withCallback(Promise.resolve({}), callback); } };
          chrome.storage.onChanged = makeEvent(storageListeners);

          chrome.tabs = chrome.tabs || {};
          chrome.tabs.query = function (query, callback) {
            return withCallback(request("tabs.query", { query: query || {} }), callback);
          };
          chrome.tabs.create = function (options, callback) {
            return withCallback(request("tabs.create", { options: options || {} }), callback);
          };
          chrome.tabs.update = function (tabID, options, callback) {
            return withCallback(request("tabs.update", {
              tabId: tabID || 0,
              url: options && options.url,
              active: options && options.active
            }), callback);
          };
          chrome.tabs.reload = function (tabID, callback) {
            return withCallback(request("tabs.reload", { tabId: tabID || 0 }), callback);
          };
          chrome.tabs.remove = function (tabID, callback) {
            return withCallback(request("tabs.remove", { tabId: tabID || 0 }), callback);
          };
          chrome.tabs.sendMessage = function (tabID, message, callback) {
            var id = nextID++;
            if (typeof callback === "function") { pending[id] = callback; }
            post("tabs.sendMessage", { tabId: tabID, message: message });
            return id;
          };
          chrome.tabs.get = function (tabID, callback) {
            return withCallback(request("tabs.query", { query: {} }).then(function (tabs) {
              for (var i = 0; i < tabs.length; i++) {
                if (tabs[i].id === tabID) { return tabs[i]; }
              }
              return undefined;
            }), callback);
          };
          chrome.tabs.onUpdated = makeEvent(tabUpdatedListeners);
          chrome.tabs.onRemoved = makeEvent(tabRemovedListeners);
          chrome.tabs.onActivated = makeEvent([]);
          chrome.tabs.onCreated = makeEvent([]);

          window.__chromexTabUpdated = function (json) {
            var detail = {};
            try { detail = JSON.parse(json); } catch (error) {}
            chrome.tabs.onUpdated.dispatch(detail.tabId || 0, { url: detail.url, status: "complete" }, detail);
          };
          window.__chromexNavigation = function (json) {
            var detail = {};
            try { detail = JSON.parse(json); } catch (error) {}
            chrome.webNavigation.onCommitted.dispatch({
              tabId: detail.tabId || 0,
              url: detail.url || "",
              frameId: 0,
              timeStamp: Date.now()
            });
            chrome.webNavigation.onCompleted.dispatch({
              tabId: detail.tabId || 0,
              url: detail.url || "",
              frameId: 0,
              timeStamp: Date.now()
            });
          };

          chrome.scripting = chrome.scripting || {};
          chrome.scripting.executeScript = function (injection, callback) {
            var target = (injection && injection.target) || {};
            return withCallback(request("scripting.executeScript", {
              target: target,
              files: injection && injection.files,
              func: injection && injection.func ? String(injection.func) : undefined,
              code: injection && injection.args && injection.args.length ? undefined : undefined,
              worldId: injection && injection.worldId
            }), callback);
          };
          chrome.scripting.insertCSS = function (injection, callback) {
            var target = (injection && injection.target) || {};
            return withCallback(request("scripting.insertCSS", {
              tabId: target.tabId,
              css: injection && injection.css,
              files: injection && injection.files
            }), callback);
          };

          chrome.i18n = chrome.i18n || {};
          chrome.i18n.getMessage = function (name, substitutions, callback) {
            var subs = [];
            if (typeof substitutions === "string") { subs = [substitutions]; }
            else if (Array.isArray(substitutions)) { subs = substitutions; }
            var promise = request("i18n.getMessage", { name: String(name), substitutions: subs }).then(function (value) {
              return value === null || value === undefined ? "" : String(value);
            });
            if (typeof callback === "function") { promise.then(callback); return undefined; }
            return promise;
          };
          chrome.i18n.getUILanguage = function () { return UI_LANGUAGE; };
          chrome.i18n.getAcceptLanguages = function (callback) {
            return withCallback(request("i18n.getAcceptLanguages", {}), callback);
          };

          chrome.permissions = chrome.permissions || {};
          chrome.permissions.contains = function (permissions, callback) {
            return withCallback(request("permissions.contains", { permissions: permissions || {} }), callback);
          };
          chrome.permissions.getAll = function (callback) {
            return withCallback(request("permissions.getAll", {}), callback);
          };
          chrome.permissions.request = function (permissions, callback) {
            return withCallback(request("permissions.request", { permissions: permissions || {} }), callback);
          };

          chrome.action = chrome.action || {};
          chrome.action.setBadgeText = function (details, callback) {
            if (callback) { callback(); }
          };
          chrome.action.setBadgeBackgroundColor = function (details, callback) { if (callback) { callback(); } };
          chrome.action.setTitle = function (details, callback) { if (callback) { callback(); } };
          chrome.action.setIcon = function (details, callback) { if (callback) { callback(); } };
          chrome.action.getBadgeText = function (details, callback) { withCallback(Promise.resolve(""), callback); };
          chrome.action.onClicked = makeEvent(actionListeners);
          window.__chromexActionClicked = function () {
            chrome.action.onClicked.dispatch({ id: EXT_ID });
          };

          chrome.alarms = chrome.alarms || {};
          chrome.alarms.create = function (name, info) {
            if (typeof name === "object") { info = name; name = ""; }
            post("alarms.create", {
              name: name || "",
              delayInMinutes: info && info.when ? 0 : (info && info.delayInMinutes),
              periodInMinutes: info && info.periodInMinutes
            });
          };
          chrome.alarms.clear = function (name, callback) {
            return withCallback(request("alarms.clear", { name: name || "" }), callback);
          };
          chrome.alarms.clearAll = function (callback) {
            return withCallback(request("alarms.clearAll", {}), callback);
          };
          chrome.alarms.get = function (name, callback) {
            return withCallback(request("alarms.getAll", {}).then(function (all) {
              for (var i = 0; i < all.length; i++) {
                if (all[i].name === name) { return all[i]; }
              }
              return undefined;
            }), callback);
          };
          chrome.alarms.getAll = function (callback) {
            return withCallback(request("alarms.getAll", {}), callback);
          };
          chrome.alarms.onAlarm = makeEvent(alarmListeners);
          window.__chromexAlarm = function (json) {
            var detail = {};
            try { detail = JSON.parse(json); } catch (error) {}
            chrome.alarms.onAlarm.dispatch({ name: detail.name || "" });
          };

          chrome.downloads = chrome.downloads || {};
          chrome.downloads.download = function (options, callback) {
            var url = typeof options === "string" ? options : (options && options.url);
            return withCallback(request("downloads.download", { url: url }), callback);
          };
          chrome.downloads.search = function (query, callback) { withCallback(Promise.resolve([]), callback); };
          chrome.downloads.cancel = function (id, callback) { if (callback) { callback(); } };
          chrome.downloads.onChanged = makeEvent([]);

          chrome.webNavigation = chrome.webNavigation || {};
          chrome.webNavigation.onCommitted = makeEvent(navigationListeners);
          chrome.webNavigation.onCompleted = makeEvent([]);
          chrome.webNavigation.onBeforeNavigate = makeEvent([]);
          chrome.webNavigation.onDOMContentLoaded = makeEvent([]);
          chrome.webNavigation.onHistoryStateUpdated = makeEvent([]);

          function observedWebRequestEvent(event, name) {
            var add = event.addListener;
            event.addListener = function () {
              report("chrome.webRequest." + name + ".addListener");
              return add.apply(event, arguments);
            };
            return event;
          }

          chrome.webRequest = chrome.webRequest || {};
          chrome.webRequest.onBeforeRequest = observedWebRequestEvent(makeEvent([]), "onBeforeRequest");
          chrome.webRequest.onBeforeSendHeaders = observedWebRequestEvent(makeEvent([]), "onBeforeSendHeaders");
          chrome.webRequest.onSendHeaders = makeEvent([]);
          chrome.webRequest.onHeadersReceived = observedWebRequestEvent(makeEvent([]), "onHeadersReceived");
          chrome.webRequest.onResponseStarted = makeEvent([]);
          chrome.webRequest.onCompleted = observedWebRequestEvent(makeEvent([]), "onCompleted");
          chrome.webRequest.onErrorOccurred = observedWebRequestEvent(makeEvent([]), "onErrorOccurred");
          chrome.webRequest.handlerBehaviorChanged = function (callback) { if (callback) { callback(); } };

          chrome.declarativeNetRequest = chrome.declarativeNetRequest || {};
          chrome.declarativeNetRequest.getDynamicRules = function (callback) {
            withCallback(Promise.resolve([]), callback);
          };
          chrome.declarativeNetRequest.getSessionRules = function (callback) {
            withCallback(Promise.resolve([]), callback);
          };
          chrome.declarativeNetRequest.updateDynamicRules = function (rules, callback) {
            if (callback) { callback(); }
          };
          chrome.declarativeNetRequest.updateSessionRules = function (rules, callback) {
            if (callback) { callback(); }
          };
          chrome.declarativeNetRequest.isRegexSupported = function (query, callback) {
            withCallback(Promise.resolve({ isSupported: false }), callback);
          };

          chrome.offscreen = chrome.offscreen || {};
          chrome.offscreen.createDocument = function (options, callback) {
            withCallback(Promise.resolve(), callback);
          };
          chrome.offscreen.closeDocument = function (callback) {
            withCallback(Promise.resolve(), callback);
          };

          chrome.proxy = chrome.proxy || {};
          chrome.proxy.settings = chrome.proxy.settings || {};
          chrome.proxy.settings.set = function (details, callback) {
            report("chrome.proxy.settings.set: " + String(JSON.stringify(details && details.value || {})));
            if (callback) { callback(); }
          };
          chrome.proxy.settings.get = function (details, callback) {
            withCallback(Promise.resolve({ value: { mode: "direct" } }), callback);
          };
          chrome.proxy.settings.clear = function (details, callback) { if (callback) { callback(); } };

          chrome.system = chrome.system || {};
          chrome.system.cpu = chrome.system.cpu || {};
          chrome.system.cpu.getInfo = function (callback) {
            return withCallback(request("system.cpu", {}), callback);
          };
          chrome.system.memory = chrome.system.memory || {};
          chrome.system.memory.getInfo = function (callback) {
            return withCallback(request("system.memory", {}), callback);
          };

          chrome.contextMenus = chrome.contextMenus || {};
          chrome.contextMenus.create = function (details, callback) { if (callback) { callback(); } };
          chrome.contextMenus.removeAll = function (callback) { if (callback) { callback(); } };
          chrome.contextMenus.onClicked = makeEvent([]);

          chrome.notifications = chrome.notifications || {};
          chrome.notifications.create = function (id, options, callback) {
            var identifier = "chromex-" + Date.now();
            if (typeof id === "function") { id(identifier); }
            else if (typeof callback === "function") { callback(identifier); }
            return identifier;
          };
          chrome.notifications.clear = function (id, callback) { if (callback) { callback(true); } };
          chrome.notifications.onClicked = makeEvent([]);

          chrome.commands = chrome.commands || {};
          chrome.commands.getAll = function (callback) { withCallback(Promise.resolve([]), callback); };
          chrome.commands.onCommand = makeEvent([]);

          chrome.omnibox = chrome.omnibox || {};
          chrome.omnibox.setDefaultSuggestion = function () {};
          chrome.omnibox.onInputChanged = makeEvent([]);
          chrome.omnibox.onInputEntered = makeEvent([]);

          chrome.cookies = chrome.cookies || {};
          chrome.cookies.get = function (details, callback) { withCallback(Promise.resolve(null), callback); };
          chrome.cookies.getAll = function (details, callback) { withCallback(Promise.resolve([]), callback); };
          chrome.cookies.set = function (details, callback) { withCallback(Promise.resolve(null), callback); };
          chrome.cookies.remove = function (details, callback) { withCallback(Promise.resolve(null), callback); };

          chrome.history = chrome.history || {};
          chrome.history.search = function (query, callback) { withCallback(Promise.resolve([]), callback); };
          chrome.bookmarks = chrome.bookmarks || {};
          chrome.bookmarks.search = function (query, callback) { withCallback(Promise.resolve([]), callback); };
          chrome.bookmarks.getTree = function (callback) { withCallback(Promise.resolve([]), callback); };

          chrome.identity = chrome.identity || {};
          chrome.identity.getAuthToken = function (details, callback) {
            if (typeof callback === "function") {
              chrome.runtime.lastError = { message: "identity is not available on iOS" };
              callback(undefined);
            }
            return Promise.reject(new Error("identity is not available on iOS"));
          };

          chrome.tabGroups = chrome.tabGroups || {};
          chrome.tabGroups.query = function (query, callback) { withCallback(Promise.resolve([]), callback); };

          // ---------------------------------------------------------------
          // Message routing
          // ---------------------------------------------------------------

          window.__chromexStorageChanged = function (changesJson) {
            var changes;
            try { changes = JSON.parse(changesJson); } catch (error) { return; }
            chrome.storage.onChanged.dispatch(changes, "local");
          };

          window.__chromexDispatch = function (requestID, payloadJson) {
            var message;
            try { message = JSON.parse(payloadJson); } catch (error) { return "__none__"; }
            if (!runtimeListeners.length) { return "__none__"; }
            var sender = {
              id: EXT_ID,
              url: location.href,
              tab: { id: 0, url: location.href },
              frameId: 0
            };
            var responded = false;
            function sendResponse(value) {
              if (responded) { return; }
              responded = true;
              post("runtime.response", { requestId: requestID, value: value });
            }
            runtimeListeners.slice().forEach(function (listener) {
              try {
                var result = listener(message, sender, sendResponse);
                if (result && typeof result.then === "function") {
                  result.then(sendResponse, function (error) {
                    sendResponse({ __error: String(error) });
                  });
                } else if (result !== undefined && result !== true && result !== null) {
                  sendResponse(result);
                }
              } catch (error) {
                sendResponse({ __error: String(error) });
              }
            });
            return "__handled__";
          };

          // ---------------------------------------------------------------
          // Desktop Chrome surfaces WebKit does not have
          // ---------------------------------------------------------------

          if (!navigator.userAgentData) {
            var uaBrands = [
              { brand: "Chromium", version: "131" },
              { brand: "Google Chrome", version: "131" },
              { brand: "Not_A Brand", version: "24" }
            ];
            var uaData = {
              brands: uaBrands,
              mobile: false,
              platform: "Windows",
              getHighEntropyValues: function () {
                return Promise.resolve({
                  brands: uaBrands,
                  mobile: false,
                  platform: "Windows",
                  platformVersion: "10.0.0",
                  architecture: "x86",
                  bitness: "64",
                  model: "",
                  uaFullVersion: "131.0.0.0",
                  fullVersionList: uaBrands,
                  wow64: false
                });
              },
              toJSON: function () { return { brands: uaBrands, mobile: false, platform: "Windows" }; }
            };
            try {
              Object.defineProperty(navigator, "userAgentData", { value: uaData, configurable: true });
            } catch (error) {}
          }

          chrome.extension = chrome.extension || {};
          chrome.extension.getURL = chrome.runtime.getURL;
          chrome.extension.getBackgroundPage = chrome.runtime.getBackgroundPage;
          chrome.extension.isAllowedIncognitoAccess = function (callback) { if (callback) { callback(false); } };
          chrome.extension.sendMessage = chrome.runtime.sendMessage;
          chrome.extension.onMessage = chrome.runtime.onMessage;

          chrome.windows = chrome.windows || {};
          chrome.windows.WINDOW_ID_CURRENT = -2;
          chrome.windows.getCurrent = function (callback) {
            withCallback(chrome.tabs.query({ active: true }).then(function (tabs) {
              return { id: 0, focused: true, type: "normal", tabs: tabs };
            }), callback);
          };
          chrome.windows.getAll = function (options, callback) {
            if (typeof options === "function") { callback = options; }
            withCallback(chrome.tabs.query({}).then(function (tabs) {
              return [{ id: 0, focused: true, type: "normal", tabs: tabs }];
            }), callback);
          };
          chrome.windows.create = function (options, callback) {
            report("chrome.windows.create: " + String(JSON.stringify(options || {})));
            var url = options && options.url;
            if (url) {
              chrome.tabs.create({ url: url, active: true }, function (tab) {
                if (callback) { callback({ id: 0, type: "normal", tabs: [tab] }); }
              });
            } else if (callback) {
              callback({ id: 0, type: "normal", tabs: [] });
            }
          };
          chrome.windows.remove = function (id, callback) { if (callback) { callback(); } };
          chrome.windows.update = function (id, info, callback) { if (callback) { callback({ id: id || 0 }); } };
          chrome.windows.onRemoved = makeEvent([]);
          chrome.windows.onFocusChanged = makeEvent([]);
          chrome.windows.onCreated = makeEvent([]);

          var nativePorts = {};
          var nextPortID = 0;

          function makeNativePort(portId, name) {
            var messageListeners = [];
            var disconnectListeners = [];
            var port = {
              name: name || "",
              sender: { id: EXT_ID, url: location.href },
              onMessage: makeEvent(messageListeners),
              onDisconnect: makeEvent(disconnectListeners),
              postMessage: function (message) {
                post("runtime.port.postMessage", { portId: portId, message: message });
              },
              disconnect: function () {
                post("runtime.port.disconnect", { portId: portId });
                delete nativePorts[portId];
                disconnectListeners.slice().forEach(function (listener) {
                  try { listener(port); } catch (error) {}
                });
              }
            };
            nativePorts[portId] = port;
            return port;
          }

          chrome.runtime.connect = function (extensionId, connectInfo) {
            if (connectInfo === undefined && extensionId && typeof extensionId === "object") {
              connectInfo = extensionId;
              extensionId = EXT_ID;
            }
            var portId = EXT_ID + ":" + (++nextPortID) + ":" + Math.random().toString(36).slice(2);
            var port = makeNativePort(portId, (connectInfo && connectInfo.name) || "");
            post("runtime.connect", { portId: portId, name: port.name });
            return port;
          };
          chrome.runtime.onConnect = makeEvent([]);

          window.__chromexIncomingPort = function (portId, name, senderJson) {
            var port = makeNativePort(portId, name);
            try { port.sender = JSON.parse(senderJson || "{}"); } catch (error) {}
            chrome.runtime.onConnect.dispatch(port);
          };

          window.__chromexPortMessage = function (portId, payloadJson) {
            var port = nativePorts[portId];
            if (!port) { return; }
            var message;
            try { message = JSON.parse(payloadJson); } catch (error) { return; }
            port.onMessage.dispatch(message, port);
          };

          window.__chromexPortDisconnect = function (portId) {
            var port = nativePorts[portId];
            if (!port) { return; }
            delete nativePorts[portId];
            port.onDisconnect.dispatch(port);
          };

          var noopApis = {
            management: { getAll: [], getSelf: {}, launchApp: undefined },
            idle: { queryState: "active" },
            power: {},
            sessions: { getRecentlyClosed: [], restore: {} },
            tts: { getVoices: [] },
            fontSettings: { getFontList: [] },
            topSites: { get: [] },
            search: { query: [] },
            certificates: {}
          };
          Object.keys(noopApis).forEach(function (name) {
            var namespace = chrome[name] || {};
            Object.keys(noopApis[name]).forEach(function (method) {
              if (!namespace[method]) {
                namespace[method] = function () {
                  var args = Array.prototype.slice.call(arguments);
                  var callback = args.filter(function (arg) { return typeof arg === "function"; })[0];
                  var value = noopApis[name][method];
                  if (callback) { callback(typeof value === "object" ? value : undefined); }
                  return Promise.resolve(value);
                };
              }
            });
            if (!namespace.onChanged) { namespace.onChanged = makeEvent([]); }
            chrome[name] = namespace;
          });

          // Any chrome.* member an extension still reaches for is reported by
          // name, so a missing surface shows up in diagnostics instead of as an
          // opaque TypeError inside obfuscated code.
          function observedChromeNamespace(target) {
            if (!target || typeof target !== "object") { return target; }
            return new Proxy(target, {
              get: function (object, property) {
                if (property in object) { return object[property]; }
                if (typeof property === "symbol") { return undefined; }
                report("chrome." + String(property) + " is not implemented");
                return undefined;
              }
            });
          }
          Object.keys(chrome).forEach(function (name) {
            if (chrome[name] && typeof chrome[name] === "object") {
              chrome[name] = observedChromeNamespace(chrome[name]);
            }
          });
          window.chrome = observedChromeNamespace(chrome);

          if (CONTEXT !== "content") {
            window.addEventListener("error", function (event) {
              var target = event.target;
              var where = (target && target !== window)
                ? (target.src || target.href || target.localName || "")
                : "";
              report((event.message || "script error") + " @ " + (event.filename || where || "") + ":" + (event.lineno || 0));
            }, true);
            window.addEventListener("unhandledrejection", function (event) {
              report("unhandled rejection: " + String(event.reason && event.reason.stack ? event.reason.stack : event.reason));
            });
            var originalError = console.error;
            console.error = function () {
              try {
                var parts = [];
                for (var i = 0; i < arguments.length; i++) { parts.push(String(arguments[i])); }
                report(parts.join(" "));
              } catch (error) {}
              if (originalError) { originalError.apply(console, arguments); }
            };

            if (CONTEXT === "popup" || CONTEXT === "options") {
              window.setTimeout(function () {
                try {
                  var app = document.getElementById("app");
                  if (app && app.childElementCount === 0) {
                    report("extension page booted empty: #app has no children (readyState " + document.readyState + ")");
                  } else if (app) {
                    report("extension page rendered " + app.childElementCount + " node(s)");
                  } else {
                    report("extension page has no #app element (readyState " + document.readyState + ")");
                  }
                } catch (error) {}
              }, 2500);
            }
          }
        })();
        """#

        let uiLanguage = Locale.current.language.languageCode?.identifier
            ?? Locale.current.identifier
            ?? "en"
        return template
            .replacingOccurrences(of: "__CHROMEX_TOKEN__", with: token)
            .replacingOccurrences(of: "__CHROMEX_EXT_ID__", with: extensionID)
            .replacingOccurrences(of: "__CHROMEX_CONTEXT__", with: context)
            .replacingOccurrences(of: "__CHROMEX_UI_LANGUAGE__", with: uiLanguage)
            .replacingOccurrences(of: "__CHROMEX_MANIFEST__", with: JSBridge.literal(manifestJSON))
    }

    /// Wraps a background script in a minimal HTML document so WebKit can host it.
    static func backgroundDocument(scriptPaths: [String]) -> String {
        let tags = scriptPaths.map { path in
            "<script src=\"\(path)\"></script>"
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width"></head>
        <body>
        \(tags)
        </body>
        </html>
        """
    }
}
