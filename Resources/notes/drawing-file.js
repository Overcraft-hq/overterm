// A drawing's scene as Obsidian Excalidraw writes it: JSON, or lz-string's
// base64 in lines of 256 (`compress` in the plugin's main.js) — for the
// drawing page and for drawings embedded in a note's reading view.
"use strict";
window.DrawingFile = (() => {
  const { LZString } = window.Draw;

  function compress(json) {
    const base64 = LZString.compressToBase64(json);
    let out = "";
    for (let i = 0; i < base64.length; i += 256) out += base64.slice(i, i + 256) + "\n\n";
    return out.trim();
  }

  function decompress(text) {
    return LZString.decompressFromBase64(text.replace(/[\n\r]/g, ""));
  }

  /** The scene's object from the file's text and its encoding. */
  function read(scene, encoding) {
    const json = encoding === "compressed-json" ? decompress(scene) : scene;
    if (!json) throw new Error("the drawing's data can't be read");
    return JSON.parse(json);
  }

  /** The scene as the file holds it: tab-indented JSON, as the plugin writes. */
  function write(elements, appState, files, encoding) {
    const X = window.Draw.Excalidraw;
    const scene = JSON.parse(X.serializeAsJSON(elements, appState, files, "local"));
    scene.source = "https://github.com/Overcraft-hq/overterm";
    const json = JSON.stringify(scene, null, "\t");
    return encoding === "compressed-json" ? compress(json) : json;
  }

  /** Every text element's text and id, for `## Text Elements`. */
  function texts(elements) {
    return elements
      .filter((e) => e.type === "text" && !e.isDeleted)
      .map((e) => ({ id: e.id, text: e.originalText ?? e.text ?? "" }));
  }

  return { compress, decompress, read, write, texts };
})();
