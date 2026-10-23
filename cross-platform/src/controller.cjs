'use strict';
const {EventEmitter}=require('node:events');
const {evaluate,eligible,CompletionTracker,normalize}=require('./policy.cjs');
class Controller extends EventEmitter {
  constructor({power,monitor,blocker,settings,now=Date.now}) {
    super();Object.assign(this,{power,monitor,blocker,now});this.settings=normalize(settings);
    this.tracker=new CompletionTracker();this.events=[];this.countdown=null;this.timer=null;
    this.systemBlocker=null;this.displayBlocker=null;this.busy=false;this.lidMode='system';
    this.generation=0;this.lidEpoch=0;this.idleSuppressed=false;this.closed=false;this.lastError='';
    this.state={settings:this.settings,apps:[],tasks:[],power:{battery:-1,pluggedIn:null,idleSeconds:0},capabilities:power.capabilities(),lidMode:'system',events:[]};
  }
  log(message){this.events.unshift({at:this.now(),message});this.events.length=Math.min(this.events.length,40);}
  cancel(reason='已取消休眠') {this.generation++;this.countdown=null;this.timer=null;this.idleSuppressed=true;this.log(reason);}
  update(patch) {
    const previous=this.settings;this.settings=normalize({...previous,...patch});
    this.cancel('设置已更新');this.idleSuppressed=false;this.tracker.reset();
    if(!this.settings.masterEnabled){
      this.applyBlockers(false,false);
      this.changeLid('system').catch(error=>{this.lastError=error.message;this.log(error.message);});
    }
    this.emit('settings',this.settings);
  }
  startTimer(){if(!this.settings.masterEnabled)throw Error('请先启用插件');this.cancel('已开始定时');this.idleSuppressed=false;this.timer=this.now()+this.settings.minutes*60000;}
  manualSleep(){if(!this.settings.masterEnabled)throw Error('请先启用插件');this.arm('manual',15);}
  arm(kind,seconds){this.generation++;this.countdown={kind,started:this.now(),deadline:this.now()+seconds*1000};this.log(`${{agents:'任务完成',timer:'定时',idle:'空闲',manual:'手动'}[kind]}休眠 · ${seconds} 秒取消窗口`);}
  activity(power){return !Number.isFinite(power.idleSeconds)||this.now()-power.idleSeconds*1000>this.countdown.started+500;}
  applyBlockers(system,display){
    for(const [field,enabled,type] of [['systemBlocker',system,'prevent-app-suspension'],['displayBlocker',display,'prevent-display-sleep']]) {
      const id=this[field];
      if(enabled&&(id===null||!this.blocker.isStarted(id)))this[field]=this.blocker.start(type);
      else if(!enabled&&id!==null){this.blocker.stop(id);this[field]=null;}
    }
  }
  async changeLid(mode){
    if(mode!=='system'&&!this.settings.masterEnabled)throw Error('请先启用插件');
    if(mode==='keep'&&this.state.power.pluggedIn!==true)throw Error('合盖保持运行需要接电');
    const epoch=++this.lidEpoch;
    const result=await this.power.setLidMode(mode);
    if(epoch!==this.lidEpoch)throw Error('合盖请求已取消');
    if(mode!=='system'&&(this.closed||!this.settings.masterEnabled)){
      await this.power.setLidMode('system');this.lidMode='system';throw Error('插件已停用，合盖请求已取消');
    }
    if(result?.ok===false)throw Error(result.message||'合盖规则未生效');
    this.lidMode=mode;this.log(`合盖规则：${{system:'系统默认',keep:'保持运行',sleep:'合盖休眠'}[mode]}`);
  }
  async read(){
    const [power,snapshot]=await Promise.all([this.power.status(),this.monitor.poll(this.settings.selectedAgents,this.settings.customApps)]);
    return {power,snapshot};
  }
  blocked(snapshot){return this.settings.agentProtection&&(snapshot.tasks.length>0||snapshot.uncertainSources?.length>0);}
  tick(){
    if(this.closed)return Promise.resolve();
    if(this.runningTick)return this.runningTick;
    const pending=this.runTick();this.runningTick=pending;
    const clear=()=>{if(this.runningTick===pending)this.runningTick=null;};pending.then(clear,clear);return pending;
  }
  async runTick(){
    this.busy=true;
    try {
      const generation=this.generation;
      const {power,snapshot}=await this.read();if(this.closed||generation!==this.generation)return;
      const decision=evaluate(this.settings,power,snapshot.tasks,Boolean(snapshot.uncertainSources?.length));
      const complete=this.tracker.consume(snapshot);
      if(this.lidMode!=='system'&&(!eligible(this.settings,power)||(this.lidMode==='keep'&&power.pluggedIn!==true)))await this.changeLid('system');
      if(this.closed||generation!==this.generation)return;
      if(!this.settings.masterEnabled){this.countdown=null;this.timer=null;this.tracker.reset();}
      if(power.idleSeconds<3)this.idleSuppressed=false;
      const activity=this.countdown&&['agents','idle'].includes(this.countdown.kind)&&this.activity(power);
      const compromised=this.settings.agentProtection&&Boolean(snapshot.interruptedSources?.length||snapshot.uncertainSources?.length);
      if(this.countdown&&(activity||this.blocked(snapshot)||compromised||!eligible(this.settings,power)))this.cancel('电脑操作、新任务或状态变化，取消休眠');
      if(complete&&this.settings.sleepAfterAgents&&this.settings.agentProtection&&eligible(this.settings,power)&&!this.countdown&&power.idleSeconds>=3)this.arm('agents',60);
      if(this.timer&&this.timer<=this.now()&&!this.blocked(snapshot)&&eligible(this.settings,power)&&!this.countdown){this.timer=null;this.arm('timer',60);}
      if(decision.idleDue&&!this.idleSuppressed&&!this.countdown)this.arm('idle',15);
      if(this.lidMode==='sleep'&&power.lidClosed===true&&!this.blocked(snapshot)&&eligible(this.settings,power)&&!this.countdown)this.arm('manual',15);
      this.applyBlockers(decision.awake||Boolean(this.countdown)&&eligible(this.settings,power),decision.display);
      this.state={settings:this.settings,apps:snapshot.apps||[],tasks:snapshot.tasks,power,
        uncertainSources:snapshot.uncertainSources||[],capabilities:this.power.capabilities(),lidMode:this.lidMode,
        reason:decision.reason,protected:this.systemBlocker!==null||this.displayBlocker!==null,
        countdown:this.countdown?{kind:this.countdown.kind,seconds:Math.max(0,Math.ceil((this.countdown.deadline-this.now())/1000))}:null,
        timerSeconds:this.timer?Math.max(0,Math.ceil((this.timer-this.now())/1000)):null,events:this.events,lastError:this.lastError};
      if(this.countdown&&this.countdown.deadline<=this.now())await this.finalSleep();
    } catch(error){if(this.closed)return;this.lastError=error.message;this.log(error.message);this.cancel('检测失败，取消休眠');
      // Keep protection when monitoring failed, except when the plugin is explicitly disabled.
      this.applyBlockers(eligible(this.settings,this.state.power)&&this.settings.agentProtection,false);
      this.state={...this.state,lastError:this.lastError,settings:this.settings,countdown:null,events:this.events};
    } finally {this.busy=false;if(!this.closed)this.emit('state',this.state);}
  }
  async finalSleep(){
    const token=this.generation;
    const check=await this.read();const completed=this.tracker.consume(check.snapshot);
    void completed;
    if(this.closed||token!==this.generation||!this.countdown)return;
    if(!eligible(this.settings,check.power)||this.blocked(check.snapshot)||(this.settings.agentProtection&&(check.snapshot.interruptedSources?.length||
       check.snapshot.uncertainSources?.length))||(['agents','idle'].includes(this.countdown.kind)&&this.activity(check.power))){
      this.cancel('休眠前复核：继续运行');return;
    }
    if(this.lidMode!=='system'){await this.changeLid('system');
      const final=await this.read();this.tracker.consume(final.snapshot);
      if(this.closed||token!==this.generation||!this.countdown||this.blocked(final.snapshot)||(this.settings.agentProtection&&(final.snapshot.interruptedSources?.length||final.snapshot.uncertainSources?.length))||!eligible(this.settings,final.power)||(['agents','idle'].includes(this.countdown.kind)&&this.activity(final.power))){
        this.cancel('恢复合盖规则后状态变化，取消休眠');return;
      }
    }
    this.countdown=null;this.timer=null;this.idleSuppressed=true;
    this.applyBlockers(false,false);
    try {await this.power.sleep();this.log('已提交系统休眠请求');}
    catch(error){if(!this.closed&&eligible(this.settings,check.power))this.applyBlockers(true,this.settings.keepDisplayAwake);throw error;}
  }
  wake(){this.cancel('电脑已唤醒，取消旧定时');this.tracker.reset();this.idleSuppressed=true;}
  async shutdown(){this.closed=true;this.lidEpoch++;this.cancel('正在退出');this.applyBlockers(false,false);await this.power.shutdown();}
}
module.exports={Controller};
