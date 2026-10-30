const fs=require('fs'), path=require('path');
const sharp=require('/Users/thomasb/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
const folder=process.argv[2] || fs.readFileSync(path.join(__dirname,'latest-run.txt'),'utf8').trim();
(async()=>{for(const metric of ['common','native','observed']) await sharp(path.join(folder,metric+'-energy.svg'),{density:144}).flatten({background:'#fff'}).png().toFile(path.join(folder,metric+'-energy.png'));})();
