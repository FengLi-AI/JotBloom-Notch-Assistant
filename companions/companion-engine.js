/* One owner for the companion. Pure timeline logic: no DOM, timers, or drawing. */
(function(root){
  'use strict';
  const clamp=(x,a=0,b=1)=>Math.max(a,Math.min(b,x));
  const mix=(a,b,t)=>a+(b-a)*t;
  const ease=x=>{x=clamp(x);return x*x*(3-2*x);};
  // Two full character cells (4 CSS px) are outside the usable pocket width.
  const G={notchX:665.5,notchY:20,notchWidth:179,notchHeight:32,out:628.5,inside:673.5,width:41,flare:4};
  const holds={idle:5.2,curious:6.4,sleep:30,tired:22,energetic:6.4,satisfied:3.6,receive:5.15,notify:5};
  const opening=u=>u<.2?mix(0,.1,ease(u/.2)):u<.76?mix(.1,1.035,ease((u-.2)/.56)):mix(1.035,1,ease((u-.76)/.24));
  const closing=u=>u<.18?mix(1,1.022,ease(u/.18)):1.022*(1-ease((u-.18)/.82));
  const leaving=new Set(['walk-back','glide-back','peek','closing']);
  const sleeping=m=>m==='sleep'||m==='tired';
  const entering=new Set(['opening','walk-out','glide-out','returning','arriving','app-return']);
  const restHolds={resident:{sleep:[75,110],tired:[40,55]},occasional:{sleep:[30,42],tired:[22,28]}};
  class Companion {
    constructor(options={}){
      this.random=options.random||Math.random;
      this.resident=options.resident===true;this.occasionalBackdrop=options.backdrop!==false;this.frequency=clamp(Number(options.frequency??50),0,100);this.lastTouch=-Infinity;
      this.reduced=!!options.reduced;this.motionReduced=this.reduced;this.auto=true;this.foreground=false;this.manualHidden=false;
      this.phase=this.resident?'idle':'hidden';this.elapsed=0;this.duration=Infinity;this.clock=0;this.token=0;
      this.mood='idle';this.source='idle';this.event=null;this.goal=null;this.afterWake=null;this.reserved=false;
      this.queue={receive:false,notify:false};this.lastPassive='';this.lastMood='idle';this.peekOnReturn=false;
      this.appOpen=false;this.appProgress=0;this.appFrom=0;this.appElapsed=0;this.eventsDeferred=false;this.restTravelMood=null;this.restStartedAt=0;
      this.restAvailableAt=90;this.lastRest='';this.touchVariant=0;this.hovering=false;
      this.from=this.resident?{width:G.width,x:G.out,opacity:1}:{width:0,x:G.inside,opacity:0};this.nextIn=this.gap();
    }
    gap(){return this.resident?45+this.random()*30:mix(55,10,this.frequency/100)*(1+this.random()*.55);}
    get backdrop(){return !this.resident&&this.occasionalBackdrop;}
    restDuration(mood){const [low,high]=restHolds[this.resident?'resident':'occasional'][mood];return mix(low,high,this.random());}
    setAuto(value){this.auto=!!value;if(this.auto)this.nextIn=this.gap();}
    snapshot(){
      const u=this.duration===Infinity?0:clamp(this.elapsed/this.duration),e=ease(u);
      let width=G.width,x=G.out,opacity=1,kind='mood',mood=this.mood;
      if(this.phase==='hidden'){width=0;x=G.inside;opacity=0;kind='idle';mood='idle';}
      else if(this.phase==='opening'){width=mix(this.from.width,G.width,this.motionReduced?e:opening(u));x=G.inside;opacity=0;kind='idle';mood='idle';}
      else if(['walk-out','glide-out','returning','app-return'].includes(this.phase)){
        width=mix(this.from.width,G.width,e);x=mix(this.from.x,G.out,e);opacity=mix(this.from.opacity,1,e);kind='walk-left';mood='idle';
        if(this.restTravelMood&&this.phase!=='app-return'){kind='glide';mood=this.restTravelMood;}
        if(this.phase==='app-return')kind='run-left';
        if(this.motionReduced){x=G.out;opacity=mix(this.from.opacity,1,e);}
      }else if(this.phase==='walk-back'||this.phase==='glide-back'){
        width=this.from.width;x=mix(this.from.x,G.inside,e);opacity=this.from.opacity;kind='walk-right';mood='idle';
        if(this.phase==='glide-back'){kind='glide';mood=this.restTravelMood||this.mood;}
        if(this.motionReduced){x=this.from.x;opacity=this.from.opacity*(1-e);}
      }else if(this.phase==='app-retreat'){
        x=mix(this.from.x,G.inside,e);width=this.from.width*(1-ease((u-.5)/.5));opacity=this.from.opacity*(1-ease((u-.75)/.25));kind='run-right';mood='idle';
        if(this.motionReduced){x=this.from.x;opacity=this.from.opacity*(1-e);}
      }else if(this.phase==='peek'){
        const peek=ease(u/.26)*(1-ease((u-.52)/.42));width=this.from.width*(1-.85*ease((u-.58)/.42));x=mix(G.inside,G.notchX-18,peek);kind='peek';mood='idle';
      }else if(this.phase==='closing'){
        width=this.from.width*(this.motionReduced?1-e:closing(u));x=G.inside;opacity=0;kind='idle';mood='idle';
      }else if(this.phase==='dismiss'){
        width=this.from.width*(1-e);x=this.motionReduced?this.from.x:mix(this.from.x,G.inside,e);opacity=this.from.opacity*(1-e);kind='freeze';
      }else if(['waking','recover','arriving','lingering'].includes(this.phase)) {kind='idle';mood='idle';}
      else if(this.phase==='greet'){kind='wave';mood=this.lastMood==='receive'?'satisfied':'idle';}
      else if(this.phase==='idle'){kind='idle';mood='idle';}
      const restSettled=!!this.restTravelMood&&sleeping(mood)&&!['waking','app-retreat','app-return'].includes(this.phase);
      return {appOpen:this.appOpen,appProgress:this.appProgress,eventsDeferred:this.eventsDeferred,restSettled,poseTime:restSettled?this.clock-this.restStartedAt+2:null,phase:this.phase,elapsed:this.elapsed,duration:this.duration,token:this.token,mood,kind,source:this.source,event:this.event,width,x,opacity,clock:this.clock,resident:this.resident,backdrop:this.backdrop,manualHidden:this.manualHidden,reserved:this.reserved,queued:{...this.queue},touchAge:this.clock-this.lastTouch,touchVariant:this.touchVariant};
    }
    enter(phase,duration=Infinity){
      const s=this.snapshot();this.from={width:s.width,x:s.x,opacity:s.opacity};
      this.phase=phase;this.elapsed=0;this.duration=duration;this.motionReduced=this.reduced;this.token++;
    }
    durationFor(phase,normal){return this.reduced&&['opening','walk-out','glide-out','returning','walk-back','glide-back','closing','dismiss','app-return','app-retreat'].includes(phase)?.16:normal;}
    moving(phase,normal){this.enter(phase,this.durationFor(phase,normal));}
    setAppOpen(value){
      value=!!value;if(value===this.appOpen)return;
      this.appFrom=this.appProgress;this.appElapsed=0;this.appOpen=value;
      if(value){
        if(this.event)this.queue[this.event]=true;
        if(this.goal?.source==='event')this.queue[this.goal.mood]=true;
        this.event=null;this.goal=null;this.afterWake=null;this.eventsDeferred=true;this.hovering=false;this.source='app';this.restTravelMood=null;
        if(this.phase!=='hidden')this.moving('app-retreat',.3);
      }else{
        this.nextIn=this.gap();
        if(this.resident){this.eventsDeferred=false;this.mood='idle';this.goal={mood:'idle',source:'idle'};this.moving('app-return',.38);}
        else if(this.phase!=='app-retreat')this.enter('hidden');
      }
    }
    setResident(value){
      value=!!value;if(this.resident===value)return;this.resident=value;this.nextIn=this.gap();if(this.appOpen)return;
      // Change only remaining rest; never reset the pose or elapsed clock.
      if(this.phase==='active'&&sleeping(this.mood))this.duration=value?Math.max(this.duration,this.restDuration(this.mood)):this.elapsed+Math.min(this.duration-this.elapsed,this.mood==='sleep'?12:8);
      if(value){
        this.manualHidden=false;
        if(leaving.has(this.phase)||this.phase==='dismiss'||this.phase==='app-retreat') {this.goal={mood:this.restTravelMood||'idle',source:this.restTravelMood?'passive':'idle'};this.moving('returning',.7);}
        else if(this.phase==='hidden')this.begin('idle','idle');
      }else{
        this.manualHidden=false;
        if(this.phase==='app-return'){this.eventsDeferred=true;this.goal=null;this.moving('app-retreat',.28);return;}
        if(this.phase==='idle'&&!this.reserved){this.mood='idle';this.source='passive';this.enter('active',2.4);}
      }
    }
    setBackdrop(value){if(this.resident)return;this.occasionalBackdrop=!!value;if(!this.backdrop&&this.phase==='opening')this.moving(this.restTravelMood?'glide-out':'walk-out',.85);}
    setFrequency(value){this.frequency=clamp(Number(value)||0,0,100);if(!this.resident)this.nextIn=this.gap();}
    setForeground(value){
      this.foreground=!!value;if(!value)return;this.queue.notify=false;
      if(this.event==='notify'||this.goal?.mood==='notify'){
        this.event=null;this.goal=null;this.mood='idle';
        if(entering.has(this.phase)){
          if(this.resident){this.goal={mood:'idle',source:'idle'};}
          else this.moving('walk-back',.65);
        }else {this.afterWake='settle';this.enter('recover',.45);}
      }
    }
    reserveReceipt(){
      this.reserved=true;
      // A visible companion waits in place for the receipt instead of exiting then reopening.
      if(!this.appOpen&&leaving.has(this.phase)){this.goal={mood:'idle',source:'idle'};this.moving('returning',.7);}
    }
    requestEvent(kind){
      if(!['receive','notify'].includes(kind)||kind==='notify'&&this.foreground)return false;
      if(kind==='receive')this.reserved=false;
      this.manualHidden=false;
      if(this.event===kind||this.goal?.mood===kind&&this.goal.source==='event')return true;
      this.queue[kind]=true;
      if(this.appOpen)return true;
      if(this.eventsDeferred)this.eventsDeferred=false;
      if(kind==='receive'&&this.event==='notify'){this.queue.notify=true;this.event=null;}
      if(!this.event&&!this.reserved)this.dispatch();
      return true;
    }
    dispatch(){
      if(this.appOpen||['app-retreat','app-return'].includes(this.phase)||this.eventsDeferred||this.reserved)return false;
      const kind=this.queue.receive?'receive':this.queue.notify&&!this.foreground?'notify':null;
      if(!kind)return false;this.queue[kind]=false;this.begin(kind,'event');return true;
    }
    begin(mood,source='demo'){
      if(this.appOpen)return false;
      if(sleeping(this.mood)&&this.phase==='active'){this.lastRest=this.mood;this.restAvailableAt=this.clock+240;}
      this.manualHidden=false;const goal={mood,source};this.event=source==='event'?mood:null;this.source=source;
      if(this.phase==='hidden'||this.snapshot().width<.01){
        this.goal=goal;this.mood='idle';
        this.restTravelMood=!this.resident&&sleeping(mood)?mood:null;this.restStartedAt=this.clock;
        if(this.backdrop&&!this.reduced)this.moving('opening',.56);else this.moving(this.restTravelMood?'glide-out':'walk-out',.85);
      }else if(leaving.has(this.phase)||this.phase==='dismiss'){
        this.goal=goal;this.moving('returning',.7);
      }else if(entering.has(this.phase)){this.goal=goal;}
      else if(sleeping(this.mood)||this.phase==='waking'){
        this.goal=goal;this.afterWake='goal';this.enter('waking',.85);
      }else this.perform(goal);
    }
    perform(goal){
      if(!sleeping(goal.mood))this.restTravelMood=null;
      this.goal=null;this.mood=goal.mood;this.source=goal.source;this.event=goal.source==='event'?goal.mood:null;
      if(goal.source==='idle'){this.mood='idle';this.source='idle';this.event=null;this.enter('idle');this.nextIn=this.gap();}
      else this.enter('active',sleeping(goal.mood)?this.restDuration(goal.mood):holds[goal.mood]||5);
    }
    preview(mood){
      if(this.appOpen||!Object.hasOwn(holds,mood)||this.event||this.reserved)return false;
      this.begin(mood,'demo');return true;
    }
    show(){if(this.appOpen||this.event||this.reserved)return;this.eventsDeferred=false;if(this.dispatch())return;this.begin('idle',this.resident?'idle':'demo');}
    passive(touched=false){
      if(this.appOpen)return false;
      if(this.eventsDeferred){this.eventsDeferred=false;if(this.dispatch())return true;}
      if(this.event||this.reserved||this.queue.receive||this.queue.notify)return false;
      const weights=touched?[['curious',65],['energetic',35]]:this.resident?[['curious',48],['energetic',22],['sleep',24],['tired',6]]:[['idle',40],['curious',32],['energetic',18],['sleep',8],['tired',2]];
      const pool=weights.filter(([m])=>m!==this.lastPassive&&(!sleeping(m)||(this.clock>=this.restAvailableAt&&!(m==='tired'&&this.lastPassive==='energetic'))));let pick=this.random()*pool.reduce((a,[,w])=>a+w,0),mood=pool[0][0];
      for(const [m,w] of pool){pick-=w;if(pick<=0){mood=m;break;}}
      this.lastPassive=mood;this.begin(mood,touched?'touch':'passive');return true;
    }
    interact(){
      if(this.appOpen)return false;
      if(!this.resident){this.dismiss();return true;}
      if(this.clock-this.lastTouch<1.2)return false;
      this.lastTouch=this.clock;this.touchVariant=Math.floor(this.random()*3);
      // A small acknowledgement never restarts an event or the ongoing reply to a touch.
      if(this.event||this.reserved||this.source==='touch'&&['active','waking'].includes(this.phase))return true;
      return this.passive(true);
    }
    dismiss(immediate=false){
      if(this.resident||this.appOpen)return false;
      this.queue={receive:false,notify:false};this.reserved=false;this.event=null;this.goal=null;this.afterWake=null;
      this.eventsDeferred=false;this.manualHidden=this.resident;this.source='idle';this.nextIn=this.gap();
      if(immediate||this.phase==='hidden')this.enter('hidden');else this.moving('dismiss',.22);
    }
    slideRestBack(){
      this.lastRest=this.mood;this.lastMood=this.mood;this.restAvailableAt=this.clock+240;
      if(!this.restTravelMood){this.restTravelMood=this.mood;this.restStartedAt=this.clock-this.elapsed;}
      this.peekOnReturn=false;this.moving('glide-back',.95);
    }
    finishEntrance(){
      const goal=this.goal||{mood:'idle',source:this.resident?'idle':'demo'};
      if(this.restTravelMood){
        if(sleeping(goal.mood))this.perform(goal);
        else {this.mood=this.restTravelMood;this.afterWake='goal';this.enter('waking',.85);}
      }else this.enter('arriving',this.reduced?.12:.32);
    }
    settle(){
      if(sleeping(this.lastMood)){this.lastRest=this.lastMood;this.restAvailableAt=this.clock+240;}
      this.event=null;this.goal=null;this.afterWake=null;
      if(!this.reserved&&this.dispatch())return;
      if(this.reserved||this.resident&&!this.manualHidden){this.mood='idle';this.source='idle';this.enter('idle');this.nextIn=this.gap();}
      else {this.mood='idle';this.peekOnReturn=(['receive','notify'].includes(this.lastMood)||['curious','energetic'].includes(this.lastMood)&&this.random()<.65)&&!this.reduced;this.enter('lingering',this.reduced?.16:sleeping(this.lastMood)?1.3:.65);}
    }
    finishPhase(){
      switch(this.phase){
        case 'opening':this.moving(this.restTravelMood?'glide-out':'walk-out',.85);break;
        case 'walk-out':case 'glide-out':case 'returning':this.finishEntrance();break;
        case 'app-retreat':this.mood='idle';this.enter('hidden');this.nextIn=this.gap();if(!this.appOpen)this.dispatch();break;
        case 'app-return':this.mood='idle';this.goal=null;this.source='idle';this.enter('idle');this.nextIn=this.gap();this.dispatch();break;
        case 'arriving':this.perform(this.goal||{mood:'idle',source:this.resident?'idle':'demo'});break;
        case 'active':
          this.lastMood=this.mood;
          if(!this.resident&&sleeping(this.mood)&&!this.queue.receive&&!this.queue.notify){if(this.reserved)this.enter('rest-wait');else this.slideRestBack();}
          else if(['receive','notify'].includes(this.mood))this.enter('greet',.9);
          else {this.afterWake='settle';this.enter(sleeping(this.mood)?'waking':'recover',sleeping(this.mood)?1.3:.5);}
          break;
        case 'waking':case 'recover':if(this.afterWake==='goal'&&this.goal)this.perform(this.goal);else this.settle();break;
        case 'greet':this.afterWake='settle';this.enter('recover',.5);break;
        case 'lingering':
          if(this.resident||this.reserved){this.mood='idle';this.source='idle';this.enter('idle');}
          else if(!this.dispatch())this.moving('walk-back',.9);break;
        case 'glide-back':this.moving('closing',.38);break;
        case 'walk-back':
          if(this.resident||this.reserved||this.queue.receive||this.queue.notify){this.goal={mood:'idle',source:'idle'};this.moving('returning',.7);}
          else if(this.peekOnReturn&&!this.reduced)this.moving('peek',1.15);else this.moving('closing',.44);break;
        case 'peek':this.moving('closing',.26);break;
        case 'closing':case 'dismiss':this.restTravelMood=null;this.mood='idle';this.event=null;this.source='idle';this.enter('hidden');this.nextIn=this.gap();break;
      }
    }
    tick(dt){
      this.clock+=dt;this.appElapsed+=dt;this.appProgress=mix(this.appFrom,this.appOpen?1:0,ease(this.appElapsed/(this.appOpen?.34:.24)));
      if(!this.appOpen&&(this.phase==='hidden'||this.phase==='idle')&&!this.reserved&&!this.hovering&&!this.manualHidden&&this.auto){
        this.nextIn-=dt;if(this.nextIn<=0){this.eventsDeferred=false;if(!this.dispatch())this.passive();}
      }
      let remain=dt,guard=0;
      while(remain>0&&guard++<16){
        const step=Math.min(remain,this.duration-this.elapsed);this.elapsed+=step;remain-=step;
        if(this.elapsed>=this.duration)this.finishPhase();else break;
      }
    }
  }
  class Notch {
    constructor(pet){this.pet=pet;this.phase='idle';this.elapsed=0;this.clock=0;this.auto=false;this.text='';this.records=[];this.batch=0;this.completed=false;this.height=0;this.velocity=0;this.cancelFrom=0;this.drop={x:755,y:36};}
    duration(){const map={approach:.8,hover:.75,ack:.55,absorb:.82,glow:.92,flash:.32,cancel:.22};if(this.pet.reduced)return {approach:.16,hover:.5,ack:.65,absorb:.18,glow:.28,flash:.04,cancel:.12}[this.phase];return map[this.phase];}
    enter(phase){this.phase=phase;this.elapsed=0;}
    get busy(){return ['ack','absorb','glow','flash'].includes(this.phase);}
    hover(){if(!this.pet.appOpen&&!this.busy&&!this.auto){this.pet.hovering=true;if(this.phase!=='hover')this.enter('hover');}}
    leave(){this.pet.hovering=false;if(this.phase==='hover'&&!this.auto)this.enter('idle');}
    accept(text,point){
      if(this.pet.appOpen)return false;
      text=String(text||'').trim().slice(0,4000);if(!text){this.leave();return false;}this.pet.hovering=false;
      this.records.push(text);this.auto=false;this.completed=false;
      if(this.busy){this.batch++;return true;}
      this.batch=1;this.drop=point||{x:755,y:36};this.height=1;this.velocity=0;this.pet.reserveReceipt();this.enter('ack');return true;
    }
    play(text){
      if(this.pet.appOpen||!String(text||'').trim())return false;
      if(this.busy)return this.accept(text);
      this.auto=true;this.pet.hovering=true;this.text=text;this.completed=false;this.enter('approach');return true;
    }
    cancel(immediate=false){this.pet.hovering=false;this.auto=false;this.pet.reserved=false;this.cancelFrom=this.height;this.completed=false;this.enter(immediate?'idle':'cancel');if(immediate){this.height=0;this.velocity=0;}}
    tick(dt){
      this.clock+=dt;const target=this.phase==='hover'||this.phase==='ack'?1:0;
      if(this.pet.reduced){this.height=target;this.velocity=0;}
      else {let left=dt;while(left>0){const h=Math.min(left,1/120);this.velocity+=((target-this.height)*250-this.velocity*26)*h;this.height+=this.velocity*h;left-=h;}}
      if(Math.abs(this.height)<.001&&Math.abs(this.velocity)<.01){this.height=0;this.velocity=0;}
      if(this.phase==='idle'||this.phase==='hover'&&!this.auto)return;
      this.elapsed+=dt;
      if(this.elapsed<this.duration())return;
      if(this.phase==='approach')this.enter('hover');
      else if(this.phase==='hover')this.accept(this.text);
      else if(this.phase==='ack')this.enter('absorb');
      else if(this.phase==='absorb')this.enter('glow');
      else if(this.phase==='glow')this.enter('flash');
      else if(this.phase==='flash'){this.completed=true;this.enter('idle');this.pet.requestEvent('receive');}
      else if(this.phase==='cancel'){this.height=0;this.velocity=0;this.enter('idle');}
    }
  }
  class Demo {
    constructor(options={}){this.pet=new Companion(options);this.notch=new Notch(this.pet);this.paused=false;this.slow=false;}
    tick(dt){if(this.paused)return;let left=Math.min(Math.max(dt,0),.25)*(this.slow?.65:1);while(left>0){const step=Math.min(left,1/60);this.notch.tick(step);this.pet.tick(step);left-=step;}}
    setAppOpen(value){
      const pending=value&&!this.pet.appOpen&&(this.notch.busy||this.pet.reserved);
      this.pet.setAppOpen(value);if(value){this.notch.cancel(true);if(pending)this.pet.requestEvent('receive');}
    }
    interact(){if(this.pet.appOpen)return false;if(this.pet.resident)return this.pet.interact();this.dismiss();return true;}
    dismiss(){if(this.pet.resident||this.pet.appOpen)return false;this.notch.cancel(this.paused||this.pet.reduced);this.pet.dismiss(this.paused||this.pet.reduced);return true;}
  }
  const api={Demo,Companion,Notch,geometry:G,holds};
  if(typeof module==='object'&&module.exports)module.exports=api;else root.JotBloomCompanion=api;
})(globalThis);
