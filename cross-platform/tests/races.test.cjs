'use strict';
const {test}=require('node:test');const assert=require('node:assert/strict');const {Controller}=require('../src/controller.cjs');
function deferred(){let resolve;const promise=new Promise(r=>resolve=r);return{promise,resolve};}
const empty={tasks:[],completedTaskIDs:[],uncertainSources:[],interruptedSources:[],apps:[]};
function setup(){const active=new Set();const calls=[];const power={capabilities:()=>({}),status:async()=>({battery:80,pluggedIn:true,idleSeconds:100}),setLidMode:async mode=>{calls.push(mode);return{ok:true};},shutdown:async()=>{}};
  const c=new Controller({power,monitor:{poll:async()=>empty},settings:{masterEnabled:true,mode:'never'},blocker:{start:()=>{const id=Symbol();active.add(id);return id;},stop:id=>active.delete(id),isStarted:id=>active.has(id)}});
  return{c,power,active,calls};}
test('关闭总开关立即撤销正在等待的合盖启用，过期结果不能重新启用',async()=>{
  const f=setup(),pending=deferred();await f.c.tick();f.power.setLidMode=async mode=>{f.calls.push(mode);return mode==='keep'?pending.promise:{ok:true};};
  const request=f.c.changeLid('keep');f.c.update({masterEnabled:false});pending.resolve({ok:true});
  await assert.rejects(request,/取消/);await Promise.resolve();assert.equal(f.c.lidMode,'system');assert.equal(f.active.size,0);assert.deepEqual(f.calls,['keep','system']);
});
test('退出发生在合盖恢复等待期间，异步旧tick不能重建断言',async()=>{
  const f=setup(),pending=deferred(),started=deferred();await f.c.tick();f.c.lidMode='keep';
  f.power.status=async()=>({battery:80,pluggedIn:false,idleSeconds:100});f.power.setLidMode=async()=>{started.resolve();return pending.promise;};
  const tick=f.c.tick();await started.promise;await f.c.shutdown();pending.resolve({ok:true});await tick;
  assert.equal(f.c.closed,true);assert.equal(f.active.size,0);
});
test('同时读取状态等待同一轮扫描，不能返回尚未初始化的界面',async()=>{
  const f=setup(),pending=deferred();let reads=0;
  f.power.status=async()=>{reads++;await pending.promise;return {battery:80,pluggedIn:true,idleSeconds:100};};
  const a=f.c.tick(),b=f.c.tick();assert.equal(a,b);pending.resolve();await Promise.all([a,b]);assert.equal(reads,1);assert.equal(f.c.state.reason,'保持清醒');
});
