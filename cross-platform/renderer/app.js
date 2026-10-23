'use strict';
const $=id=>document.getElementById(id);let current,agentSignature='',eventSignature='',drag=null,toastTimer;
const esc=value=>String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
async function act(action,value){const response=await window.sleepdock.invoke(action,value);if(!response.ok)toast(response.error);else if(typeof response.result==='string')toast(response.result);return response;}
function toast(message){$('toast').textContent=message;$('toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').hidden=true,6000);}
function duration(seconds){if(!Number.isFinite(seconds))return '未知';return seconds<60?`${Math.floor(seconds)} 秒`:`${Math.floor(seconds/60)} 分钟`;}
function render(state){
  current=state;const s=state.settings,p=state.power,c=state.capabilities;
  for(const key of ['masterEnabled','agentProtection','sleepAfterAgents','keepDisplayAwake','acOnly','floatOnTop','compact'])$(key).checked=s[key];
  for(const key of ['minutes','lowBatteryCutoff','opacity'])if(document.activeElement!==$(key))$(key).value=s[key];
  document.documentElement.style.setProperty('--shade',String(s.opacity*.82));
  document.body.classList.toggle('compact',s.compact);
  $('reason').textContent=state.reason||'正在读取状态';$('badge').textContent=s.masterEnabled?(state.protected?'● 保护中':'● 已启用'):'● 已停用';
  $('badge').style.color=state.protected?'#69ebc9':'#c3d2cf';$('moon').textContent=state.protected?'☼':'☾';
  $('detail').textContent=!s.masterEnabled?'打开总开关，启用所选休眠规则。':state.tasks.length?state.tasks.slice(0,3).map(t=>t.label||t.name||t.source).join('、'):'休眠规则已生效，可随时停用。';
  $('battery').textContent=(p.pluggedIn===true?'ϟ ':'')+(p.battery>=0?`${p.battery}%`:'电量未知');$('idle').textContent=duration(p.idleSeconds);$('taskCount').textContent=`${state.tasks.length} 个`;
  $('power').textContent=p.pluggedIn===true?'已接电':p.pluggedIn===false?'电池':'未知';
  $('duration').hidden=!['idle','timer'].includes(s.mode);$('timerControls').hidden=s.mode!=='timer';$('timerText').textContent=state.timerSeconds==null?'未开始':duration(state.timerSeconds);
  document.querySelectorAll('[data-mode]').forEach(b=>b.classList.toggle('selected',b.dataset.mode===s.mode));
  document.querySelectorAll('[data-lid]').forEach(b=>{b.classList.toggle('selected',b.dataset.lid===state.lidMode);b.disabled=b.dataset.lid!=='system'&&(!s.masterEnabled||!c[b.dataset.lid==='keep'?'lidKeepAwake':'lidSleep']);});
  $('lidHint').textContent=(c.notes||[]).join(' ');$('selectedCount').textContent=`${s.selectedAgents.length} 个已选`;
  $('sleepButton').disabled=!s.masterEnabled||!c.sleep;$('displayButton').disabled=!c.displayOff;$('lockButton').disabled=!c.lock;
  $('countdown').hidden=!state.countdown;if(state.countdown)$('countdownText').textContent=`${state.countdown.seconds} 秒后休眠`;
  $('error').hidden=!state.lastError;$('errorText').textContent=state.lastError||'';
  $('platformLabel').textContent=`${state.platform==='win32'?'Windows':state.platform==='linux'?'Linux':'界面验证'} · 固定宽度 / 拖底调高`;
  const signature=JSON.stringify([state.apps,s.selectedAgents]);
  if(signature!==agentSignature){agentSignature=signature;$('agents').innerHTML=state.apps.map(a=>`<div class="agent"><input data-agent="${esc(a.id)}" id="agent-${esc(a.id)}" type="checkbox" ${s.selectedAgents.includes(a.id)?'checked':''}><label for="agent-${esc(a.id)}">${esc(a.name)}<small class="${a.running?'running':''}">${a.running?'运行中':a.installed?'已安装':'未检测到安装'} · ${a.mode==='lifecycle'?'任务事件检测':'运行状态保护'}</small></label>${a.id.startsWith('custom-')?`<button data-remove="${esc(a.id)}" title="移除自选App">×</button>`:''}</div>`).join('');}
  const events=JSON.stringify(state.events);if(events!==eventSignature){eventSignature=events;$('events').innerHTML=(state.events||[]).slice(0,12).map(e=>`<li><time>${esc(new Date(e.at).toLocaleTimeString())}</time>${esc(e.message)}</li>`).join('')||'<li>暂无记录</li>';}
}
document.addEventListener('click',event=>{
  const b=event.target.closest('button');if(!b)return;
  if(b.dataset.action)act(b.dataset.action);
  if(b.dataset.mode)act('update',{mode:b.dataset.mode});
  if(b.dataset.lid)act('lid',b.dataset.lid);
  if(b.dataset.remove)act('removeApp',b.dataset.remove);
  if(b.dataset.toggle)act('update',{[b.dataset.toggle]:!current.settings[b.dataset.toggle]});
});
document.addEventListener('change',event=>{
  const input=event.target;
  if(input.dataset.agent){const selected=[...document.querySelectorAll('[data-agent]:checked')].map(el=>el.dataset.agent);current.settings.selectedAgents=selected;act('update',{selectedAgents:selected});return;}
  if(input.matches('input[id]'))act('update',{[input.id]:input.type==='checkbox'?input.checked:Number(input.value)});
});
$('resize').addEventListener('pointerdown',event=>{event.preventDefault();drag={screenY:event.screenY};$('resize').setPointerCapture(event.pointerId);act('resizeStart');});
$('resize').addEventListener('pointermove',event=>{if(drag)act('resizeBy',event.screenY-drag.screenY);});
for(const type of ['pointerup','pointercancel'])$('resize').addEventListener(type,()=>{drag=null;act('resizeEnd');});
$('resize').addEventListener('keydown',event=>{if(['ArrowUp','ArrowDown'].includes(event.key)){event.preventDefault();act('resizeStart').then(()=>act('resizeBy',event.key==='ArrowUp'?-20:20)).then(()=>act('resizeEnd'));}});
window.sleepdock.onState(render);act('get').then(response=>{if(response.result)render(response.result);});
