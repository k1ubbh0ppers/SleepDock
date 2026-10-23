'use strict';
const path=require('node:path');const fs=require('node:fs');const crypto=require('node:crypto');const {pathToFileURL}=require('node:url');
(async()=>{
  const {packager}=await import(pathToFileURL(require.resolve('@electron/packager')).href);
  const root=path.resolve(__dirname,'..');
  const metadata=require(path.join(root,'package.json'));
  const requested=process.argv.slice(2);
  if(requested.some(argument=>!/^--platform=(win32|linux)$/.test(argument)))throw new Error('Usage: npm run package -- [--platform=win32|--platform=linux]');
  const platforms=requested.length?[...new Set(requested.map(argument=>argument.split('=')[1]))]:['win32','linux'];
  const checksums=require(path.join(path.dirname(require.resolve('electron')),'checksums.json'));
  const out=path.resolve(process.env.SLEEPDOCK_PACKAGE_OUT||path.join(root,'dist'));
  const electronZipDir=process.env.SLEEPDOCK_ELECTRON_ZIP_DIR?path.resolve(process.env.SLEEPDOCK_ELECTRON_ZIP_DIR):undefined;
  for(const platform of platforms){
    if(electronZipDir){
      const filename=`electron-v${metadata.devDependencies.electron}-${platform}-x64.zip`;
      const expected=checksums[filename];
      const actual=crypto.createHash('sha256').update(fs.readFileSync(path.join(electronZipDir,filename))).digest('hex');
      if(!expected||actual!==expected)throw new Error(`Electron runtime checksum mismatch: ${filename}`);
    }
    const paths=await packager({dir:root,out,platform,arch:'x64',name:'SleepDock',electronVersion:metadata.devDependencies.electron,
      overwrite:true,asar:false,prune:true,icon:path.join(root,'resources',platform==='win32'?'icon.ico':'tray.png'),
      download:{checksums},electronZipDir,
      ignore:[/^\/dist(?:\/|$)/,/^\/node_modules(?:\/|$)/,/^\/tests(?:\/|$)/,/^\/scripts(?:\/|$)/,/\.DS_Store$/],
      win32metadata:{CompanyName:'SleepDock',FileDescription:'SleepDock desktop sleep control',ProductName:'SleepDock',OriginalFilename:'SleepDock.exe'},
      appVersion:metadata.version,buildVersion:metadata.version});
    for(const directory of paths)for(const document of ['使用说明.md','验证记录.md'])
      fs.copyFileSync(path.join(root,document),path.join(directory,document));
    for(const directory of paths){
      // Electron's own LICENSE must stay intact at the package root.
      fs.copyFileSync(path.join(root,'..','LICENSE'),path.join(directory,'LICENSE-SleepDock.txt'));
      fs.copyFileSync(path.join(root,'..','LICENSE'),path.join(directory,'resources','app','LICENSE'));
      fs.copyFileSync(path.join(root,'..','THIRD_PARTY_NOTICES.md'),path.join(directory,'THIRD_PARTY_NOTICES.md'));
    }
    if(platform==='linux'){
      const launcher=path.join(paths[0],'启动SleepDock.sh');
      fs.writeFileSync(launcher,'#!/bin/sh\nset -eu\nAPP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\nexec "$APP_DIR/SleepDock" "$@"\n');fs.chmodSync(launcher,0o755);
    }
    console.log(`PACKAGE_READY ${platform} ${paths.join(', ')}`);
  }
})().catch(error=>{console.error(error);process.exit(1);});
