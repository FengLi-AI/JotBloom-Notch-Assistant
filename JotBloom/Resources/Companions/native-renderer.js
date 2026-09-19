// Original six-character art, pose templates, and local interpolation. MIT licensed.
(()=>{
  const TAU=Math.PI*2, clamp=(v,a=0,b=1)=>Math.max(a,Math.min(b,v)), mix=(a,b,t)=>a+(b-a)*t;
  const smooth=t=>{t=clamp(t);return t*t*(3-2*t);};
  const progress=(t,a,b)=>smooth((t-a)/(b-a));
  const easeOut=t=>1-Math.pow(1-clamp(t),3);
  const originalArt={
  "chuichui": {
    "colors": {
      "B": "#fff0da",
      "A": "#e8b8ad",
      "D": "#423d3d"
    },
    "pixels": [
      "....................",
      "....BBB.............",
      "....BAB.............",
      "....BAB.....BBB.....",
      "....BAB....BABB.....",
      "....BBB....BBB......",
      ".....BBBBBBBBB......",
      "....BBBBBBBBBBB.....",
      "....BBBBBBBBBBBB....",
      "....BBDBBBBDBBBB....",
      "....BBDBBBBDBBBB....",
      "....BABBBDBBBABB....",
      ".....BBBBBBBBBB.....",
      "......BBBBBBBB......",
      "......BBB..BBB......",
      "...................."
    ]
  },
  "yuntuan": {
    "colors": {
      "B": "#d8eafa",
      "A": "#a9c7e5",
      "D": "#354854"
    },
    "pixels": [
      "....................",
      "....................",
      "....................",
      "......BBB...BB......",
      ".....BBBBB.BBBB.....",
      "....BBBBBBBBBBBB....",
      "...BBBBBBBBBBBBBB...",
      "..BBBBBBBBBBBBBBB...",
      "..BBBDBBBBDBBBBBB...",
      "..BBBDBBBBDBBBBBB...",
      "..BBABBBDBBBBBABB...",
      "...BBBBBBBBBBBBB....",
      "....BBB.BBBBBB......",
      "....................",
      "....................",
      "...................."
    ]
  },
  "dujiao": {
    "colors": {
      "B": "#f5b8aa",
      "A": "#ffe4b5",
      "D": "#453338"
    },
    "pixels": [
      "....................",
      "....................",
      ".....AA.............",
      "....AAA.....AA......",
      ".....BB.....BAA.....",
      "....BBBBBBBBBB......",
      "...BBBBBBBBBBBB.....",
      "...BBBBBBBBBBBBB....",
      "...BBBDBBBBDBBBB....",
      "...BBBDBBBBDBBBB....",
      "...BABBBBDBBBBAB....",
      "....BBBBBBBBBBBB....",
      "....BBBBBBBBBBB.....",
      ".....BBB...BBB......",
      "....................",
      "...................."
    ]
  }
};
  const presets=[
  {
    "id": "chuichui",
    "name": "垂垂",
    "note": "一只耳朵先下班",
    "personality": "耳朵各忙各的，其实一直在听。",
    "details": {
      "idle": "安静地等一会儿，轻轻呼吸、眨眨眼。",
      "curious": "先探过去，再歪头看一眼，小手也抬起来。",
      "sleep": "身体先落下来，两只耳朵再各自折好。",
      "energetic": "先蹲一下，再跳起来，落地时缓一缓。",
      "tired": "累到趴平，头顶亮起红色 ERROR，先歇一会儿。",
      "satisfied": "开心地晃一晃，笑着收好这个想法。",
      "notify": "举起小纸条，挥挥手，等你注意到。"
    }
  },
  {
    "id": "yuntuan",
    "name": "云团",
    "note": "一朵有点偏心的云",
    "personality": "飘得慢慢的，想法都接得稳稳的。",
    "details": {
      "idle": "安静地等一会儿，轻轻呼吸、眨眨眼。",
      "curious": "先探过去，再歪头看一眼，小手也抬起来。",
      "sleep": "云团落成小枕头，眼睛闭上，Z 慢慢飘走。",
      "energetic": "先蹲一下，再跳起来，落地时缓一缓。",
      "tired": "累到趴平，头顶亮起红色 ERROR，先歇一会儿。",
      "satisfied": "开心地晃一晃，笑着收好这个想法。",
      "notify": "举起小纸条，挥挥手，等你注意到。"
    }
  },
  {
    "id": "dujiao",
    "name": "嘟角",
    "note": "矮一点，也皮一点",
    "personality": "头顶压低一格，淘气的小软角还在。",
    "details": {
      "idle": "安静地等一会儿，轻轻呼吸、眨眨眼。",
      "curious": "先探过去，再歪头看一眼，小手也抬起来。",
      "sleep": "身体慢慢趴下，小软角晚半拍倒向两边。",
      "energetic": "先蹲一下，再跳起来，落地时缓一缓。",
      "tired": "累到趴平，头顶亮起红色 ERROR，先歇一会儿。",
      "satisfied": "开心地晃一晃，笑着收好这个想法。",
      "notify": "举起小纸条，挥挥手，等你注意到。"
    }
  }
];
  const presetModels=Object.fromEntries(presets.map(p=>[p.id,p]));
  const states=[
    {id:'idle',label:'常态',en:'IDLE',title:'等你来',duration:5.6},
    {id:'curious',label:'好奇',en:'CURIOUS',title:'那是什么？',duration:6.4},
    {id:'sleep',label:'打盹',en:'SLEEPY',title:'先眯一会儿',duration:8},
    {id:'energetic',label:'精神好',en:'AWAKE',title:'今天状态不错',duration:6.2},
    {id:'tired',label:'累趴了',en:'TIRED',title:'让我瘫一下',duration:5.6},
    {id:'receive',label:'接灵感',en:'RECEIVE',title:'交给我吧',duration:6.6},
    {id:'satisfied',label:'满足',en:'HAPPY',title:'又收获一个想法',duration:5.4},
    {id:'notify',label:'递纸条',en:'RESULT',title:'Codex 有新结果',duration:6.2}
  ];
  const models=Object.fromEntries(states.map(s=>[s.id,s]));
  const rigSpec={
    chuichui:{featureCut:6,feetY:14,eyes:[6,11,9,2],mouth:[9,11],roots:[[5,6],[12,6]],hands:[[4,11],[16,11]],
      sleep:[[7,11,9],[5,13,10],[4,14,11],[4,14,12],[5,13,13],[6,12,14]],tired:[[7,11,11],[5,14,12],[3,15,13],[4,14,14]],closed:[7,12,12],tiredEyes:[7,12,13]},
    yuntuan:{featureCut:0,feetY:16,eyes:[5,10,8,2],mouth:[8,10],roots:[[6,3],[12,3]],hands:[[2,10],[17,10]],
      sleep:[[7,10,8],[6,11,9],[4,14,10],[3,16,11],[2,17,12],[3,16,13],[5,14,14]],tired:[[6,10,11],[4,14,12],[2,17,13],[3,16,14]],closed:[6,12,12],tiredEyes:[6,12,13]},
    dujiao:{featureCut:5,feetY:13,eyes:[6,11,8,2],mouth:[9,10],roots:[[6,5],[13,5]],hands:[[3,10],[16,10]],
      sleep:[[7,11,9],[5,13,10],[4,15,11],[4,15,12],[5,14,13],[6,13,14]],tired:[[6,12,11],[4,14,12],[3,16,13],[4,15,14]],closed:[7,12,12],tiredEyes:[7,12,13]}
  };
  function makeRig(id){
    const art=originalArt[id],spec=rigSpec[id],rig={...spec,colors:art.colors,body:[],features:[[],[]],feet:[],cheeks:[]};
    art.pixels.forEach((row,y)=>[...row].forEach((color,x)=>{
      if(color==='.')return;
      if(y<spec.featureCut){rig.features[x<10?0:1].push([x,y,color]);return;}
      if(y>=spec.feetY){rig.feet.push([x,y,color]);return;}
      rig.body.push([x,y,'B']);if(color==='A')rig.cheeks.push([x,y,color]);
    }));
    rig.bands=[];
    for(let y=0;y<16;y++){
      const xs=rig.body.filter(c=>c[1]===y).map(c=>c[0]).sort((a,b)=>a-b);if(!xs.length)continue;
      const runs=[];let start=xs[0],last=start;
      for(const x of xs.slice(1)){if(x>last+1){runs.push([start,last+1]);start=x;}last=x;}runs.push([start,last+1]);
      rig.bands.push({y,runs});
    }
    return rig;
  }

const darkVariants={"momo": {"name": "墨墨", "letter": "A", "kind": "尖耳小猫", "note": "尖耳、短脚，身后一条小尾巴。", "art": {"colors": {"B": "#434B60", "A": "#AD96AF", "D": "#F5E7B5"}, "pixels": ["....................", "....................", "....B.........B.....", "....BAB.....BAB.....", "....BBBB...BBBB.....", ".....BBBBBBBBBB.....", "....BBBBBBBBBBBB....", "....BBBBBBBBBBBB....", "...BBBDBBBBDBBBB....", "...BBBDBBBBDBBBB....", "...BBABBBDBBBABB....", "....BBBBBBBBBBB.....", ".....BBBBBBBBB......", ".....BBBB..BBB......", ".....BBB...BBB......", "...................."]}}, "lili": {"name": "栗栗", "letter": "B", "kind": "圆耳小熊", "note": "圆耳、宽肚子，动作慢半拍。", "art": {"colors": {"B": "#59454C", "A": "#B98F91", "D": "#FFE6BA"}, "pixels": ["....................", "....................", ".....BB.....BB......", "....BAAB...BAAB.....", "....BBBB...BBBB.....", ".....BBBBBBBBBB.....", "....BBBBBBBBBBBB....", "....BBBBBBBBBBBB....", "....BBDBBBBBDBBB....", "....BBDBBBBBDBBB....", "....BABBBDBBBBAB....", "....BBBBBBBBBBBB....", ".....BBBBBBBBBB.....", ".....BBBB..BBBB.....", "......BBB..BBB......", "...................."]}}, "mumu": {"name": "暮暮", "letter": "C", "kind": "小蝙蝠", "note": "高耳、小身体，两侧翅膀会收拢。", "art": {"colors": {"B": "#514768", "A": "#AC9AC5", "D": "#EDE7FF"}, "pixels": ["....................", "......B......B......", "......BB....BB......", "......BAB..BAB......", ".......BB..BB.......", ".......BBBBBB.......", "......BBBBBBBB......", "......BBBBBBBB......", "......BDBBBDBB......", "......BDBBBDBB......", "......ABBDBBBA......", ".......BBBBBB.......", ".......BBBBBB.......", ".......BB..BB.......", "....................", "...................."]}}};
for(const [id,v] of Object.entries(darkVariants)){originalArt[id]=v.art;presets.push({id,name:v.name});rigSpec[id]={featureCut:5,feetY:id==="mumu"?13:13,eyes:id==="lili"?[6,12,8,2]:id==="mumu"?[7,11,8,2]:[6,11,8,2],mouth:[9,10],roots:id==="mumu"?[[7,5],[12,5]]:[[6,5],[13,5]],hands:id==="mumu"?[[6,9],[14,9]]:[[4,10],[15,10]],sleep:[[7,12,10],[5,14,11],[4,15,12],[5,14,13],[6,13,14]],tired:[[7,12,11],[5,14,12],[3,16,13],[4,15,14]],closed:id==="mumu"?[7,11,12]:[6,12,12],tiredEyes:[6,12,13]};}
  for(const item of presets) presetModels[item.id]=item;
  const rigs=Object.fromEntries(presets.map(p=>[p.id,makeRig(p.id)]));

const canvasInfo=new WeakMap();
  function basePoseAt(id,mode,t,still=false){
    const r=rigs[id],cloud=id==='yuntuan',bunny=id==='chuichui',clock=still?0:t,b=Math.sin(clock*TAU/4.8);
    const p={x:0,y:cloud?-.24*Math.sin(clock*TAU/5.8):0,rot:0,sx:1,sy:1+.012*b,
      sleep:0,tired:0,full:0,closed:0,happy:0,gaze:.24,lookX:0,lookY:0,
      eyeL:r.eyes[0],eyeR:r.eyes[1],eyeY:r.eyes[2],cheekY:0,mouthAlpha:r.mouth?1:0,
      featureY:0,featureLX:0,featureRX:0,featureL:.025*Math.sin(clock*1.4),featureR:.03*Math.sin(clock*1.3),
      footY:0,arms:0,handLX:0,handRX:0,handY:0,armL:0,armR:0,
      paperAlpha:0,paperX:16,paperY:5,paperRot:0,paperFold:0,cakeAlpha:0,cakeX:8,cakeY:11,bite:0,sparkle:0};
    if(mode==='curious'){
      const scan=still?-1:Math.sin(clock*TAU/6.4-Math.PI/2);
      p.x=.6*scan;p.rot=.045*scan;p.sy=1;p.y=-.22;
      p.lookX=.65*scan;p.lookY=-.35;p.gaze=.7;p.arms=1;
      p.armL=1.65+.1*Math.sin(clock*2);p.armR=-.08;p.handY=-.4;
      if(cloud){p.handLX=1.2;p.handRX=-.3;}
      p.featureL=-.1+.03*scan;p.featureR=bunny?-.4:.24;
    }else if(mode==='sleep'||mode==='tired'){
      const sleeping=mode==='sleep',settle=still?1:progress(t,.05,1.15),droop=still?1:progress(t,.45,1.55);
      p.sleep=sleeping?settle:0;p.tired=sleeping?0:settle;p.sy=1+.009*Math.sin(clock*TAU/5.3);p.y=0;
      p.closed=still?1:progress(t,.3,1.1);p.gaze=0;p.mouthAlpha=(r.mouth?1:0)*(1-settle);
      const e=sleeping?r.closed:r.tiredEyes;
      p.eyeL=mix(r.eyes[0],e[0],settle);p.eyeR=mix(r.eyes[1],e[1],settle);p.eyeY=mix(r.eyes[2],e[2],settle);
      p.cheekY=(e[2]-r.eyes[2]-1)*settle;
      p.featureY=((sleeping?r.sleep[0][2]:r.tired[0][2])-r.bands[0].y)*settle;
      p.featureL=-Math.PI/2*droop;
      p.featureR=Math.PI/2*droop;p.featureLX=(bunny?2:0)*droop;
      p.arms=settle;
      p.handLX=(cloud?1:0)*settle;p.handRX=(bunny?-1:0)*settle;p.handY=(12-r.hands[0][1])*settle;
      p.armL=-.06*Math.sin(clock*1.3);p.armR=.06*Math.sin(clock*1.3);
    }else if(mode==='energetic'){
      const phase=still?.9:t%3.2;let air=0,squash=0;
      if(phase<.48)squash=.19*Math.pow(Math.sin(phase/.48*Math.PI),2);
      else if(phase<1.48)air=Math.pow(Math.sin((phase-.48)*Math.PI),2);
      else if(phase<2.05)squash=.14*Math.pow(Math.sin((phase-1.48)/.57*Math.PI),2);
      p.sy=1-squash;p.sx=1+(cloud?.16:.3)*squash;
      p.y=-(bunny?.8:cloud?2:1.55)*air;p.gaze=.15;
      p.arms=1;p.armL=2.2*air;p.armR=-2.2*air;
      if(cloud){p.handLX=.8;p.handRX=-.8;}
      const after=phase>1.48?Math.sin((phase-1.48)*13)*Math.exp(-(phase-1.48)*4):0;
      p.featureL=-.11*air+.12*after;p.featureR=.22*air-.17*after;
      p.sparkle=cloud?air:0;
    }else if(mode==='satisfied'){
      p.full=1;p.happy=1;p.gaze=0;p.y=-.12*Math.sin(clock*2);p.sy=1+.015*b;
      p.featureL=-.05+.07*Math.sin(clock*2);p.featureR=.12*Math.sin(clock*2-.4);
    }else if(mode==='notify'){
      const a=still?1:progress(t,.15,1.2);p.arms=1;p.gaze=.35;p.armL=2.2+.35*Math.sin(clock*4);p.armR=-1;
      p.paperAlpha=a;p.paperX=mix(16.8,16,a);p.paperY=5+.16*Math.sin(clock*2);p.paperRot=.05*Math.sin(clock*2.2);
      p.featureL=.08*Math.sin(clock*2.2);p.featureR=-.1*Math.sin(clock*2.2-.3);
    }else if(mode==='receive'){
      const arrival=progress(t,0,1.1),fold=progress(t,1.1,1.65),lift=progress(t,1.5,2.65),content=progress(t,4,4.75);
      p.arms=1;p.armL=.85*arrival;p.armR=-.85*arrival;p.gaze=0;p.lookX=-.6*(1-fold);
      p.paperAlpha=1-fold;p.paperX=mix(-3,4,arrival);p.paperY=mix(6,10,arrival);p.paperRot=mix(-.2,0,arrival);p.paperFold=fold;
      p.cakeAlpha=fold*(1-progress(t,3.7,4));p.cakeY=mix(12,9.5,lift);p.bite=progress(t,2.7,3.8);
      const chewing=progress(t,2.5,2.8)*(1-progress(t,3.8,4.2)),chew=Math.sin(clock*TAU*2.2)*chewing;
      p.full=.4*chewing+.8*content;p.sy=1+.035*chew;p.eyeY+=.12*chew;p.closed=.5*chewing;
      p.happy=content;p.featureL=.04*chew;p.featureR=-.04*chew;
    }
    return p;
  }
  const blendPose=(a,b,f)=>Object.fromEntries(Object.keys(b).map(key=>[key,mix(a[key],b[key],f)]));
  function cells(ctx,data,colors){
    for(const key of new Set(data.map(cell=>cell[2]))){
      ctx.beginPath();for(const [x,y,color] of data)if(color===key)ctx.rect(x,y,1,1);
      ctx.fillStyle=colors[key]||key;ctx.fill();
    }
  }
  function part(ctx,x,y,angle,fn){ctx.save();ctx.translate(x,y);ctx.rotate(angle);fn();ctx.restore();}
  function flatBand(rows,i,n,j,count){
    const a=Math.round(i/n*rows.length),b=Math.round((i+1)/n*rows.length),row=rows[Math.min(a,rows.length-1)];
    const width=row[1]-row[0]+1;
    return [row[0]+width*j/count,rows[0][2]+a,width/count,b-a];
  }
  function drawBody(ctx,r,p){
    ctx.save();ctx.translate(10,14);ctx.scale(p.sx,p.sy);ctx.translate(-10,-14);ctx.fillStyle=r.colors.B;ctx.beginPath();
    r.bands.forEach((band,i)=>band.runs.forEach(([left,right],j)=>{
      const base=[left,band.y,right-left,1],a=flatBand(r.sleep,i,r.bands.length,j,band.runs.length),b=flatBand(r.tired,i,r.bands.length,j,band.runs.length);
      const rect=base.map((v,k)=>v+(a[k]-v)*p.sleep+(b[k]-v)*p.tired);
      if(p.full>0&&i>=r.bands.length-4&&i<r.bands.length-1){rect[0]-=p.full;rect[2]+=2*p.full;}
      if(rect[3]>0)ctx.rect(...rect);
    }));ctx.fill();ctx.restore();
  }
  const bodyY=(y,p)=>14+(y-14)*p.sy;
  function drawFeature(ctx,r,p,side){
    const [x,y]=r.roots[side],dx=side?p.featureRX:p.featureLX,angle=side?p.featureR:p.featureL;
    // Follow the changing body anchor, but preserve the feature's cell size.
    part(ctx,x+dx,bodyY(y+p.featureY,p),angle,()=>{ctx.translate(-x,-y);cells(ctx,r.features[side],r.colors);});
  }
  function drawHands(ctx,r,p){
    if(p.arms<=0)return;ctx.save();ctx.globalAlpha=p.arms;
    r.hands.forEach(([x,y],side)=>part(ctx,x+(side?p.handRX:p.handLX),bodyY(y+p.handY,p),side?p.armR:p.armL,()=>{
      ctx.fillStyle=r.colors.B;ctx.fillRect(side?0:-1,0,1,2);
    }));ctx.restore();
  }
  function drawFace(ctx,r,p,g,blink){
    const gx=g.x*p.gaze+p.lookX,gy=g.y*p.gaze*.55+p.lookY;
    const closed=clamp(Math.max(p.closed,blink)),happy=p.happy,eyeY=bodyY(p.eyeY,p)+gy;
    ctx.fillStyle=r.colors.D;
    for(const x of [p.eyeL,p.eyeR]){
      // Open, closed and smiling expressions are all made of the same 1 x 1 cells.
      // Only the temporary eyelid reveal and positions interpolate during motion.
      ctx.save();ctx.translate(x+gx,eyeY);
      if(happy<1){ctx.globalAlpha=1-happy;
        if(closed<1)ctx.fillRect(0,closed*(r.eyes[3]-1),1,Math.max(0,r.eyes[3]*(1-closed)));
        if(closed>0){ctx.globalAlpha=(1-happy)*closed;ctx.fillRect(0,0,2,1);}
      }
      if(happy>0){ctx.globalAlpha=happy;ctx.fillRect(-1,0,1,1);ctx.fillRect(0,-1,1,1);ctx.fillRect(1,0,1,1);}
      ctx.restore();
    }
    if(r.mouth&&p.mouthAlpha>0){ctx.save();ctx.globalAlpha=p.mouthAlpha;ctx.fillStyle=r.colors.D;ctx.fillRect(r.mouth[0]+gx*.3,bodyY(r.mouth[1],p)+gy*.3,1,1);ctx.restore();}
    for(const [x,y,color] of r.cheeks){ctx.fillStyle=r.colors[color];ctx.fillRect(x,bodyY(y+p.cheekY,p),1,1);}
  }
  function drawPaper(ctx,p){
    if(p.paperAlpha<=0)return;ctx.save();ctx.globalAlpha=p.paperAlpha;
    part(ctx,p.paperX+1.5,p.paperY+2,p.paperRot,()=>{ctx.translate(-1.5,-2);ctx.beginPath();ctx.rect(0,0,3*(1-p.paperFold),4);ctx.clip();
      cells(ctx,[[0,0,'P'],[1,0,'P'],[2,0,'P'],[0,1,'P'],[1,1,'I'],[2,1,'P'],[0,2,'P'],[1,2,'I'],[2,2,'P'],[0,3,'P'],[1,3,'P'],[2,3,'P']],{P:'#f3b746',I:'#805019'});
    });ctx.restore();
  }
  function drawCake(ctx,p){
    if(p.cakeAlpha<=0)return;ctx.save();ctx.globalAlpha=p.cakeAlpha;ctx.translate(p.cakeX,p.cakeY);
    ctx.beginPath();ctx.rect(0,-1,3*(1-.67*p.bite),4);ctx.clip();
    cells(ctx,[[1,-1,'R'],[0,0,'B'],[1,0,'B'],[2,0,'B'],[0,1,'A'],[1,1,'A'],[2,1,'A'],[0,2,'B'],[1,2,'B'],[2,2,'B']],{B:'#fff2d4',A:'#f4c980',R:'#ee9b89'});ctx.restore();
  }
  function drawSleep(ctx,p,t,still){
    if(p.sleep<=0)return;
    const z=[[0,0,'Z'],[1,0,'Z'],[2,0,'Z'],[1,1,'Z'],[0,2,'Z'],[1,2,'Z'],[2,2,'Z']];
    for(let i=0;i<3;i++){
      const age=(still?3.6:t)-1.6-i*1.5;if(age<0)continue;const u=(age%4.5)/4.5;
      const x=u<.33?mix(0,1,smooth(u/.33)):u<.68?mix(1,-.3,smooth((u-.33)/.35)):mix(-.3,.8,smooth((u-.68)/.32));
      const a=progress(u,0,.12)*(1-progress(u,.65,1)),s=mix(.3,.9,smooth(u));
      ctx.save();ctx.globalAlpha=a*p.sleep*.85;ctx.translate(14+x,9.7-6.8*smooth(u));ctx.scale(s,s);cells(ctx,z,{Z:'#b3c4bc'});ctx.restore();
    }
  }
  // Five-by-seven letterforms on a half-cell grid, centered above the character.
  const errorLetters={E:['11111','10000','10000','11110','10000','10000','11111'],R:['11110','10001','10001','11110','10100','10010','10001'],O:['01110','10001','10001','10001','10001','10001','01110']};
  const errorPixels=[...'ERROR'].flatMap((letter,index)=>errorLetters[letter].flatMap((row,y)=>[...row].flatMap((on,x)=>on==='1'?[[index*6+x,y,'R']]:[])));
  function drawError(ctx,p){
    const alpha=progress(p.tired,.65,1);if(alpha<=0)return;
    ctx.save();ctx.globalAlpha=alpha;ctx.translate(2.75,3.5+(1-alpha)*.5);ctx.scale(.5,.5);
    cells(ctx,errorPixels,{R:'#c52b34'});ctx.restore();
  }
  function draw(canvas,id,p,t,g={x:0,y:0},blink=0,still=false){
    const ctx=canvasInfo.get(canvas)||canvas.getContext('2d'),r=rigs[id];
    ctx.setTransform(1,0,0,1,0,0);ctx.clearRect(0,0,canvas.width,canvas.height);ctx.setTransform(canvas.width/20,0,0,canvas.height/16,0,0);
    ctx.save();ctx.translate(10+p.x,14+p.y);ctx.rotate(p.rot);ctx.translate(-10,-14);
    ctx.save();ctx.translate(0,p.footY);
    if(p.stride){
      for(let side=0;side<2;side++){ctx.save();ctx.translate(0,-Math.max(0,p.stride*(side?1:-1)));cells(ctx,r.feet.filter(cell=>(cell[0]<10?0:1)===side),r.colors);ctx.restore();}
    }else cells(ctx,r.feet,r.colors);
    ctx.restore();
    drawHands(ctx,r,p);drawBody(ctx,r,p);drawFeature(ctx,r,p,0);drawFeature(ctx,r,p,1);drawFace(ctx,r,p,g,blink);
    ctx.restore();drawPaper(ctx,p);drawCake(ctx,p);drawSleep(ctx,p,t,still);drawError(ctx,p);
    if(p.sparkle>0){ctx.save();ctx.globalAlpha=p.sparkle;cells(ctx,[[1,4,'A'],[0,5,'A'],[1,5,'A'],[2,5,'A'],[1,6,'A'],[18,3,'B']],r.colors);ctx.restore();}
    ctx.setTransform(1,0,0,1,0,0);
  }

const wingL=[[0,0],[1,-1],[1,0],[2,-2],[2,-1],[2,0],[2,1],[3,-1],[3,0],[3,1],[3,2]],wingR=wingL.map(([x,y])=>[-x,y]);
const baseHands=drawHands;
drawHands=function(ctx,r,p){if(r!==rigs.mumu){baseHands(ctx,r,p);return;}let folded=Math.max(p.sleep,p.tired);ctx.fillStyle=r.colors.B;for(let side=0;side<2;side++){part(ctx,side?14:6,bodyY(8+p.featureY,p),side?-p.armR*.22:p.armL*.22,()=>{ctx.scale(mix(1,.24,folded),mix(1,.8,folded));cells(ctx,(side?wingL:wingR).map(([x,y])=>[x,y,'B']),r.colors);});}};
const baseDraw=draw;
draw=function(canvas,id,p,t,g,blink,still){baseDraw(canvas,id,p,t,g,blink,still);if(id!=='momo')return;const ctx=canvas.getContext('2d');ctx.save();ctx.setTransform(canvas.width/20,0,0,canvas.height/16,0,0);ctx.translate(10+p.x,14+p.y);ctx.rotate(p.rot);ctx.translate(-10,-14);ctx.translate(14,12);ctx.rotate(-.1+.13*Math.sin((still?0:t)*1.7));ctx.fillStyle=rigs[id].colors.B;ctx.globalAlpha=1-Math.max(p.sleep,p.tired)*.8;ctx.fillRect(0,0,3,1);ctx.fillRect(2,-1,1,1);ctx.fillRect(3,-3,1,2);ctx.restore();};
function poseAt(id,mode,t,still){let p=basePoseAt(id,mode,t,still);if(id==='lili'){p.rot*=.7;p.featureL*=.45;p.featureR*=.45;const down=Math.max(p.sleep,p.tired);p.featureY+=down;p.featureLX+=down;p.featureRX-=down;}if(id==='mumu'){if(mode==='idle'){if(still)t=0;p.y=-.25-.18*Math.sin(t*2);p.arms=.4;p.armL=.35+.3*Math.sin(t*2);p.armR=-p.armL;}p.featureL*=.6;p.featureR*=.6;}return p;}

let activePreset="chuichui",reduce=false,poseToken=-1,posePreset="",sharedPose=null,poseFrom=null,blendStart=0,poseArtTime=0,lastPaintClock=0;
  function computePose(s){
    if(posePreset!==activePreset){posePreset=activePreset;poseToken=-1;sharedPose=null;poseFrom=null;}
    if(s.token!==poseToken){poseFrom=sharedPose?{...sharedPose}:null;poseToken=s.token;blendStart=s.clock;}
    if(s.kind==='freeze'&&poseFrom)return poseFrom;
    let p=poseAt(activePreset,s.mood,s.poseTime??(s.phase==='active'?s.elapsed:s.clock),reduce);p.stride=0;
    if(s.kind.startsWith('walk')||s.kind.startsWith('run')){
      p=poseAt(activePreset,'idle',s.clock,reduce);const running=s.kind.startsWith('run'),speed=running?6:3.1,w=reduce?0:Math.sin(s.elapsed*TAU*speed),dir=s.kind.endsWith('left')?-1:1;
      p.sy=1;p.gaze=0;p.lookX=dir*.38;if(running){p.rot=dir*.045;p.featureL-=.13;p.featureR+=.16;}p.y=-.18*Math.abs(w);p.stride=w*.48;p.arms=1;p.armL=(running?.7:.35)*w;p.armR=-(running?.7:.35)*w;
      p.featureL+=.13*Math.sin(s.elapsed*TAU*3.1-.45);p.featureR-=.12*Math.sin(s.elapsed*TAU*3.1-.7);
      if(activePreset==='yuntuan'){p.handLX=.4;p.handRX=-.4;p.y-=.14*Math.sin(s.elapsed*TAU*1.55);}
    }else if(s.kind==='wave'){
      p.arms=1;p.armL=2.4+(reduce?0:.4*Math.sin(s.elapsed*TAU*3));p.armR=-.4;if(activePreset==='yuntuan')p.handLX=.6;
    }else if(s.kind==='peek'){
      p.gaze=0;p.lookX=-.5;p.rot=-.065;p.featureL=-.1;p.featureR=.18;
    }else if(s.mood==='receive'&&!reduce){p.paperX=mix(15,4,progress(s.elapsed,0,1.1));p.paperRot=mix(.15,0,progress(s.elapsed,0,1.1));}
    // Personality lives in motion; all authored pixels retain their original cell size.
    if(!reduce&&s.kind==='idle'&&s.phase==='idle'){
      const beat=s.clock%17,pulse=progress(beat,10.8,11.1)*(1-progress(beat,11.35,12));
      if(activePreset==='chuichui'){p.featureR-=.22*pulse;p.lookY-=.16*pulse;}
      else if(activePreset==='yuntuan'){p.y-=.16*Math.sin(s.clock*1.1);p.lookX=.12*Math.sin(s.clock*.5);}
      else{p.featureL-=.15*pulse;p.featureR+=.12*pulse;p.rot+=.018*pulse;}
    }
    if(s.source==='touch'&&s.phase==='active'&&!reduce){
      const q=progress(s.elapsed,0,.35)*(1-progress(s.elapsed,1.35,2.15));
      if(s.touchVariant===0){p.arms=1;p.armL+=.75*q;p.happy=Math.max(p.happy,.55*q);}
      else if(s.touchVariant===1){p.rot-=.035*q;p.featureR+=.17*q;}
      else {p.lookY-=.35*q;p.featureL-=.16*q;}
    }
    if(s.restSettled)poseArtTime=s.poseTime;else if(s.phase==='active')poseArtTime=s.elapsed;else poseArtTime+=Math.max(0,s.clock-lastPaintClock);
    const blendDuration=s.phase==='waking'?s.duration:s.phase==='recover'?.5:s.kind.startsWith('run')?.1:s.kind.startsWith('walk')?.22:.38;
    if(poseFrom&&!reduce&&!s.restSettled){const a={...poseFrom,stride:poseFrom.stride||0};p=blendPose(a,{...p,stride:p.stride||0},smooth((s.clock-blendStart)/blendDuration));}
    if(!reduce&&s.touchAge>=0&&s.touchAge<.7){
      const q=progress(s.touchAge,0,.16)*(1-progress(s.touchAge,.3,.7));
      p.closed=Math.max(p.closed,.78*q);if(p.sleep<.1&&p.tired<.1)p.rot+=.024*q;
    }
    return p;
  }

globalThis.CompanionArt={presets,states,originalArt,poseAt,draw};
  // Commands are replayed by Core Graphics. No browser or WebView is involved.
  class Recorder {
    constructor(){this.commands=[];}
    save(){this.commands.push(['save']);} restore(){this.commands.push(['restore']);}
    setTransform(...args){this.commands.push(['transform',...args]);}
    translate(...args){this.commands.push(['translate',...args]);}
    scale(...args){this.commands.push(['scale',...args]);}
    rotate(...args){this.commands.push(['rotate',...args]);}
    beginPath(){this.commands.push(['begin']);}
    rect(...args){this.commands.push(['rect',...args]);}
    fillRect(...args){this.commands.push(['fillRect',...args]);}
    clearRect(){} fill(){this.commands.push(['fill']);} clip(){this.commands.push(['clip']);}
    set fillStyle(value){this.commands.push(['color',value]);}
    set globalAlpha(value){this.commands.push(['alpha',value]);}
  }
  let pet=null;
  function init(options){
    pet=new JotBloomCompanion.Companion(options);
    // Real desktop cadence is deliberately quieter than the accelerated HTML.
    pet.gap=function(){return this.resident?60+this.random()*60:mix(720,120,this.frequency/100)*(.8+this.random()*.4);};
    pet.nextIn=pet.gap();poseToken=-1;posePreset='';sharedPose=null;
  }
  function frame(dt,preset,gx=0,gy=0){
    activePreset=Object.hasOwn(originalArt,preset)?preset:'chuichui';reduce=pet.reduced;
    pet.tick(Math.max(0,Math.min(dt,.25)));
    const s=pet.snapshot(),p=computePose(s);sharedPose=p;lastPaintClock=s.clock;
    const ctx=new Recorder(),canvas={width:80,height:64,getContext:()=>ctx};
    const b=s.clock%5.3,blink=!reduce&&b<.22?Math.pow(Math.sin(b/.22*Math.PI),2):0;
    if(s.opacity>0)draw(canvas,activePreset,p,poseArtTime,{x:clamp(gx,-1,1),y:clamp(gy,-1,1)},blink,reduce);
    return {state:s,commands:ctx.commands};
  }
  function action(name,value){
    const methods={resident:'setResident',backdrop:'setBackdrop',frequency:'setFrequency',panel:'setAppOpen',preview:'preview',event:'requestEvent',foreground:'setForeground',interact:'interact',show:'show'};
    if(name==='reduced'){pet.reduced=!!value;return;}
    if(name==='reserve'){pet.reserveReceipt();return true;}
    if(name==='release'){pet.reserved=false;return true;}
    if(name==='hovering'){pet.hovering=!!value;return true;}
    const method=methods[name];if(method)return pet[method](value);
  }
  function thumbnail(preset,mood='idle'){
    const ctx=new Recorder(),canvas={width:80,height:64,getContext:()=>ctx};
    draw(canvas,preset,poseAt(preset,mood,3.6,true),3.6,{x:0,y:0},0,true);
    return ctx.commands;
  }
  globalThis.NativeCompanion={init,frame,action,thumbnail,state:()=>pet.snapshot()};
})();
