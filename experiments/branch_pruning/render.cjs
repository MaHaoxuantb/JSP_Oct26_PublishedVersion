const fs=require('fs'),path=require('path');
const sharp=require('sharp');
const folder=process.argv[2]||path.resolve(__dirname, fs.readFileSync(path.join(__dirname,'latest-run.txt'),'utf8').trim());
(async()=>{await sharp(path.join(folder,'branch-energy.svg'),{density:144}).flatten({background:'#fff'}).png().toFile(path.join(folder,'branch-energy.png'));})();
