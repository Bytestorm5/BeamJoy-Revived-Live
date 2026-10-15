// Serves the BeamJoy Live window outside the game: the mod's ui/ folder at /ui/ (as the game
// does), AngularJS, and harness.html with a fake bngApi standing in for the game's Lua.
//
//   cd tools/ui-harness && npm install && npm start
//   open http://localhost:4100/?site=http://localhost:3000
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const clientDir = path.resolve(here, "../../Client");
const port = Number(process.env.PORT) || 4100;
const types = { ".js": "text/javascript", ".mjs": "text/javascript", ".html": "text/html", ".json": "application/json", ".png": "image/png", ".jpg": "image/jpeg" };

createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  let file;
  if (url.pathname === "/") file = path.join(here, "harness.html");
  else if (url.pathname.startsWith("/ui/")) file = path.join(clientDir, url.pathname);
  else if (url.pathname === "/angular.js") file = path.join(here, "node_modules/angular/angular.js");
  else if (url.pathname.startsWith("/fixtures/")) file = path.join(here, url.pathname);
  if (!file || !file.startsWith(here) && !file.startsWith(clientDir)) {
    res.writeHead(404).end();
    return;
  }
  try {
    const body = await readFile(file);
    res.writeHead(200, { "Content-Type": types[path.extname(file)] ?? "application/octet-stream" }).end(body);
  } catch {
    res.writeHead(404).end();
  }
}).listen(port, () => console.log(`UI harness on http://localhost:${port}/?site=<BeamJoy Web URL>`));
