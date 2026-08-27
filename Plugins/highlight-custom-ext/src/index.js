var RULES = [
  { ext: 'txt', language: 'plaintext' },
  { ext: 'cfg', language: 'ini' },
  { ext: 'conf', language: 'ini' },
  { ext: 'log', language: 'plaintext' }
];

function applyRules() {
  for (var i = 0; i < RULES.length; i++) {
    var r = RULES[i];
    editor.setHighlightLanguageForExtension(r.ext, r.language);
  }
}

function clearRules() {
  for (var i = 0; i < RULES.length; i++) {
    editor.clearHighlightLanguageForExtension(RULES[i].ext);
  }
}

function activate() {
  commands.register('highlight.applyDefaults', function () {
    applyRules();
    ui.showStatusMessage('Highlight rules applied: txt,cfg,conf,log');
  });

  commands.register('highlight.clearDefaults', function () {
    clearRules();
    ui.showStatusMessage('Highlight rules cleared: txt,cfg,conf,log');
  });

  applyRules();
}

function deactivate() {}

module.exports = { activate: activate, deactivate: deactivate };
