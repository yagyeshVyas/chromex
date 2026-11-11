import Foundation

/// The JavaScript bridge injected into content scripts, popups and background pages.
///
/// Two properties matter more than the API surface:
///
/// 1. The capability `token` is substituted into the shim's closure at injection
///    time. Page JavaScript can call `chrome.runtime.sendMessage`, but it cannot
///    read the token, so it cannot impersonate an extension and reach another
///    extension's storage.
/// 2. Everything returns a callback *and* a promise, and failures surface as a
///    rejected promise rather than a thrown string.
enum ExtensionShim {
    static func source(token: String, extensionID: String, context: String) -> String {
        let template = #"""
        (function () {
          "use strict";
          var TOKEN = "__CHROMEX_TOKEN__";
          var EXT_ID = "__CHROMEX_EXT_ID__";
          var CONTEXT = "__CHROMEX_CONTEXT__";
          var BASE = "chromex-extension://" + EXT_ID + "/";
          var pending = {};
          var nextID = 1;
          var runtimeListeners = [];
          var storageListeners = [];

          function post(api, payload, callback) {
            var id = nextID++;
            if (callback) { pending[id] = callback; }
            try {
              webkit.messageHandlers.chromexBridge.postMessage({
                token: TOKEN,
                id: id,
                api: api,
                payload: payload || {}
              });
            } catch (error) {
              if (callback) { delete pending[id]; callback(undefined, String(error)); }
            }
            return id;
          }

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

          var chrome = window.chrome || {};
          window.chrome = chrome;

          chrome.runtime = chrome.runtime || {};
          chrome.runtime.id = EXT_ID;
          chrome.runtime.lastError = undefined;
          chrome.runtime.getURL = function (path) {
            return BASE + String(path || "").replace(/^\/+/, "");
          };
          chrome.runtime.sendMessage = function (message, callback) {
            return withCallback(request("runtime.sendMessage", { message: message }), callback);
          };
          chrome.runtime.onMessage = {
            addListener: function (listener) {
              if (typeof listener === "function") { runtimeListeners.push(listener); }
            },
            removeListener: function (listener) {
              runtimeListeners = runtimeListeners.filter(function (item) { return item !== listener; });
            },
            hasListener: function (listener) { return runtimeListeners.indexOf(listener) >= 0; }
          };

          chrome.storage = chrome.storage || {};
          function makeArea(area) {
            return {
              get: function (keys, callback) {
                return withCallback(request("storage.get", { area: area, keys: keys }), callback);
              },
              set: function (items, callback) {
                return withCallback(request("storage.set", { area: area, items: items }), callback);
              },
              remove: function (keys, callback) {
                return withCallback(request("storage.remove", { area: area, keys: keys }), callback);
              },
              clear: function (callback) {
                return withCallback(request("storage.clear", { area: area }), callback);
              },
              getBytesInUse: function (keys, callback) {
                return withCallback(request("storage.bytes", { area: area }), callback);
              }
            };
          }
          chrome.storage.local = makeArea("local");
          chrome.storage.sync = makeArea("local");
          chrome.storage.session = makeArea("local");
          chrome.storage.onChanged = {
            addListener: function (listener) {
              if (typeof listener === "function") { storageListeners.push(listener); }
            }
          };

          chrome.tabs = chrome.tabs || {};
          chrome.tabs.query = function (query, callback) {
            return withCallback(request("tabs.query", { query: query || {} }), callback);
          };
          chrome.tabs.create = function (options, callback) {
            return withCallback(request("tabs.create", { options: options || {} }), callback);
          };

          chrome.action = chrome.action || {};
          chrome.action.setBadgeText = function () { /* not supported in this build */ };

          window.__chromexStorageChanged = function (changesJson) {
            var changes;
            try { changes = JSON.parse(changesJson); } catch (error) { return; }
            storageListeners.forEach(function (listener) {
              try { listener(changes, "local"); } catch (error) {}
            });
          };

          window.__chromexDispatch = function (requestID, payloadJson) {
            var message;
            try { message = JSON.parse(payloadJson); } catch (error) { return "__none__"; }
            if (!runtimeListeners.length) { return "__none__"; }
            var sender = { id: EXT_ID, url: location.href };
            var responded = false;
            function sendResponse(value) {
              if (responded) { return; }
              responded = true;
              post("runtime.response", { requestId: requestID, value: value });
            }
            runtimeListeners.forEach(function (listener) {
              try {
                var result = listener(message, sender, sendResponse);
                if (result !== undefined && result !== true && result !== null) {
                  sendResponse(result);
                }
              } catch (error) {
                sendResponse({ __error: String(error) });
              }
            });
            return "__handled__";
          };

          if (CONTEXT === "background") {
            window.addEventListener("unhandledrejection", function (event) {
              post("log", { level: "error", message: String(event.reason) });
            });
          }
        })();
        """#

        return template
            .replacingOccurrences(of: "__CHROMEX_TOKEN__", with: token)
            .replacingOccurrences(of: "__CHROMEX_EXT_ID__", with: extensionID)
            .replacingOccurrences(of: "__CHROMEX_CONTEXT__", with: context)
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
