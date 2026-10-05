/* 581 v0.3.35: bounded, deterministic delivery helpers. No fetch or timer.
   Suspicious geometry is only a reason to ASK the same legal scooter router again;
   never replace a road path with a straight segment or bypass access restrictions. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;
if(root)root.DoorDelivery=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
'use strict';
const R=6371000, rad=Math.PI/180;
const clamp=(v,a,b)=>Math.max(a,Math.min(b,v));
const finite=v=>typeof v==='number'&&Number.isFinite(v);
function point(p){return p&&finite(p.lat)&&finite(p.lng)&&p.lat>=20&&p.lat<=27&&p.lng>=117&&p.lng<=123;}
function meters(a,b){const dlat=(b.lat-a.lat)*rad,dlon=(b.lng-a.lng)*rad;
 const h=Math.sin(dlat/2)**2+Math.cos(a.lat*rad)*Math.cos(b.lat*rad)*Math.sin(dlon/2)**2;
 return R*2*Math.atan2(Math.sqrt(h),Math.sqrt(Math.max(0,1-h)));}
function at(c){return {lng:c[0],lat:c[1]};}
function project(p,a,b){const sx=111320*Math.cos(p.lat*rad),sy=111320;
 const ax=(a[0]-p.lng)*sx,ay=(a[1]-p.lat)*sy,dx=(b[0]-a[0])*sx,dy=(b[1]-a[1])*sy;
 const vv=dx*dx+dy*dy,t=vv?clamp(-(ax*dx+ay*dy)/vv,0,1):0;
 return {distance:Math.hypot(ax+t*dx,ay+t*dy),t,coord:[a[0]+t*(b[0]-a[0]),a[1]+t*(b[1]-a[1])]};}
function closest(coords,p){let best=null,along=0;
 for(let i=1;i<coords.length;i++){const q=project(p,coords[i-1],coords[i]),len=meters(at(coords[i-1]),at(coords[i]));
  if(!best||q.distance<best.distance)best={...q,index:i-1,along:along+q.t*len};along+=len;}
 return best;}
function inspect(coords){
 if(!Array.isArray(coords)||coords.length<3)return {suspicious:false,reason:'',checked:0};
 // At most 256 points and 32 forward neighbours; no graph search on the phone.
 const step=Math.max(1,Math.ceil(coords.length/255));const c=coords.filter((_,i)=>i%step===0);
 if(c.at(-1)!==coords.at(-1))c.push(coords.at(-1));
 const d=[0];for(let i=1;i<c.length;i++)d.push(d[i-1]+meters(at(c[i-1]),at(c[i])));
 let best=null,checked=0;
 for(let i=0;i<c.length-2;i++)for(let j=i+2;j<Math.min(c.length,i+33);j++){
  const travelled=d[j]-d[i];if(travelled>1800)break;if(travelled<350)continue;
  checked++;const chord=meters(at(c[i]),at(c[j])),excess=travelled-chord;
  if(chord>=40&&chord<travelled*.42&&excess>=280&&(!best||excess>best.excess))
   best={i,j,excess,chord,travelled,center:c[Math.floor((i+j)/2)]};
 }
 return {suspicious:!!best,reason:best?'possible_loop':'',checked,detour:best};
}
function clearlyBetter(main,candidate){
 if(!finite(main?.distance)||!finite(candidate?.distance)||!finite(candidate?.duration)||!finite(main?.duration))return false;
 const saving=main.distance-candidate.distance;
 return saving>=Math.max(150,main.distance*.06)&&candidate.duration<=main.duration*1.10+30;
}
function sanitizeAreas(rows){
 if(!Array.isArray(rows))return [];
 return rows.slice(0,50).filter(z=>point(z)).map((z,i)=>({
  id:String(z.id||`zone-${i}`).slice(0,80),name:String(z.name||'避開區域').slice(0,40),
  note:String(z.note||'').slice(0,160),lat:z.lat,lng:z.lng,radius:clamp(Number(z.radius)||80,30,200),
  enabled:z.enabled!==false,start:validTime(z.start)?z.start:'00:00',end:validTime(z.end)?z.end:'00:00',
  createdAt:Number(z.createdAt)||0
 }));
}
function validTime(s){return typeof s==='string'&&/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(s);}
function timeNumber(s){return Number(s.slice(0,2))*60+Number(s.slice(3));}
function activeAt(z,minute){if(!z.enabled)return false;const a=timeNumber(z.start),b=timeNumber(z.end);
 return a===b||(a<b?(minute>=a&&minute<b):(minute>=a||minute<b));}
function taipeiMinute(now=Date.now()){
 const d=new Date(now+8*3600000);return d.getUTCHours()*60+d.getUTCMinutes();
}
function chooseAreas(rows,origin,destination,via=[],minute=taipeiMinute()){
 const valid=sanitizeAreas(rows),active=valid.filter(z=>activeAt(z,minute));
 const endpoint=[],candidates=[];
 for(const z of active){
  if([origin,destination,...via].some(p=>point(p)&&meters(p,z)<=z.radius+40)){endpoint.push(z);continue;}
  // Only nearby corridor areas are sent; never scan all city POIs or query external feeds.
  const anchors=[origin,destination,...via].filter(point),pad=.015;
  if(!anchors.length)continue;
  if(z.lat<Math.min(...anchors.map(p=>p.lat))-pad||z.lat>Math.max(...anchors.map(p=>p.lat))+pad||
     z.lng<Math.min(...anchors.map(p=>p.lng))-pad||z.lng>Math.max(...anchors.map(p=>p.lng))+pad)continue;
  candidates.push(z);
 }
 // The map can restore saved areas before its first GPS fix. Worker requests still have an origin.
 const reference=point(origin)?origin:point(destination)?destination:via.find(point);
 if(reference)candidates.sort((a,b)=>meters(reference,a)-meters(reference,b));
 return {areas:candidates.slice(0,8),endpointExempt: endpoint,overflow:Math.max(0,candidates.length-8)};
}
function ring(z){const out=[],n=16,r=z.radius/Math.cos(Math.PI/n);
 for(let i=0;i<n;i++){const a=i*2*Math.PI/n;out.push([z.lng+Math.cos(a)*r/(111320*Math.cos(z.lat*rad)),z.lat+Math.sin(a)*r/111320]);}
 out.push(out[0].slice());return out;}
function constraintsOK(coords,via=[],areas=[]){
 if(!Array.isArray(coords)||coords.length<2)return {ok:false,reason:'路線資料不足'};
 let lastAlong=-1;
 for(const p of via){const q=closest(coords,p);
  if(!q||q.distance>60||q.along<lastAlong-10)return {ok:false,reason:'無法確認路線依序經過指定位置；請把點放到道路上'};
  lastAlong=q.along;
 }
 for(const z of areas){const q=closest(coords,z);if(q&&q.distance<z.radius-3)return {ok:false,reason:'回傳路線仍穿過避開區域；未自動套用'};}
 return {ok:true,reason:''};
}
function signalStyle(mode,remaining){
 if(mode==='off')return {visible:false,opacity:0};
 if(mode==='on')return {visible:true,opacity:1};
 if(!finite(remaining)||remaining>500)return {visible:false,opacity:0};
 return {visible:true,opacity:clamp(1-(remaining-250)/350,.28,1)};
}
// Polygon coordinates are exactly the same ring used by exclude_polygons.
function areaFeatures(rows,origin,destination,via=[],minute=taipeiMinute()){
 const clean=sanitizeAreas(rows),chosen=chooseAreas(clean,origin,destination,via,minute);
 const exempt=new Set(chosen.endpointExempt.map(z=>z.id));
 return {type:'FeatureCollection',features:clean.filter(z=>z.enabled).map(z=>{
  const status=!activeAt(z,minute)?'inactive':exempt.has(z.id)?'exempt':'active';
  return {type:'Feature',id:z.id,properties:{id:z.id,name:z.name,radius:z.radius,status,
   label:z.name+(status==='inactive'?'（未到時段）':status==='exempt'?'（本次放行）':'')},
   geometry:{type:'Polygon',coordinates:[ring(z)]}};
 })};
}
// One timer at the next actual schedule boundary; no per-frame/date polling.
function nextAreaBoundaryMs(rows,now=Date.now()){
 const d=new Date(now+8*3600000),t=d.getUTCHours()*3600000+d.getUTCMinutes()*60000+d.getUTCSeconds()*1000+d.getUTCMilliseconds();
 let next=Infinity;
 for(const z of sanitizeAreas(rows)){if(!z.enabled||z.start===z.end)continue;
  for(const value of [z.start,z.end]){let delay=timeNumber(value)*60000-t;if(delay<=0)delay+=86400000;next=Math.min(next,delay+80);}}
 return Number.isFinite(next)?next:null;
}
function editVias(vias,picked,replaceIndex=null){
 if(!Array.isArray(vias)||vias.length>64||vias.some(p=>!point(p))||!point(picked))return null;
 const next=vias.map(p=>({lat:p.lat,lng:p.lng})),value={lat:picked.lat,lng:picked.lng};
 if(replaceIndex!==null){
  if(!Number.isInteger(replaceIndex)||replaceIndex<0||replaceIndex>=next.length)return null;
  next[replaceIndex]=value;
 }else{if(next.length>=64)return null;next.push(value);}
 return next;
}
return Object.freeze({editVias,areaFeatures,nextAreaBoundaryMs,point,meters,project,closest,inspect,clearlyBetter,sanitizeAreas,activeAt,taipeiMinute,chooseAreas,ring,constraintsOK,signalStyle});
});
