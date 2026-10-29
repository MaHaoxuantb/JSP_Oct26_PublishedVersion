const fs = require('fs');
const path = require('path');
const sharp = require('/Users/thomasb/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
const folder = process.argv[2] || fs.readFileSync(path.join(__dirname,'latest-run.txt'),'utf8').trim();
(async () => {
  for (const name of ['exact-energy','native-energy','current-energy']) {
    await sharp(path.join(folder,name+'.svg'),{density:144})
      .flatten({background:'#ffffff'}).png().toFile(path.join(folder,name+'.png'));
  }
})();
