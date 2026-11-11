chrome.runtime.sendMessage({ping:1}, function(r){document.title = r && r.pong ? 'pong' : 'no-pong';});
