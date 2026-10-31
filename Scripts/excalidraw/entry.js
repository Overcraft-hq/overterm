// What the drawing page (Resources/notes/draw.js) gets from the bundle:
// Excalidraw and the React it runs on, and lz-string for the plugin's
// compressed-json.
import React from "react";
import { createRoot } from "react-dom/client";
import * as Excalidraw from "@excalidraw/excalidraw";
import LZString from "lz-string";

window.Draw = { React, createRoot, Excalidraw, LZString };
