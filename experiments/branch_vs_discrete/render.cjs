const fs=require('fs'),path=require('path');
const sharp=require('sharp');
const folder=process.argv[2];
(async()=>{await sharp(path.join(folder,'comparison-energy.svg'),{density:144}).flatten({background:'#fff'}).png().toFile(path.join(folder,'comparison-energy.png'));})();
