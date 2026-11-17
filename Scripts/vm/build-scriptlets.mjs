// Writes Scripts/vm/notifications-agent/assets/scriptlets.json from uBlock Origin's source: each
// scriptlet's function, its JavaScript name, what it needs and its other names, for the ad
// blocker to run uBlock's "+js(...)" rules on pages as uBlock does. Run with node:
//   git clone --depth 1 https://github.com/gorhill/uBlock.git <dir>
//   node Scripts/vm/build-scriptlets.mjs <dir>
// uBlock Origin is GPL-3.0; the file it writes is that code, unchanged.
import { writeFileSync } from 'node:fs';
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
