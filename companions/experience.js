/* Website scenarios use the same character player and notch timeline as the app. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id), art = CompanionArt, api = NativeCompanion;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)'), mobile = matchMedia('(max-width:620px)');
  const clamp = (v, a=0, b=1) => Math.max(a, Math.min(b, v)), mix = (a,b,t) => a+(b-a)*t;
  const smooth = t => {t=clamp(t);return t*t*(3-2*t);};
  const progress = (t,a,b) => smooth((t-a)/(b-a)), easeOut = t => 1-Math.pow(1-clamp(t),3);
  let selected='chuichui', feature='company', paused=false, open=false, pendingMood=null;
  let last=performance.now(), recordCount=0, taskTime=null, taskFinished=false, taskWasForeground=false, restoreNotchFocus=false;
  api.init({resident:true, backdrop:false, frequency:50, reduced:reduced.matches});
  // Bridge the existing capture timeline to the native player's public commands.
  const pet = {
    get reduced(){return reduced.matches;}, get appOpen(){return open;},
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
  function say(text){if($('status').textContent!==text)$('status').textContent=text;}
  function resume(){paused=false;updatePause();last=performance.now();}
  function revealStage(){const r=$('desktop').getBoundingClientRect();if(r.top<24||r.bottom>innerHeight-24)$('desktop').scrollIntoView({behavior:reduced.matches?'instant':'smooth',block:'center'});}
  function updatePause(){$('pause').textContent=paused?'继续动画':'暂停动画';$('pause').setAttribute('aria-pressed',String(paused));}
  $('pause').onclick=()=>{paused=!paused;updatePause();};
  reduced.addEventListener('change',()=>api.action('reduced',reduced.matches));
  function fit(){svg.setAttribute('viewBox',mobile.matches?'575 10 360 170':'505 10 500 125');$('mock-panel').setAttribute('height',mobile.matches?'108':'78');}
  mobile.addEventListener('change',fit);fit();
  function setPanel(value){
    if(value===open)return;
    const pending=value&&(notch.busy||api.state().reserved);
    if(value){notch.cancel(true);pendingMood=null;}
    open=value;api.action('panel',value);if(pending)api.action('event','receive');
    $('notch').setAttribute('aria-expanded',String(value));
    $('mock-panel').setAttribute('aria-hidden',String(!value));
    if(value){$('mock-panel').style.display='block';$('close-panel').focus({preventScroll:true});}
    else {restoreNotchFocus=true;if($('mock-panel').contains(document.activeElement))$('notch').focus({preventScroll:true});}
  }
  function togglePanel(){resume();setPanel(!open);}
  $('notch').onclick=togglePanel;
  $('notch').onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();togglePanel();}};
  $('close-panel').onclick=()=>{resume();setPanel(false);};
  $('show-library').onclick=()=>{resume();setPanel(true);revealStage();};
  document.addEventListener('keydown',e=>{if(e.key==='Escape'&&open){setPanel(false);$('notch').focus();}});
  $('backdrop').onclick=()=>{
    const night=$('desktop').classList.toggle('night');
    $('screen-wallpaper').setAttribute('fill',night?'url(#night-wallpaper)':'url(#wallpaper)');
    $('backdrop').textContent=night?'切换浅色壁纸':'切换深色壁纸';$('backdrop').setAttribute('aria-pressed',String(night));
  };
  const tabs=[...document.querySelectorAll('[data-feature]')];
  function selectFeature(id){
    feature=id;tabs.forEach(t=>{const active=t.dataset.feature===id;t.setAttribute('aria-selected',String(active));t.tabIndex=active?0:-1;$(t.getAttribute('aria-controls')).hidden=!active;});
    const hints={company:'点点刘海左边的小伙伴，它会回应你。',capture:'把下方的文字拖到刘海本体，出现提示后松手。',codex:'模拟一次任务完成，看看它怎样把消息递给你。'};
    $('stage-hint').textContent=hints[id];
  }
  tabs.forEach((t,i)=>{t.onclick=()=>selectFeature(t.dataset.feature);t.onkeydown=e=>{let n=i;if(e.key==='ArrowRight')n=(i+1)%tabs.length;else if(e.key==='ArrowLeft')n=(i+tabs.length-1)%tabs.length;else if(e.key==='Home')n=0;else if(e.key==='End')n=tabs.length-1;else return;e.preventDefault();selectFeature(tabs[n].dataset.feature);tabs[n].focus();};});
  const characterButtons=[];
  for(const preset of art.presets){
    const b=document.createElement('button'), c=document.createElement('canvas'), name=document.createElement('span');
    c.width=160;c.height=128;c.setAttribute('aria-hidden','true');
    art.draw(c,preset.id,art.poseAt(preset.id,'idle',0,true),0,{x:0,y:0},0,true);
    name.textContent=preset.name;b.type='button';b.append(c,name);b.setAttribute('aria-label','选择'+preset.name);b.setAttribute('aria-pressed',String(preset.id===selected));
    b.onclick=()=>{selected=preset.id;characterButtons.forEach(item=>item.setAttribute('aria-pressed',String(item===b)));resume();};
    $('characters').append(b);characterButtons.push(b);
  }
  const moodButtons=[];
  for(const mood of art.states.filter(s=>!['receive','notify'].includes(s.id))){
    const b=document.createElement('button');b.type='button';b.textContent=mood.label;b.dataset.mood=mood.id;b.setAttribute('aria-pressed','false');
    b.onclick=()=>{resume();setPanel(false);pendingMood=mood;revealStage();};$('moods').append(b);moodButtons.push(b);
  }
  function touch(){resume();api.action('interact');}
  $('walker').onclick=touch;$('walker').onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();touch();}};
  function playCapture(){
    const text=source.value.trim();if(!text){source.setCustomValidity('先写一句想留下的话，再试一次。');source.reportValidity();source.focus();return;}
    resume();setPanel(false);pendingMood=null;revealStage();notch.play(text.slice(0,2000));
  }
  source.addEventListener('input',()=>source.setCustomValidity(''));
  $('demo-capture').onclick=playCapture;
  $('capture-drag-handle').onclick=playCapture;
  $('capture-drag-handle').ondragstart=e=>{
    const text=source.value.trim();if(!text){e.preventDefault();source.focus();return;}
    resume();setPanel(false);e.dataTransfer.setData('text/plain',text.slice(0,2000));e.dataTransfer.effectAllowed='copy';
    const ghost=$('capture-drag-ghost');ghost.textContent=text.length>20?text.slice(0,20)+'…':text;e.dataTransfer.setDragImage(ghost,-14,-20);
  };
  const pointFromClient=(x,y)=>{const p=svg.createSVGPoint();p.x=x;p.y=y;return p.matrixTransform(svg.getScreenCTM().inverse());};
  const hasText=e=>Array.from(e.dataTransfer?.types||[]).includes('text/plain');
  const inside=p=>p.x>=NX&&p.x<=NX+NW&&p.y>=NY&&p.y<=NY+NH;
  function over(e){
    if(!hasText(e))return;e.preventDefault();const hit=!open&&inside(pointFromClient(e.clientX,e.clientY));
    e.dataTransfer.dropEffect=hit?'copy':'none';if(hit){resume();notch.hover();}else notch.leave();
  }
  svg.addEventListener('dragenter',over);svg.addEventListener('dragover',over);
  svg.addEventListener('dragleave',e=>{if(!svg.contains(e.relatedTarget))notch.leave();});
  svg.addEventListener('drop',e=>{
    if(!hasText(e))return;e.preventDefault();e.stopPropagation();const point=pointFromClient(e.clientX,e.clientY);
    if(!open&&inside(point)){pendingMood=null;resume();notch.accept(e.dataTransfer.getData('text/plain').slice(0,2000),point);}else notch.leave();
  });
  document.addEventListener('dragend',()=>notch.leave());
  document.addEventListener('drop',()=>notch.leave());
  // A bounded, local mock task demonstrates both foreground and background behavior.
  $('demo-notify').onclick=()=>{resume();setPanel(false);pendingMood=null;revealStage();taskTime=0;taskFinished=false;$('task-state').textContent=$('codex-foreground').checked?'正在前台工作':'正在后台工作';$('task-progress').style.width='0%';$('demo-notify').disabled=true;$('task-detail').textContent='正在整理今天的灵感…';};
  $('codex-foreground').onchange=()=>api.action('foreground',$('codex-foreground').checked);
  function tickTask(dt){
    if(taskTime===null)return;taskTime+=dt;$('task-progress').style.width=clamp(taskTime/2.4)*100+'%';
    if(taskTime>=2.4){
      taskTime=null;taskFinished=true;taskWasForeground=$('codex-foreground').checked;$('task-state').textContent='已完成';$('task-detail').textContent='摘要已整理好，共归纳出三个主题。';
      api.action('foreground',$('codex-foreground').checked);api.action('event','notify');
    }else $('task-state').textContent=$('codex-foreground').checked?'正在前台工作':'正在后台工作';
  }
  function updateRecords(){
    if(recordCount===notch.records.length)return;recordCount=notch.records.length;
    $('capture-count').textContent=String(recordCount);$('empty-library').hidden=recordCount>0;
    const items=notch.records.slice(-10).reverse().map(text=>{const li=document.createElement('li');li.textContent=text;return li;});
    $('demo-library').replaceChildren(...items);
  }
  function statusFor(s){
    if(open)return '灵感库打开了，小伙伴先回刘海里，让你安心查看。';
    const capture={approach:'把这段想法带到刘海旁。',hover:'松手即可收录；拖离刘海就取消。',ack:'收到，正在收录这段文字。',absorb:'文字收回刘海，想法留下来了。',glow:'收好了，刘海亮一下回应你。',flash:'这点灵感，小伙伴也收到啦。'};
    if(capture[notch.phase])return capture[notch.phase];
    if(pendingMood)return '等它收好手里的事情，再看看「'+pendingMood.label+'」。';
    if(s.event==='receive')return '灵感已留下，小伙伴正在接住、收好，再朝你挥挥手。';
    if(s.event==='notify')return 'Codex 忙完了，小伙伴举起纸条来告诉你。';
    if(feature==='codex'){
      if(taskTime!==null)return 'Codex 还在工作，小伙伴安静陪着你。';
      if(taskFinished)return taskWasForeground?'你正在查看 Codex，这次完成就不再额外提醒。':'消息已经送到，你可以继续手头的事情。';
      return '点击「模拟任务完成」，体验一次后台提醒。';
    }
    if(feature==='capture')return recordCount?'已经留住 '+recordCount+' 条灵感。点击刘海，就能查看。':'拖一段文字到上方刘海，也可以点击按钮播放完整过程。';
    const name=art.presets.find(p=>p.id===selected).name;
    if(s.source==='touch')return name+'注意到你啦。';
    if(s.mood==='sleep')return name+'先眯一会儿，Zzz…';
    if(s.mood==='tired')return name+'累趴了，让它缓一缓。';
    if(s.mood!=='idle')return name+'的「'+(art.states.find(m=>m.id===s.mood)?.label||'小动作')+'」。';
    return name+'在这里，陪你慢慢想。';
  }
  const canvas=$('walker'), ctx=canvas.getContext('2d');
  function paint(commands){
    ctx.setTransform(1,0,0,1,0,0);ctx.clearRect(0,0,canvas.width,canvas.height);
    for(const [op,...a] of commands){switch(op){
      case 'save':ctx.save();break;case 'restore':ctx.restore();break;
      case 'transform':ctx.setTransform(...a.map(v=>v*2));break;
      case 'translate':ctx.translate(...a);break;case 'scale':ctx.scale(...a);break;case 'rotate':ctx.rotate(...a);break;
      case 'begin':ctx.beginPath();break;case 'rect':ctx.rect(...a);break;case 'fillRect':ctx.fillRect(...a);break;
      case 'fill':ctx.fill();break;case 'clip':ctx.clip();break;case 'color':ctx.fillStyle=a[0];break;case 'alpha':ctx.globalAlpha=a[0];break;
    }}
  }
  function frame(now){
    const dt=paused||document.hidden?0:Math.min((now-last)/1000,.1);last=now;
    notch.tick(dt);tickTask(dt);
    if(pendingMood&&!open&&!paused&&!notch.busy&&!notch.auto&&api.action('preview',pendingMood.id))pendingMood=null;
    const {state:s,commands}=api.frame(dt,selected);paint(commands);render(s);updateRecords();
    $('pet-position').setAttribute('x',s.x);$('pet-position').setAttribute('opacity',s.opacity);
    $('capture-pet-window').setAttribute('x',NX-s.width);$('capture-pet-window').setAttribute('width',s.width>.01?s.width+19.5:0);
    canvas.tabIndex=s.opacity>.5&&!open?0:-1;
    $('mock-panel').style.opacity=String(s.appProgress);
    $('mock-panel').style.pointerEvents=open?'auto':'none';
    if(!open&&s.appProgress<.001&&restoreNotchFocus){$('mock-panel').style.display='none';restoreNotchFocus=false;}
    $('stage-hint').hidden=open||notch.phase!=='idle';
    const busy=notch.busy||notch.auto||s.reserved||s.event!==null||s.queued.receive||s.queued.notify||taskTime!==null;
    $('demo-capture').disabled=busy;$('demo-notify').disabled=busy;
    moodButtons.forEach(b=>{b.setAttribute('aria-pressed',String(b.dataset.mood===s.mood));b.dataset.pending=String(b.dataset.mood===pendingMood?.id);});
    Object.assign(svg.dataset,{notchPhase:notch.phase,petMood:s.mood,petPhase:s.phase,petEvent:s.event||'',recordCount:String(recordCount),paused:String(paused)});
    say(statusFor(s));requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
})();
