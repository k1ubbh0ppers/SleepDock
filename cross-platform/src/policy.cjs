'use strict';

const DEFAULTS = Object.freeze({masterEnabled:false, mode:'system', minutes:30,
  agentProtection:true, sleepAfterAgents:false, keepDisplayAwake:false, acOnly:false,
  lowBatteryCutoff:20, floatOnTop:true, compact:false, opacity:0.82,
  selectedAgents:['deepseek','codex','workbuddy','muse','claude','cindy'], customApps:[],
  normalHeight:728, compactHeight:300});
const WIDTH=390, MIN_HEIGHT=260;
function normalize(value={}) {
  const s=structuredClone(DEFAULTS);
  for(const key of ['masterEnabled','agentProtection','sleepAfterAgents','keepDisplayAwake','acOnly','floatOnTop','compact'])
    if(typeof value[key]==='boolean') s[key]=value[key];
  if(['system','idle','timer','never'].includes(value.mode)) s.mode=value.mode;
  for(const [key,min,max] of [['minutes',1,1440],['lowBatteryCutoff',0,50],['normalHeight',MIN_HEIGHT,2000],['compactHeight',MIN_HEIGHT,2000]])
    if(Number.isFinite(value[key])) s[key]=Math.round(Math.max(min,Math.min(max,value[key])));
  if(Number.isFinite(value.opacity))s.opacity=Math.max(0.45,Math.min(1,value.opacity));
  if(Array.isArray(value.customApps)) s.customApps=value.customApps.filter(a=>a&&typeof a.id==='string'&&a.id.startsWith('custom-')&&typeof a.name==='string'&&typeof a.path==='string').slice(0,40);
  const allowed=new Set([...DEFAULTS.selectedAgents,...s.customApps.map(a=>a.id)]);
  if(Array.isArray(value.selectedAgents))s.selectedAgents=[...new Set(value.selectedAgents.filter(id=>allowed.has(id)))];
  return s;
}
function eligible(s,p) {
  return s.masterEnabled && (!s.acOnly||p.pluggedIn===true) &&
    !(p.pluggedIn!==true&&p.battery>=0&&p.battery<=s.lowBatteryCutoff);
}
function evaluate(s,p,tasks=[],uncertain=false) {
  const result=(awake,reason,idleDue=false)=>({awake,display:awake&&s.keepDisplayAwake,reason,idleDue});
  if(!s.masterEnabled)return result(false,'插件已停用');
  if(s.acOnly&&p.pluggedIn!==true)return result(false,'仅接电保护 · 当前未确认接电');
  if(!eligible(s,p))return result(false,'低电量 · 已释放保护');
  if(s.agentProtection&&tasks.length)return result(true,'Agent 正在工作');
  if(s.agentProtection&&uncertain)return result(true,'任务状态待确认 · 保留保护');
  if(s.mode==='never')return result(true,'保持清醒');
  if(s.mode==='timer')return result(true,'定时模式');
  if(s.mode==='idle') {
    const due=p.idleSeconds>=s.minutes*60;
    return result(!due,due?'空闲时间已到':`等待空闲 ${s.minutes} 分钟`,due);
  }
  return result(s.keepDisplayAwake,'跟随系统休眠设置');
}
class CompletionTracker {
  constructor(){this.reset();}
  reset(){this.observed=new Set();this.confirmed=new Set();this.previous=new Set();this.compromised=false;}
  consume(snapshot){
    const current=new Set(snapshot.tasks.map(t=>t.id));
    if(!this.observed.size&&!current.size)return false;
    for(const id of current)this.observed.add(id);
    for(const id of snapshot.completedTaskIDs||[])if(this.observed.has(id))this.confirmed.add(id);
    for(const id of this.previous)if(!current.has(id)&&!this.confirmed.has(id))this.compromised=true;
    if(snapshot.uncertainSources?.length||snapshot.interruptedSources?.length)this.compromised=true;
    this.previous=current;
    if(current.size)return false;
    const completed=!this.compromised&&[...this.observed].every(id=>this.confirmed.has(id));
    this.reset();return completed;
  }
}
module.exports={DEFAULTS,WIDTH,MIN_HEIGHT,normalize,eligible,evaluate,CompletionTracker};
