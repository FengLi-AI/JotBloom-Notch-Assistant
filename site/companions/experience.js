/* Website scenarios use the same character player and notch timeline as the app. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id), art = CompanionArt, api = NativeCompanion;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)'), mobile = matchMedia('(max-width:620px)');
  const clamp = (v, a=0, b=1) => Math.max(a, Math.min(b, v)), mix = (a,b,t) => a+(b-a)*t;
  const smooth = t => {t=clamp(t);return t*t*(3-2*t);};
  const progress = (t,a,b) => smooth((t-a)/(b-a)), easeOut = t => 1-Math.pow(1-clamp(t),3);
  let selected='chuichui', paused=false, pendingMood=null, view='detail';
  let last=performance.now(), recordCount=0, taskTime=null, taskFinished=false, taskWasForeground=false;
  api.init({resident:true, backdrop:true, frequency:50, reduced:reduced.matches});
  // Bridge the existing capture timeline to the native player's public commands.
  const pet = {
    get reduced(){return reduced.matches;}, get appOpen(){return false;},
    set hovering(value){api.action('hovering',value);},
    set reserved(value){api.action(value?'reserve':'release');},
    reserveReceipt(){api.action('reserve');}, requestEvent(value){api.action('event',value);}
  };
  const notch = new JotBloomCompanion.Notch(pet);
  const svg=$('capture-svg'), liquid=$('capture-liquid'), label=$('capture-liquid-label'), labelText=$('capture-liquid-text');
  const rim=$('capture-rim'), rimCtx=rim.getContext('2d'), rimGuide=$('capture-rim-path'), rimPath=new Path2D(rimGuide.getAttribute('d'));
  const flying=$('capture-flying-note'), source=$('capture-source-text');
  const NX=665.5, NY=20, NW=179, NH=32, CX=755, PROMPT_H=16, PROMPT_W=173, RIM_W=191, RIM_H=50;
  let rimWasVisible=false;
  const length=rimGuide.getTotalLength(), route=Array.from({length:513},(_,i)=>{const p=rimGuide.getPointAtLength(length*i/512);return{x:p.x,y:p.y};});
  const ringPoint=u=>{const n=((u%1+1)%1)*512,i=Math.floor(n),f=n-i;return{x:mix(route[i].x,route[i+1].x,f),y:mix(route[i].y,route[i+1].y,f)};};
    function liquidShape(height,bottomWidth,wave=0){
      const top=NY+22,bottom=NY+NH+height,left=NX+3,right=NX+176;
      const l=CX-bottomWidth/2,r=CX+bottomWidth/2,corner=Math.max(0,Math.min(9,bottomWidth*.24,(bottom-top)*.9));
      const k=corner*.55228475,shoulder=bottom-corner;
      return `M${left} ${top}H${right}C${right} ${top+(shoulder-top)*.65},${r} ${shoulder},${r} ${shoulder}C${r} ${shoulder+k},${r-corner+k} ${bottom+wave*.2},${r-corner} ${bottom}C${CX+bottomWidth*.18} ${bottom+wave},${CX-bottomWidth*.18} ${bottom-wave*.6},${l+corner} ${bottom}C${l+corner-k} ${bottom-wave*.2},${l} ${shoulder+k},${l} ${shoulder}C${l} ${shoulder},${left} ${top+(shoulder-top)*.65},${left} ${top}Z`;
    }
    function drawRim(laps,opacity){
      if(opacity<=0&&!rimWasVisible)return;
      rimCtx.setTransform(1,0,0,1,0,0);rimCtx.clearRect(0,0,rim.width,rim.height);rimWasVisible=opacity>0;if(opacity<=0)return;
      // Canvas starts at the screen top; the physical notch covers the inner halo.
      // rimPath is OPEN: left -> bottom -> right. No stroke or light crosses its top.
      rimCtx.setTransform(rim.width/RIM_W,0,0,rim.height/RIM_H,0,0);rimCtx.save();rimCtx.translate(6,0);
      const gradient=rimCtx.createLinearGradient(0,16,179,16);
      [[0,'#AFF0FF'],[.216314,'#1A58DE'],[.490385,'#DCA3FF'],[.74903,'#9338EE'],[1,'#70BAFF']].forEach(([at,color])=>gradient.addColorStop(at,color));
      rimCtx.strokeStyle=gradient;rimCtx.shadowColor='#a8baff';rimCtx.shadowBlur=2;rimCtx.lineWidth=2.1;rimCtx.globalAlpha=opacity*.24;rimCtx.stroke(rimPath);
      rimCtx.shadowBlur=0;rimCtx.lineWidth=1.05;rimCtx.globalAlpha=opacity;rimCtx.stroke(rimPath);
      for(let i=0;i<42;i++){
        const q=i/41,from=laps-.22+q*.22,to=from+.22/41;
        if(from<0||Math.floor(from)!==Math.floor(to))continue;
        const a=ringPoint(from),b=ringPoint(to);
        rimCtx.beginPath();rimCtx.moveTo(a.x,a.y);rimCtx.lineTo(b.x,b.y);rimCtx.strokeStyle=q>.8?'#d8f7ff':q>.45?'#DCA3FF':'#70BAFF';
        rimCtx.globalAlpha=opacity*Math.pow(q,1.3)*.95;rimCtx.lineWidth=mix(.7,1.45,q);rimCtx.lineCap='round';rimCtx.stroke();
      }
      rimCtx.restore();
    }
    function render(s){
      const phase=notch.phase,t=notch.elapsed,u=clamp(t/(notch.duration()||1));
      let height=PROMPT_H*notch.height,bottomWidth=PROMPT_W,wave=0,liquidAlpha=clamp(notch.height*4),labelAlpha=smooth((notch.height-.5)/.45),ringAlpha=0,laps=0;
      let noteAlpha=0,noteX=0,noteY=0,noteScale=1;
      if(phase==='hover')wave=reduced.matches?0:Math.sin(notch.clock*2.9)*.12;
      if(phase==='approach'){const e=smooth(u);noteAlpha=progress(u,0,.15)*(1-progress(u,.88,1));noteX=mix(CX-110,CX,e);noteY=mix(NY+95,NY+16,e)-Math.sin(u*Math.PI)*9;noteScale=mix(1,.65,e);}
      if(phase==='ack'){wave=reduced.matches?0:Math.sin(t*24)*Math.exp(-t*8)*.85;labelAlpha=1;noteAlpha=(1-progress(u,0,.22))*.85;noteX=mix(notch.drop.x,CX,progress(u,0,.22));noteY=mix(notch.drop.y,NY+16,progress(u,0,.22));noteScale=mix(.7,.15,progress(u,0,.22));}
      if(phase==='absorb'){bottomWidth=mix(PROMPT_W,8,progress(u,0,.7));height=mix(PROMPT_H,-10,progress(u,.26,1));liquidAlpha=1-progress(u,.87,1);labelAlpha=1-progress(u,0,.35);}
      if(phase==='glow'){height=0;liquidAlpha=0;labelAlpha=0;laps=2*u;ringAlpha=reduced.matches?.25:progress(u,0,.07);}
      if(phase==='flash'){height=0;liquidAlpha=0;labelAlpha=0;laps=2;ringAlpha=reduced.matches?0:u<.32?1-smooth(u/.32):u<.59?.92*smooth((u-.32)/.27):.92*(1-smooth((u-.59)/.41));}
      if(phase==='cancel'){height=PROMPT_H*notch.cancelFrom*(1-easeOut(u));bottomWidth=mix(PROMPT_W,12,easeOut(u));liquidAlpha=1-u;labelAlpha=1-progress(u,0,.4);}
      if(phase==='idle'&&notch.height<.001){liquidAlpha=0;labelAlpha=0;}
      liquid.setAttribute('d',liquidShape(height,bottomWidth,wave));liquid.setAttribute('opacity',liquidAlpha);label.setAttribute('opacity',labelAlpha);label.setAttribute('transform',`translate(0 ${height-PROMPT_H+wave*.12})`);
      labelText.textContent=phase==='ack'||phase==='absorb'?'收到，正在收录'+(notch.batch>1?' · '+notch.batch+' 条':''):'松手即可收录灵感';
      for(const [i,id] of ['capture-ripple-a','capture-ripple-b'].entries()){
        const age=t-i*.13,v=clamp(age/.68),ring=$(id),active=phase==='ack'&&age>=0&&!reduced.matches;
        ring.setAttribute('d',liquidShape(PROMPT_H,PROMPT_W,wave*.25));ring.setAttribute('transform',`translate(${CX} ${NY+NH}) scale(${1+v*.025} ${1+v*.1}) translate(${-CX} ${-NY-NH})`);ring.setAttribute('opacity',active?(1-v)*.15:0);ring.setAttribute('stroke-width',String(.4-v*.2));
      }
      drawRim(laps,ringAlpha);flying.setAttribute('opacity',noteAlpha);flying.setAttribute('transform',`translate(${noteX} ${noteY}) scale(${noteScale})`);
    }
  const notes={chuichui:'一只耳朵先下班',yuntuan:'一朵有点偏心的云',dujiao:'矮一点，也皮一点',momo:'尖耳和小尾巴',lili:'圆耳和暖暖的肚子',mumu:'轻轻扇动小翅膀'};
  const descriptions={idle:'轻轻呼吸，偶尔眨眨眼。',curious:'歪歪头，抬起小手看看你。',sleep:'慢慢趴下来，安心眯一会儿。',energetic:'伸个懒腰，今天状态不错。',tired:'有点累，先让它缓一缓。',satisfied:'开心地晃一晃，又收获一点想法。',notify:'举起小纸条，等你注意到。',receive:'稳稳接住，把这点灵感收好。'};
  function text(id,value){if($(id).textContent!==value)$(id).textContent=value;}
  function resume(){paused=false;updatePause();last=performance.now();}
  function updatePause(){text('pause',paused?'继续动画':'暂停动画');$('pause').setAttribute('aria-pressed',String(paused));}
  function revealStage(id){const r=$(id).getBoundingClientRect();if(r.top<24||r.bottom>innerHeight-24)$(id).scrollIntoView({behavior:reduced.matches?'instant':'smooth',block:'center'});}
  $('pause').onclick=()=>{paused=!paused;updatePause();};
  reduced.addEventListener('change',()=>api.action('reduced',reduced.matches));
  function fit(){
    svg.setAttribute('viewBox',view==='screen'?'0 0 1510 996':mobile.matches?'575 0 360 170':'505 0 500 170');
    const width=$('mini-scene').clientWidth||700;$('mini-scene').setAttribute('viewBox',`${755-width/2} 0 ${width} 86`);
  }
  mobile.addEventListener('change',fit);new ResizeObserver(fit).observe($('mini-scene'));fit();
  for(const name of ['detail','screen'])$('view-'+name).onclick=()=>{view=name;fit();for(const v of ['detail','screen'])$('view-'+v).setAttribute('aria-pressed',String(v===view));};
  function presence(resident){
    api.action('resident',resident);$('backdrop-setting').hidden=resident;resume();
    $('presence-resident').setAttribute('aria-pressed',String(resident));$('presence-occasional').setAttribute('aria-pressed',String(!resident));
    text('presence-note',resident?'留在刘海旁，安静地陪你一会儿。':'偶尔出来走走，动作结束后回刘海里。点击下方动作，马上看一次。');
  }
  $('pet-backdrop').onchange=()=>api.action('backdrop',$('pet-backdrop').checked);
  $('presence-resident').onclick=()=>presence(true);$('presence-occasional').onclick=()=>presence(false);
  const characterButtons=[],moodButtons=[];
  function drawThumb(canvas,id,mood='idle'){art.draw(canvas,id,art.poseAt(id,mood,3.6,true),3.6,{x:0,y:0},0,true);}
  for(const preset of art.presets){
    const b=document.createElement('button'),c=document.createElement('canvas'),name=document.createElement('span');
    c.width=160;c.height=128;c.setAttribute('aria-hidden','true');drawThumb(c,preset.id);
    name.textContent=preset.name;b.type='button';b.append(c,name);b.setAttribute('aria-label','选择'+preset.name);b.setAttribute('aria-pressed',String(preset.id===selected));
    b.onclick=()=>{selected=preset.id;characterButtons.forEach(item=>item.setAttribute('aria-pressed',String(item===b)));moodButtons.forEach(item=>drawThumb(item.querySelector('canvas'),selected,item.dataset.mood));text('character-note',preset.name+' · '+notes[preset.id]);text('capture-character',preset.name+'帮你接着');resume();};
    $('characters').append(b);characterButtons.push(b);
  }
  for(const mood of art.states.filter(s=>!['receive','notify'].includes(s.id))){
    const b=document.createElement('button'),c=document.createElement('canvas'),label=document.createElement('span');
    c.width=160;c.height=128;c.setAttribute('aria-hidden','true');drawThumb(c,selected,mood.id);label.textContent=mood.label;
    b.type='button';b.append(c,label);b.dataset.mood=mood.id;b.setAttribute('aria-pressed','false');
    b.onclick=()=>{resume();pendingMood=mood;revealStage('hero-stage');};$('moods').append(b);moodButtons.push(b);
  }
  function touch(){resume();api.action('interact');}
  for(const id of ['walker','hero-sprite','mini-sprite']){$(id).onclick=touch;$(id).onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();touch();}};}
  function playCapture(){
    const value=source.value.trim();if(!value){source.setCustomValidity('先写一句想留下的话，再试一次。');source.reportValidity();return;}
    resume();pendingMood=null;revealStage('desktop');notch.play(value.slice(0,2000));
  }
  source.addEventListener('input',()=>source.setCustomValidity(''));
  $('demo-capture').onclick=playCapture;$('capture-drag-handle').onclick=playCapture;
  $('capture-drag-handle').ondragstart=e=>{
    const value=source.value.trim();if(!value){e.preventDefault();source.focus();return;}
    resume();e.dataTransfer.setData('text/plain',value.slice(0,2000));e.dataTransfer.effectAllowed='copy';
    const ghost=$('capture-drag-ghost');ghost.textContent=value.length>20?value.slice(0,20)+'…':value;e.dataTransfer.setDragImage(ghost,-14,-20);
  };
  const pointFromClient=(x,y)=>{const p=svg.createSVGPoint();p.x=x;p.y=y;return p.matrixTransform(svg.getScreenCTM().inverse());};
  const hasText=e=>Array.from(e.dataTransfer?.types||[]).includes('text/plain');
  const inside=p=>p.x>=NX&&p.x<=NX+NW&&p.y>=NY&&p.y<=NY+NH;
  function over(e){if(!hasText(e))return;e.preventDefault();const hit=inside(pointFromClient(e.clientX,e.clientY));e.dataTransfer.dropEffect=hit?'copy':'none';if(hit){resume();notch.hover();}else notch.leave();}
  svg.addEventListener('dragenter',over);svg.addEventListener('dragover',over);
  svg.addEventListener('dragleave',e=>{if(!svg.contains(e.relatedTarget))notch.leave();});
  svg.addEventListener('drop',e=>{if(!hasText(e))return;e.preventDefault();e.stopPropagation();const point=pointFromClient(e.clientX,e.clientY);if(inside(point)){pendingMood=null;resume();notch.accept(e.dataTransfer.getData('text/plain').slice(0,2000),point);}else notch.leave();});
  document.addEventListener('dragend',()=>notch.leave());document.addEventListener('drop',()=>notch.leave());
  $('demo-notify').onclick=()=>{resume();pendingMood=null;revealStage('hero-stage');taskTime=0;taskFinished=false;$('demo-notify').disabled=true;};
  $('codex-foreground').onchange=()=>api.action('foreground',$('codex-foreground').checked);
  function tickTask(dt){
    if(taskTime===null)return;taskTime+=dt;
    if(taskTime>=2.4){taskTime=null;taskFinished=true;taskWasForeground=$('codex-foreground').checked;api.action('foreground',taskWasForeground);api.action('event','notify');}
  }
  const contexts=['walker','hero-sprite','mini-sprite'].map(id=>$(id).getContext('2d'));
  function paint(ctx,commands){
    ctx.setTransform(1,0,0,1,0,0);ctx.clearRect(0,0,ctx.canvas.width,ctx.canvas.height);
    for(const [op,...a] of commands){switch(op){case 'save':ctx.save();break;case 'restore':ctx.restore();break;case 'transform':ctx.setTransform(...a.map(v=>v*2));break;case 'translate':ctx.translate(...a);break;case 'scale':ctx.scale(...a);break;case 'rotate':ctx.rotate(...a);break;case 'begin':ctx.beginPath();break;case 'rect':ctx.rect(...a);break;case 'fillRect':ctx.fillRect(...a);break;case 'fill':ctx.fill();break;case 'clip':ctx.clip();break;case 'color':ctx.fillStyle=a[0];break;case 'alpha':ctx.globalAlpha=a[0];break;}}
  }
  function pocketPath(width){if(width<.01)return '';const l=NX-width,r=NX+19.5;return `M${r} 20V52H${l+13}C${l+8.02944} 52,${l+4} 47.9706,${l+4} 43V24C${l+4} 21.79086,${l+2.20914} 20,${l} 20H${r}Z`;}
  function frame(now){
    const dt=paused||document.hidden?0:Math.min((now-last)/1000,.1);last=now;notch.tick(dt);tickTask(dt);
    if(pendingMood&&!paused&&!notch.busy&&!notch.auto&&api.action('preview',pendingMood.id))pendingMood=null;
    const {state:s,commands}=api.frame(dt,selected);contexts.forEach(ctx=>paint(ctx,commands));render(s);
    for(const [position,window,pocket,canvas] of [['pet-position','capture-pet-window','capture-pocket','walker'],['hero-position','hero-window','hero-pocket','hero-sprite'],['mini-position','mini-window','mini-pocket','mini-sprite']]){
      $(position).setAttribute('x',s.x);$(position).setAttribute('opacity',s.opacity);$(window).setAttribute('x',NX-s.width);$(window).setAttribute('width',s.width>.01?s.width+19.5:0);$(pocket).setAttribute('d',pocketPath(s.width));$(pocket).setAttribute('opacity',s.backdrop?1:0);$(canvas).tabIndex=s.opacity>.5?0:-1;
    }
    if(recordCount!==notch.records.length){recordCount=notch.records.length;text('capture-count',String(recordCount));text('saved-text',notch.records.at(-1)||'等一个闪过的想法。');}
    const busy=notch.busy||notch.auto||s.reserved||s.event!==null||s.queued.receive||s.queued.notify||taskTime!==null;
    $('demo-capture').disabled=busy;$('demo-notify').disabled=busy;
    moodButtons.forEach(b=>{b.setAttribute('aria-pressed',String(b.dataset.mood===s.mood));b.dataset.pending=String(b.dataset.mood===pendingMood?.id);});
    Object.assign(svg.dataset,{notchPhase:notch.phase,petMood:s.mood,petPhase:s.phase,petEvent:s.event||'',recordCount:String(recordCount),paused:String(paused)});
    const name=art.presets.find(p=>p.id===selected).name, model=art.states.find(m=>m.id===s.mood);
    text('touch-hint',s.resident?'点一下，看看它的回应':'点一下，让它先回刘海歇歇');
    text('pose-title',s.opacity<.01?name+'在刘海里':model?.title||'等你来');text('pose-detail',s.opacity<.01?'点一下右边的动作，让它出来走走。':descriptions[s.mood]||descriptions.idle);
    text('status',pendingMood?'等它收好手里的事情，再看看「'+pendingMood.label+'」。':s.event==='receive'?'小伙伴正在接住灵感，收好后再朝你挥挥手。':s.event==='notify'?'Codex 忙完了，小伙伴举起纸条来告诉你。':s.source==='touch'?name+'注意到你啦。':name+' · '+(s.resident?'安静陪着你。':'偶尔出来走走，再回刘海里歇着。'));
    const captions={approach:'把这段想法带到刘海旁。',hover:'松手即可收录；拖离刘海就取消。',ack:'收到，正在收录这段文字。',absorb:'文字收回刘海，想法留下来了。',glow:'收好了，刘海亮一下回应你。',flash:'这点灵感，小伙伴也收到啦。'};
    text('capture-status',captions[notch.phase]||(s.event==='receive'?'收好了，小伙伴正在接住这点灵感。':recordCount?'已经留住 '+recordCount+' 条灵感，可以再试一条。':'把文字拖到顶部刘海本体，我接着。'));
    text('codex-status',taskTime!==null?'Codex 正在工作，小伙伴安静等着。':s.event==='notify'?'任务完成，纸条送到啦。':taskFinished?taskWasForeground?'你正在查看 Codex，这次不额外提醒。':'提醒已送到，继续忙你的吧。':'后台有结果时提醒，前台不打扰。');
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
})();
