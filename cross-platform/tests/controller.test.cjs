'use strict';
const {test}=require('node:test');const assert=require('node:assert/strict');const {Controller}=require('../src/controller.cjs');
const snapshot=(ids=[],completed=[],uncertain=[],interrupted=[])=>({tasks:ids.map(id=>({id,source:'codex'})),completedTaskIDs:completed,uncertainSources:uncertain,interruptedSources:interrupted,apps:[]});
function fixture(settings={}){
  let now=100000,reads=0,sleeps=0,lid='system';let current=snapshot();let status={battery:90,pluggedIn:true,idleSeconds:100};const active=new Set();const history=[];
  const power={capabilities:()=>({sleep:true}),status:async()=>({...status}),sleep:async()=>{sleeps++;history.push(['sleep',active.size]);},setLidMode:async mode=>{lid=mode;history.push(['lid',active.size]);return{ok:true};},shutdown:async()=>{}};
  const blocker={start:type=>{const id=Math.random();active.add(id);history.push(['start',type]);return id;},stop:id=>{active.delete(id);history.push(['stop',id]);},isStarted:id=>active.has(id)};
  const monitor={poll:async()=>{reads++;return structuredClone(current);}};
  const controller=new Controller({power,blocker,monitor,settings:{masterEnabled:true,...settings},now:()=>now});
  return {c:controller,power,monitor,history,active,setSnapshot:s=>current=s,setStatus:s=>status={...status,...s},advance:ms=>now+=ms,sleeps:()=>sleeps,reads:()=>reads,lid:()=>lid};
}
test('关闭总开关立即释放保护',async()=>{const f=fixture({mode:'never'});await f.c.tick();assert.equal(f.active.size,1);f.c.update({masterEnabled:false});assert.equal(f.active.size,0);await f.c.tick();assert.equal(f.sleeps(),0);});
test('正常任务完成倒计时60秒才请求，最终复核保留保活',async()=>{const f=fixture({sleepAfterAgents:true});f.setSnapshot(snapshot(['a']));await f.c.tick();f.setSnapshot(snapshot([],['a']));await f.c.tick();assert.equal(f.c.countdown.kind,'agents');f.advance(60000);await f.c.tick();assert.equal(f.sleeps(),1);assert.equal(f.reads(),4);assert.deepEqual(f.history.at(-1),['sleep',0]);});
test('倒计时期间新任务取消休眠',async()=>{const f=fixture();f.c.manualSleep();f.setSnapshot(snapshot(['a']));f.advance(15000);await f.c.tick();assert.equal(f.sleeps(),0);assert.equal(f.c.countdown,null);});
test('最后一次检查出现任务则不释放保护',async()=>{const f=fixture();f.c.manualSleep();f.advance(15000);let reads=0;f.monitor.poll=async()=>++reads===1?snapshot():snapshot(['new']);await f.c.tick();assert.equal(f.sleeps(),0);assert.equal(f.active.size,1);});
test('合盖恢复等待期间仍保留保护，恢复后复核任务',async()=>{const f=fixture();f.c.lidMode='keep';f.c.manualSleep();f.advance(15000);let read=0;f.monitor.poll=async()=>++read<3?snapshot():snapshot(['new']);await f.c.tick();assert.equal(f.sleeps(),0);assert.deepEqual(f.history.find(x=>x[0]==='lid'),['lid',1]);assert.equal(f.active.size,1);});
test('最终读取期间关闭总开关使旧休眠请求失效',async()=>{const f=fixture();f.c.manualSleep();f.advance(15000);let read=0;f.monitor.poll=async()=>{if(++read===2)f.c.update({masterEnabled:false});return snapshot();};await f.c.tick();assert.equal(f.sleeps(),0);assert.equal(f.active.size,0);});
test('低电量取消待执行休眠并释放保护',async()=>{const f=fixture({mode:'never'});f.c.manualSleep();f.setStatus({battery:5,pluggedIn:false});f.advance(15000);await f.c.tick();assert.equal(f.sleeps(),0);assert.equal(f.active.size,0);});
test('任务中断不触发完成后休眠',async()=>{const f=fixture({sleepAfterAgents:true});f.setSnapshot(snapshot(['a']));await f.c.tick();f.setSnapshot(snapshot(['a'],[],[],['claude']));await f.c.tick();f.setSnapshot(snapshot([],['a']));await f.c.tick();assert.equal(f.c.countdown,null);});
test('键鼠活动即使空闲已超过3秒也取消完成倒计时',async()=>{const f=fixture({sleepAfterAgents:true});f.setSnapshot(snapshot(['a']));await f.c.tick();f.setSnapshot(snapshot([],['a']));await f.c.tick();f.advance(30000);f.setStatus({idleSeconds:12});await f.c.tick();assert.equal(f.c.countdown,null);assert.equal(f.sleeps(),0);});
test('定时休眠在任务结束后再计60秒',async()=>{const f=fixture({mode:'timer',minutes:1});f.c.startTimer();f.setSnapshot(snapshot(['a']));f.advance(60000);await f.c.tick();assert.equal(f.c.countdown,null);f.setSnapshot(snapshot([],['a']));await f.c.tick();assert.equal(f.c.countdown.kind,'timer');});
test('睡眠请求失败恢复保活且显示错误',async()=>{const f=fixture();f.power.sleep=async()=>{throw Error('denied');};f.c.manualSleep();f.advance(15000);await f.c.tick();assert.equal(f.active.size,1);assert.equal(f.c.state.lastError,'denied');});
test('任务读取失败不会休眠，并保留保护',async()=>{const f=fixture();f.monitor.poll=async()=>{throw Error('unreadable');};f.c.manualSleep();f.advance(15000);await f.c.tick();assert.equal(f.sleeps(),0);assert.equal(f.active.size,1);});
test('唤醒取消旧定时',async()=>{const f=fixture();f.c.manualSleep();f.c.wake();assert.equal(f.c.countdown,null);});
test('退出释放断言、使请求失效且停止轮询',async()=>{const f=fixture({mode:'never'});await f.c.tick();await f.c.shutdown();await f.c.tick();assert.equal(f.active.size,0);assert.equal(f.reads(),1);});
test('明确关闭Agent保护后未知任务不阻止手动休眠',async()=>{const f=fixture({agentProtection:false});f.setSnapshot(snapshot(['a'],[],['*'],['codex']));f.c.manualSleep();f.advance(15000);await f.c.tick();assert.equal(f.sleeps(),1);});
test('退出期间系统拒绝休眠，过期错误不能重建断言',async()=>{const f=fixture();let rejectSleep,entered;const started=new Promise(r=>entered=r);f.power.sleep=()=>{entered();return new Promise((_,reject)=>rejectSleep=reject);};f.c.manualSleep();f.advance(15000);const tick=f.c.tick();await started;await f.c.shutdown();rejectSleep(Error('denied'));await tick;assert.equal(f.active.size,0);});
