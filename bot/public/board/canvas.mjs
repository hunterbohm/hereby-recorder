// The editable .excalidraw file kept in the notes for every board (scene.mjs lays it out). React and Excalidraw load
// only when a board is exported, from jsDelivr, pinned with SRI like the page's other scripts; the page itself draws
// with blocks.mjs and never needs them.
import { files, scene } from './scene.mjs';

const SCRIPTS = [
  ['https://cdn.jsdelivr.net/npm/react@18.3.1/umd/react.production.min.js',
    'sha384-DGyLxAyjq0f9SPpVevD6IgztCFlnMF6oW/XQGmfe+IsZ8TqEiDrcHkMLKI6fiB/Z'],
  ['https://cdn.jsdelivr.net/npm/react-dom@18.3.1/umd/react-dom.production.min.js',
    'sha384-gTGxhz21lVGYNMcdJOyq01Edg0jhn/c22nsx0kyqP0TxaV5WVdsSH1fSDUf5YJj1'],
  ['https://cdn.jsdelivr.net/npm/@excalidraw/excalidraw@0.17.6/dist/excalidraw.production.min.js',
    'sha384-2RnaDBiRrWXqT5k4HtP4X4gh/ukRFg9zn1Sjt+JeYQOUWSYYnN1tKE4FL9QA3Wdl'],
];
const BACKGROUND = '#ffffff';

let library = null;
// Excalidraw's library, loaded once, in order (each needs the one before).
export function load() {
  library ??= (async () => {
    for (const [src, integrity] of SCRIPTS) {
      await new Promise((resolve, reject) => {
        const script = Object.assign(document.createElement('script'), { src, integrity, crossOrigin: 'anonymous' });
        script.onload = resolve;
        script.onerror = () => reject(new Error(`could not load ${src.split('/npm/')[1]}`));
        document.head.append(script);
      });
    }
    return window.ExcalidrawLib;
  })();
  library.catch(() => { library = null; });
  return library;
}

// A board as an editable .excalidraw file.
export async function exportBoard(board) {
  const lib = await load();
  const elements = lib.convertToExcalidrawElements(scene(board), { regenerateIds: false });
  const appState = { viewBackgroundColor: BACKGROUND, exportBackground: true, exportWithDarkMode: false };
  return { scene: lib.serializeAsJSON(elements, appState, files(board), 'local') };
}
