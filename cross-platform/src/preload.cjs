'use strict';
const {contextBridge,ipcRenderer}=require('electron');
contextBridge.exposeInMainWorld('sleepdock',Object.freeze({
  invoke:(action,value)=>ipcRenderer.invoke('sleepdock:action',action,value),
  onState:callback=>{const listener=(_event,state)=>callback(state);ipcRenderer.on('sleepdock:state',listener);return()=>ipcRenderer.removeListener('sleepdock:state',listener);}
}));
