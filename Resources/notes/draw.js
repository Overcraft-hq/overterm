// A drawing in the editor: Excalidraw over the file's scene. Every change
// goes back to the app (`change`), which writes it into the file's text —
// so it is saved like any edit. The app drives it through `OT`.
"use strict";
(() => {
  const { React, createRoot, Excalidraw: X } = window.Draw;
  const post = (message) => window.webkit.messageHandlers.draw.postMessage(message);
  const root = createRoot(document.getElementById("canvas"));

  let api = null;
  let encoding = "json";
  let seen = null;
  let timer = null;
  let generation = 0;

  /** What a change is measured by: the elements' versions and the background. */
  function stamp(elements, appState) {
    return X.hashElementsVersion(elements) + ":" + appState.viewBackgroundColor;
  }

  function send() {
    timer = null;
    if (!api) return;
    const elements = api.getSceneElements();
    post({
      change: {
        scene: DrawingFile.write(elements, api.getAppState(), api.getFiles(), encoding),
        encoding,
        texts: DrawingFile.texts(elements),
      },
    });
  }

  function onChange(elements, appState) {
    const now = stamp(elements, appState);
    // The first call is the scene as loaded: nothing to write.
    if (seen === null || seen === now) {
      seen = now;
      return;
    }
    seen = now;
    clearTimeout(timer);
    timer = setTimeout(send, 300);
  }

  const OT = {
    /** Shows a scene: `scene` as `encoding` has it, written back as `saveAs`. */
    load({ scene, encoding: given, saveAs, dark }) {
      let data;
      try {
        data = DrawingFile.read(scene, given);
      } catch (error) {
        post({ error: String(error.message || error) });
        return;
      }
      encoding = saveAs;
      seen = null;
      api = null;
      clearTimeout(timer);
      generation += 1;
      const restored = X.restore(data, null, null);
      root.render(
        React.createElement(X.Excalidraw, {
          key: generation,
          initialData: { elements: restored.elements, appState: restored.appState, files: restored.files, scrollToContent: true },
          excalidrawAPI: (a) => (api = a),
          onChange,
          theme: dark ? "dark" : "light",
          UIOptions: { canvasActions: { loadScene: false, saveToActiveFile: false, toggleTheme: null } },
          onLinkOpen: (element, event) => {
            event.preventDefault();
            post({ link: element.link });
          },
        }),
      );
    },

    theme(dark) {
      api?.updateScene({ appState: { theme: dark ? "dark" : "light" } });
    },

    /** Writes now what is waiting (before a save, a close). */
    flush() {
      if (timer) {
        clearTimeout(timer);
        send();
      }
    },

    /** Adds elements given as Excalidraw's skeletons — an agent's, a check's. */
    add(skeletons) {
      if (!api) return 0;
      const added = X.convertToExcalidrawElements(skeletons, { regenerateIds: true });
      api.updateScene({ elements: [...api.getSceneElementsIncludingDeleted(), ...added] });
      api.scrollToContent(added, { fitToContent: false });
      return added.length;
    },

    /** What is on the canvas, for checks. */
    state() {
      const elements = api ? api.getSceneElements() : [];
      return { ready: !!api, count: elements.length, types: elements.map((e) => e.type), texts: DrawingFile.texts(elements) };
    },

    /** A scene made from skeletons, without a canvas — what an agent's drawing is written as. */
    convert(skeletons, saveAs) {
      const elements = X.convertToExcalidrawElements(skeletons, { regenerateIds: true });
      const appState = { viewBackgroundColor: "#ffffff", gridSize: null };
      return { scene: DrawingFile.write(elements, appState, {}, saveAs), texts: DrawingFile.texts(elements), count: elements.length };
    },
  };

  window.OT = OT;
  post({ ready: true });
})();
