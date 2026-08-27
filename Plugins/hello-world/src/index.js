// hello-world plugin for BestText.
//
// Demonstrates three common plugin patterns:
//   1. A no-op command (just shows a notification)
//   2. An editor-modifying command (reverse current line)
//   3. A read-only inspection command (count lines)
//
// Plugins run inside JavaScriptCore, on the main thread. The globals
// `editor`, `commands`, `ui`, `workspace`, `fs` are injected by the host and
// hop to the main actor only when they are not already on it.

var HIGHLIGHT_DEFAULTS = [
  { ext: 'txt',  language: 'plaintext' },
  { ext: 'cfg',  language: 'ini' },
  { ext: 'conf', language: 'ini' },
  { ext: 'log',  language: 'plaintext' }
];

function applyHighlightDefaults() {
  for (var i = 0; i < HIGHLIGHT_DEFAULTS.length; i++) {
    var r = HIGHLIGHT_DEFAULTS[i];
    editor.setHighlightLanguageForExtension(r.ext, r.language);
  }
}

function clearHighlightDefaults() {
  for (var i = 0; i < HIGHLIGHT_DEFAULTS.length; i++) {
    editor.clearHighlightLanguageForExtension(HIGHLIGHT_DEFAULTS[i].ext);
  }
}

function activate(context) {
  console.log('hello-world: activating (pluginId=' + context.pluginId + ')');

  commands.register('hello.greet', function () {
    ui.showNotification('Hello from a BestText plugin!');
  });

  commands.register('hello.reverseLine', function () {
    var line = editor.getCurrentLine();
    if (!line || !line.text) {
      ui.showNotification('No text on current line', 'warning');
      return;
    }
    var reversed = line.text.split('').reverse().join('');
    editor.replaceCurrentLine(reversed);
  });

  commands.register('hello.countLines', function () {
    var text = editor.getText();
    var count = text.length === 0 ? 0 : text.split('\n').length;
    ui.showNotification('Document has ' + count + ' line(s).');
  });

  commands.register('hello.applyHighlightDefaults', function () {
    applyHighlightDefaults();
    ui.showStatusMessage('Highlight rules applied: txt,cfg,conf,log');
  });

  commands.register('hello.clearHighlightDefaults', function () {
    clearHighlightDefaults();
    ui.showStatusMessage('Highlight rules cleared: txt,cfg,conf,log');
  });

  // Apply on startup too.
  applyHighlightDefaults();
}

function deactivate() {
  console.log('hello-world: deactivating');
}

module.exports = { activate: activate, deactivate: deactivate };
