// Writes Scripts/vm/notifications-agent/assets/scriptlets.json from uBlock Origin's source: each
// scriptlet's function, its JavaScript name, what it needs and its other names, for the ad
// blocker to run uBlock's "+js(...)" rules on pages as uBlock does. Also copies uBlock's stand-in
// resources (web_accessible_resources), which "$redirect=" rules answer blocked ad scripts with,
// so a page that calls them goes on as if they had loaded, into assets/redirects, listed in
// assets/redirects.json by every name rules give them. Run with node:
//   git clone --depth 1 https://github.com/gorhill/uBlock.git <dir>
//   node Scripts/vm/build-scriptlets.mjs <dir>
// uBlock Origin is GPL-3.0; the file it writes is that code, unchanged.
import { copyFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const source = resolve(process.argv[2]);
const { builtinScriptlets } = await import(pathToFileURL(`${source}/src/js/resources/scriptlets.js`).href);
const out = {};
for (const entry of builtinScriptlets) {
    out[entry.name] = {
        fn: entry.fn.name,
        code: entry.fn.toString(),
        dependencies: entry.dependencies ?? [],
        aliases: entry.aliases ?? [],
        world: entry.world ?? 'MAIN',
        requiresTrust: entry.requiresTrust === true,
    };
}
const target = new URL('notifications-agent/assets/scriptlets.json', import.meta.url);
writeFileSync(target, JSON.stringify(out));
console.log(`${Object.keys(out).length} scriptlets`);

const { default: resources } = await import(pathToFileURL(`${source}/src/js/redirect-resources.js`).href);
const folder = new URL('notifications-agent/assets/redirects/', import.meta.url);
mkdirSync(folder, { recursive: true });
const names = {};
for (const [file, details] of resources) {
    if (file.endsWith('.html')) { continue; }
    copyFileSync(`${source}/src/web_accessible_resources/${file}`, new URL(file, folder));
    names[file] = file;
    const aliases = Array.isArray(details.alias) ? details.alias : (details.alias ? [details.alias] : []);
    for (const alias of aliases) { names[alias] = file; }
}
writeFileSync(new URL('notifications-agent/assets/redirects.json', import.meta.url), JSON.stringify(names));
console.log(`${new Set(Object.values(names)).size} stand-in resources`);
