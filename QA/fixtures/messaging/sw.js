chrome.runtime.onMessage.addListener(function(m, s, respond){if(m && m.ping){respond({pong:true});} return true;});
