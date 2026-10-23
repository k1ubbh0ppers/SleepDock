'use strict';
const {app,BrowserWindow,ipcMain,powerMonitor,powerSaveBlocker,Tray,Menu,nativeImage,dialog,shell,screen}=require('electron');
const fs=require('node:fs');const path=require('node:path');const crypto=require('node:crypto');
const {Controller}=require('./controller.cjs');const {PlatformPower}=require('./platform.cjs');
const {AgentMonitor}=require('./agents.cjs');const {WIDTH,MIN_HEIGHT,normalize}=require('./policy.cjs');
let win,tray,controller,settingsFile,quitting=false,saveTimer,resizeTimer,pollTimer;
const smoke=app.commandLine.hasSwitch('ui-smoke');
if(smoke)app.setPath('userData',path.resolve(app.commandLine.getSwitchValue('smoke-out')||app.getPath('temp'),'SleepDock-ui-smoke'));
if(!app.requestSingleInstanceLock())app.quit();
else {
app.on('second-instance',()=>{win?.show();win?.focus();});
app.whenReady().then(start).catch(async error=>{console.error(error);if(smoke)app.exit(1);else {await dialog.showMessageBox({type:'error',message:'SleepDock 无法启动',detail:error.message});app.quit();}});
}
function load(){try{return normalize(JSON.parse(fs.readFileSync(settingsFile,'utf8')));}catch{return normalize();}}
function persist(){
  if(smoke)return;clearTimeout(saveTimer);saveTimer=setTimeout(()=>{
    try{const temporary=settingsFile+'.tmp';fs.writeFileSync(temporary,JSON.stringify(controller.settings,null,2),{mode:0o600});fs.renameSync(temporary,settingsFile);}
    catch(error){controller.lastError=`设置保存失败：${error.message}`;}
  },200);
}
function boundsHeight(h){return Math.max(Math.min(MIN_HEIGHT,screen.getPrimaryDisplay().workArea.height),Math.min(h,screen.getDisplayMatching(win?.getBounds()||{x:0,y:0,width:WIDTH,height:h}).workArea.height));}
function shape(){
  if(!win||win.isDestroyed()||process.platform==='darwin')return;
  // A real window region also removes corner pixels on compositors that ignore alpha.
  const height=win.getContentSize()[1],r=24,rects=[{x:0,y:r,width:WIDTH,height:Math.max(1,height-2*r)}];
  for(let y=0;y<r;y++){const inset=Math.ceil(r-Math.sqrt(r*r-(r-y-0.5)**2));rects.push({x:inset,y,width:WIDTH-2*inset,height:1},{x:inset,y:height-y-1,width:WIDTH-2*inset,height:1});}
  try{win.setShape(rects);}catch{/* Transparent backing still works on compositors without region support. */}
}
function layout(){
  const s=controller.settings;win.setAlwaysOnTop(s.floatOnTop);const height=boundsHeight(s[s.compact?'compactHeight':'normalHeight']);
  win.setSize(WIDTH,height);shape();
}
function publish(state){if(quitting||!win||win.isDestroyed())return;
  win.webContents.send('sleepdock:state',{...state,settings:controller.settings,platform:process.platform});
  if(tray&&!tray.isDestroyed()){tray.setToolTip(`SleepDock · ${state.reason||'已停用'}`);tray.setContextMenu(Menu.buildFromTemplate([
    {label:'显示插件',click:()=>{win.show();win.focus();}},{label:'启用插件',type:'checkbox',checked:controller.settings.masterEnabled,click:()=>{controller.update({masterEnabled:!controller.settings.masterEnabled});controller.tick();}},
    {type:'separator'},{label:'退出并释放保护',click:()=>app.quit()}]));}
}
async function start(){
  settingsFile=path.join(app.getPath('userData'),'settings.json');
  const settings=load();if(smoke)settings.masterEnabled=false;
  const power=new PlatformPower({resourcesDir:path.join(__dirname,'..','resources'),stateDir:path.join(app.getPath('userData'),'power'),electronPowerMonitor:powerMonitor});
  let recoveryError='';try{await power.setLidMode('system');}catch(error){recoveryError=`上次合盖设置恢复失败：${error.message}`;}
  controller=new Controller({power,monitor:new AgentMonitor(),blocker:powerSaveBlocker,settings});
  if(recoveryError){controller.lastError=recoveryError;controller.log(recoveryError);}
  power.on('failure',error=>{controller.lastError=error.message;controller.cancel('合盖守护异常');controller.lidMode='system';controller.log(error.message);});
  controller.on('settings',()=>{persist();publish(controller.state);});controller.on('state',publish);
  win=new BrowserWindow({width:WIDTH,height:boundsHeight(settings[settings.compact?'compactHeight':'normalHeight']),minWidth:WIDTH,maxWidth:WIDTH,minHeight:MIN_HEIGHT,
    frame:false,transparent:true,backgroundColor:'#00000000',hasShadow:false,thickFrame:false,resizable:true,maximizable:false,fullscreenable:false,
    title:'SleepDock',alwaysOnTop:settings.floatOnTop,show:false,autoHideMenuBar:true,
    webPreferences:{preload:path.join(__dirname,'preload.cjs'),contextIsolation:true,nodeIntegration:false,sandbox:true}});
  win.setMenu(null);
  if(process.platform==='win32'){try{win.setBackgroundMaterial('acrylic');}catch{}}
  win.webContents.setWindowOpenHandler(()=>({action:'deny'}));
  win.webContents.on('will-navigate',event=>event.preventDefault());
  win.on('will-resize',(event,bounds)=>{if(bounds.width!==WIDTH){event.preventDefault();win.setSize(WIDTH,boundsHeight(bounds.height));}});
  win.on('resize',()=>{clearTimeout(resizeTimer);resizeTimer=setTimeout(()=>{
    if(win.isDestroyed())return;const height=win.getSize()[1];if(win.getSize()[0]!==WIDTH)win.setSize(WIDTH,height);
    controller.settings[controller.settings.compact?'compactHeight':'normalHeight']=height;persist();shape();
  },80);});
  win.on('close',event=>{if(!quitting){event.preventDefault();app.quit();}});
  ipcMain.handle('sleepdock:action',async(event,action,value)=>{
    if(event.sender!==win.webContents||event.senderFrame!==win.webContents.mainFrame)return {ok:false,error:'无效窗口'};
    try {return {ok:true,result:await actionHandler(action,value)};}catch(error){controller.lastError=error.message;controller.log(error.message);publish({...controller.state,lastError:error.message});return {ok:false,error:error.message};}
  });
  await win.loadFile(path.join(__dirname,'..','renderer','index.html'));
  const trayData=fs.readFileSync(path.join(__dirname,'..','resources','tray.png'));tray=new Tray(nativeImage.createFromBuffer(trayData));
  win.show();shape();await controller.tick();publish(controller.state);
  pollTimer=setInterval(()=>controller.tick(),1000);pollTimer.unref();
  powerMonitor.on('resume',()=>controller.wake());
  if(smoke)await smokeCheck();
}
async function actionHandler(action,value){
  switch(action){
  case 'get':await controller.tick();publish(controller.state);return {...controller.state,platform:process.platform};
  case 'update':{
    const allowed=['masterEnabled','mode','minutes','agentProtection','sleepAfterAgents','keepDisplayAwake','acOnly','lowBatteryCutoff','floatOnTop','compact','opacity','selectedAgents'];
    const patch={};for(const key of allowed)if(value&&Object.hasOwn(value,key))patch[key]=value[key];
    controller.update(patch);layout();await controller.tick();return;
  }
  case 'startTimer':controller.startTimer();await controller.tick();return;
  case 'cancel':controller.cancel();await controller.tick();return;
  case 'sleep':controller.manualSleep();await controller.tick();return;
  case 'dismissError':controller.lastError='';publish({...controller.state,lastError:''});return;
  case 'displayOff':if(!controller.power.capabilities().displayOff)throw Error('当前桌面未提供熄屏接口');await controller.power.displayOff();return;
  case 'lock':if(!controller.power.capabilities().lock)throw Error('当前桌面未提供锁屏接口');await controller.power.lock();return;
  case 'lid':{
    if(!['system','keep','sleep'].includes(value))throw Error('无效合盖规则');
    const caps=controller.power.capabilities();if(value!=='system'&&!caps[value==='keep'?'lidKeepAwake':'lidSleep'])throw Error('当前系统不支持这项合盖控制');
    if(value!=='system'){
      if(!controller.settings.masterEnabled)throw Error('请先启用插件');
      if(value==='keep'&&controller.state.power.pluggedIn!==true)throw Error('请先连接电源');
      const detail=process.platform==='win32'?'会临时修改当前电源方案的合盖动作；停用或退出时恢复原值。需要系统允许修改电源设置。':
        '使用登录管理器的临时合盖规则，桌面环境可能覆盖此规则。';
      const answer=await dialog.showMessageBox(win,{type:'warning',title:'设置合盖行为',message:value==='keep'?'合盖后保持运行？':'合盖后休眠？',detail:detail+(value==='keep'?' 请保持散热，不要把运行中的笔记本放入包中。':''),buttons:['取消','应用'],defaultId:0,cancelId:0});
      if(answer.response!==1)return;
    }
    await controller.changeLid(value);await controller.tick();return;
  }
  case 'resizeStart':win._heightDrag={height:win.getSize()[1]};return;
  case 'resizeBy':if(win._heightDrag&&Number.isFinite(value))win.setSize(WIDTH,boundsHeight(win._heightDrag.height+Math.max(-2000,Math.min(2000,value))));return;
  case 'resizeEnd':win._heightDrag=null;return;
  case 'hide':win.hide();return;
  case 'quit':app.quit();return;
  case 'help':await shell.openPath(path.join(__dirname,'..','使用说明.md'));return;
  case 'addApp':{
    const selected=await dialog.showOpenDialog(win,{title:'选择已安装的 Agent 程序',properties:['openFile'],filters:process.platform==='win32'?[{name:'程序',extensions:['exe','cmd','bat']}]:[]});
    if(selected.canceled)return;const file=selected.filePaths[0];
    const id='custom-'+crypto.createHash('sha256').update(file).digest('hex').slice(0,16);
    const customApps=[...controller.settings.customApps.filter(a=>a.id!==id),{id,path:file,name:path.basename(file,path.extname(file))}];
    controller.update({customApps,selectedAgents:[...controller.settings.selectedAgents,id]});await controller.tick();return;
  }
  case 'removeApp':controller.update({customApps:controller.settings.customApps.filter(a=>a.id!==value),selectedAgents:controller.settings.selectedAgents.filter(id=>id!==value)});await controller.tick();return;
  case 'integration':{
    const file=path.join(__dirname,'..','resources','sleepdock-run.py');
    const command=process.platform==='win32'?`py -3 "${file}" --agent claude -- claude -p "任务内容"`:`python3 '${file.replaceAll("'","'\\''")}' --agent claude -- claude -p '任务内容'`;
    require('electron').clipboard.writeText(command);return '已复制通用接入示例；需要 Python 3。';
  }
  default:throw Error('不支持的操作');
  }
}
app.on('before-quit',event=>{
  if(quitting)return;event.preventDefault();quitting=true;clearTimeout(saveTimer);clearTimeout(resizeTimer);clearInterval(pollTimer);
  if(!controller){app.exit();return;}
  try{if(!smoke)fs.writeFileSync(settingsFile,JSON.stringify(controller.settings,null,2),{mode:0o600});}catch{}
  controller.shutdown().then(()=>{tray?.destroy();app.exit();}).catch(error=>{console.error(error);dialog.showMessageBoxSync({type:'error',message:'退出前恢复电源设置失败',detail:error.message});app.exit(1);});
});
app.on('window-all-closed',()=>{if(!quitting)app.quit();});
async function smokeCheck(){
  const out=path.resolve(app.commandLine.getSwitchValue('smoke-out')||app.getPath('temp'));fs.mkdirSync(out,{recursive:true});
  await new Promise(r=>setTimeout(r,500));
  const checks=await win.webContents.executeJavaScript(`({transparentBody:getComputedStyle(document.body).backgroundColor,transparentHTML:getComputedStyle(document.documentElement).backgroundColor,selected:document.querySelectorAll('[data-agent]:checked').length,content:document.querySelector('.shell').getBoundingClientRect().width,outerBorder:getComputedStyle(document.querySelector('.shell')).borderTopWidth,outerShadow:getComputedStyle(document.querySelector('.shell')).boxShadow,ready:!!window.sleepdock})`);
  win.setSize(WIDTH,520);await new Promise(r=>setTimeout(r,150));
  checks.height=win.getSize()[1];checks.min=win.getMinimumSize();checks.max=win.getMaximumSize();checks.masterEnabled=controller.settings.masterEnabled;
  const picture=await win.webContents.capturePage();fs.writeFileSync(path.join(out,'cross-ui.png'),picture.toPNG());
  // Check the complete area beyond each rounded corner, leaving one pixel for antialiasing.
  const bitmap=picture.toBitmap({scaleFactor:1}),size=picture.getSize();
  let outsidePixels=0,nontransparentOutsidePixels=0;
  for(let y=0;y<24;y++)for(let x=0;x<24;x++){
    if(Math.hypot(24-x-0.5,24-y-0.5)<=25)continue;
    for(const [px,py] of [[x,y],[size.width-x-1,y],[x,size.height-y-1],[size.width-x-1,size.height-y-1]]){
      outsidePixels++;if(bitmap[(py*size.width+px)*4+3]!==0)nontransparentOutsidePixels++;
    }
  }
  checks.nativeShadow=win.hasShadow();checks.outsidePixels=outsidePixels;checks.nontransparentOutsidePixels=nontransparentOutsidePixels;
  fs.writeFileSync(path.join(out,'cross-ui-smoke.json'),JSON.stringify(checks,null,2));
  console.log(JSON.stringify(checks));
  const okay=checks.outsidePixels>0&&checks.nontransparentOutsidePixels===0&&!checks.nativeShadow&&checks.outerBorder==='0px'&&checks.outerShadow==='none'&&checks.ready&&checks.selected===6&&checks.content===WIDTH&&checks.height===520&&checks.min[0]===WIDTH&&checks.max[0]===WIDTH&&!checks.masterEnabled&&checks.transparentBody==='rgba(0, 0, 0, 0)'&&checks.transparentHTML==='rgba(0, 0, 0, 0)';
  if(!okay){console.error('UI_SMOKE_FAILED');await controller.shutdown();app.exit(1);}else {console.log('UI_SMOKE_PASS');app.quit();}
}
