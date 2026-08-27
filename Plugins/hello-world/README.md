# hello-world

Minimal example SheepText plugin. Registers three palette commands:

- **Hello: Greet** — shows a notification
- **Hello: Reverse Current Line** — reverses text on the current line (bound to `⌘⌥R`)
- **Hello: Count Lines in Document** — counts lines
- **Hello: Apply Highlight Extension Rules** — set default highlight mapping for `txt/cfg/conf/log`
- **Hello: Clear Highlight Extension Rules** — remove those mappings

## Install

Copy this folder into:

```
~/Library/Application Support/SheepText/Plugins/hello-world/
```

Then run **Developer: Reload Plugins** from the command palette (`⌘⇧P`).

## Learn

See [`docs/PLUGIN_API.md`](../../docs/PLUGIN_API.md) for the full API.

Highlight customization APIs used in this plugin:

```js
editor.setHighlightLanguageForExtension(ext, language)
editor.clearHighlightLanguageForExtension(ext)
```
