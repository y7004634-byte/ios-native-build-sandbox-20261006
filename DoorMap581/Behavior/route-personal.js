/* Door Map 0.3.74: planning-only editor and personal data. No GPS listener or track ingestion. */
(function(root,factory){const api=factory(root.DoorDelivery);if(typeof module==='object'&&module.exports)module.exports=api;root.DoorRoutePersonal=api;})(globalThis,function(D){
'use strict';
const MAX_POINTS=64,MAX_MEMORIES=1000,MAX_BACKUP_BYTES=2500000,MEMORY_KEY='581-planned-route-memory-v1';
const copy=x=>JSON.parse(JSON.stringify(x));
const point=p=>D.point(p);
const cleanPoint=p=>({lat:Number(p.lat),lng:Number(p.lng)});
const coords=r=>r?.geometry?.coordinates||[];
const equal=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
function cleanVias(rows){if(!Array.isArray(rows)||rows.length>MAX_POINTS||!rows.every(point))throw Error('控制點格式錯誤或超過本次路線容量');return rows.map(cleanPoint);}
class Editor {
 constructor(){this.active=false;this.version=0;this.selected=null;this.history=[];}
 begin(snapshot){this.version++;this.active=true;this.base=copy(snapshot);this.via=cleanVias(snapshot.via||[]);this.record=copy(snapshot.record);this.alternates=copy(snapshot.alternates||[]);this.validVia=copy(this.via);this.history=[];this.selected=null;this.error='';return this.version;}
 get ready(){return this.active&&!this.error&&equal(this.via,this.validVia)&&coords(this.record).length>1;}
 get changed(){return this.active&&!equal(this.via,this.base.via||[]);}
 snapshot(){return {via:copy(this.via),record:copy(this.record),alternates:copy(this.alternates),validVia:copy(this.validVia),error:this.error};}
 change(kind,value){
  if(!this.active)throw Error('請先開啟編輯路線');
  const next=copy(this.via);
  if(kind==='add'){if(next.length>=MAX_POINTS)throw Error('這條路線的控制點太多；請刪除重複點');if(!point(value))throw Error('無效位置');next.push(cleanPoint(value));}
  else if(kind==='move'){if(!Number.isInteger(value.index)||!next[value.index]||!point(value.point))throw Error('控制點已不存在');next[value.index]=cleanPoint(value.point);}
  else if(kind==='delete'){if(!Number.isInteger(value)||!next[value])throw Error('控制點已不存在');next.splice(value,1);}
  else throw Error('未知編輯操作');
  this.history.push(this.snapshot());if(this.history.length>100)this.history.shift();this.via=next;this.selected=null;this.error='';return ++this.version;
 }
 undo(){if(!this.active||!this.history.length)return false;Object.assign(this,this.history.pop());this.selected=null;this.version++;return true;}
 clear(){if(!this.active)return;this.history.push(this.snapshot());this.via=copy(this.base.via||[]);this.record=copy(this.base.record);this.alternates=copy(this.base.alternates||[]);this.validVia=copy(this.via);this.selected=null;this.error='';this.version++;}
 accept(version,record,alternates=[]){if(!this.active||version!==this.version)return false;if(!D.constraintsOK(coords(record),this.via,[]).ok)throw Error('路線未依序通過控制點');this.record=copy(record);this.alternates=copy(alternates);this.validVia=copy(this.via);this.error='';return true;}
 fail(version,error){if(this.active&&version===this.version)this.error=String(error||'規劃失敗');}
 cancel(){if(!this.active)return null;const base=copy(this.base);this.active=false;this.version++;this.history=[];this.selected=null;return base;}
 finish(){if(!this.ready)throw Error('新路線尚未完成，請稍候或撤銷錯誤點');const out={...this.snapshot(),base:copy(this.base),changed:this.changed};this.active=false;this.version++;this.history=[];this.selected=null;return out;}
}
function simplify(points,tolerance=18){
 if(points.length<3)return points.slice();let max=0,at=0;
 for(let i=1;i<points.length-1;i++){const d=D.project(D.at?D.at(points[i]):{lng:points[i][0],lat:points[i][1]},points[0],points.at(-1)).distance;if(d>max){max=d;at=i;}}
 if(max<=tolerance)return [points[0],points.at(-1)];return [...simplify(points.slice(0,at+1),tolerance).slice(0,-1),...simplify(points.slice(at),tolerance)];
}
const toPoint=c=>({lng:Number(c[0]),lat:Number(c[1])});
const toCoord=p=>[p.lng,p.lat];
function length(cs){let n=0;for(let i=1;i<cs.length;i++)n+=D.meters(toPoint(cs[i-1]),toPoint(cs[i]));return n;}
function heading(a,b){return (Math.atan2((b.lng-a.lng)*Math.cos(a.lat*Math.PI/180),b.lat-a.lat)*180/Math.PI+360)%360;}
function angle(a,b){return Math.abs(((a-b+540)%360)-180);}
function memoryId(points){let h=2166136261;for(const c of JSON.stringify(points.map(p=>[p.lng.toFixed(5),p.lat.toFixed(5)]))){h^=c.charCodeAt(0);h=Math.imul(h,16777619);}return 'p-'+(h>>>0).toString(16);}
function plannedDifferences(before,after,source,now=Date.now()){
 if(!['edit','alternative'].includes(source))return [];
 const a=coords(before),b=coords(after);if(a.length<2||b.length<2)return [];
 const sampled=simplify(b,10);if(sampled.length>800)return [];
 const different=sampled.map(c=>(D.closest(a,toPoint(c))?.distance||0)>35);const groups=[];
 for(let i=0;i<sampled.length;i++){
  if(!different[i])continue;const start=Math.max(0,i-1);while(i+1<sampled.length&&different[i+1])i++;
  const end=Math.min(sampled.length-1,i+1),path=sampled.slice(start,end+1);
  // Only learn bounded local differences with a shared entrance and exit, not full trip history.
  if(different[start]||different[end]||path.length<3||length(path)>3000||length(path)<45)continue;
  let compact=simplify(path,20);if(compact.length>18)continue;
  const points=compact.map(toPoint);if(D.meters(points[0],points.at(-1))<40)continue;
  groups.push({id:memoryId(points),source,points,heading:heading(points[0],points.at(-1)),count:1,updatedAt:now});
 }
 return groups.slice(0,8);
}
function sanitizeMemories(rows){
 if(!Array.isArray(rows)||rows.length>MAX_MEMORIES)throw Error('路線記憶格式或筆數不符');const out=[];
 for(const r of rows){
  if(!r||!['edit','alternative'].includes(r.source)||!Array.isArray(r.points)||r.points.length<3||r.points.length>18||!r.points.every(point))throw Error('記憶含有無效規劃');
  const ps=r.points.map(cleanPoint);if(length(ps.map(toCoord))>3500)throw Error('記憶路段過長');
  out.push({id:memoryId(ps),source:r.source,points:ps,heading:heading(ps[0],ps.at(-1)),count:Math.max(1,Math.min(1000,Math.floor(Number(r.count)||1))),updatedAt:Math.max(0,Math.min(Date.now()+86400000,Number(r.updatedAt)||0))});
 }
 return out;
}
class Memory {
 constructor(storage){this.storage=storage;this.rows=[];this.index=new Map();this.lastError='';this.load();}
 load(){try{this.rows=sanitizeMemories(JSON.parse(this.storage.getItem(MEMORY_KEY)||'[]'));}catch(e){this.rows=[];this.lastError=String(e.message||e);}this.reindex();}
 reindex(){this.index.clear();for(const r of this.rows){const p=r.points[0],key=Math.floor(p.lng*100)+':'+Math.floor(p.lat*100);if(!this.index.has(key))this.index.set(key,[]);this.index.get(key).push(r);}}
 save(rows){const clean=sanitizeMemories(rows);this.storage.setItem(MEMORY_KEY,JSON.stringify(clean));this.rows=clean;this.reindex();}
 learn(before,after,source){const learned=plannedDifferences(before,after,source);if(!learned.length)return 0;
  let rows=copy(this.rows);for(const r of learned){const old=rows.find(x=>x.id===r.id);if(old){r.count=old.count+1;rows=rows.filter(x=>x.id!==r.id);}rows.push(r);}
  rows.sort((a,b)=>b.updatedAt-a.updatedAt);this.save(rows.slice(0,MAX_MEMORIES));return learned.length;
 }
 remove(id){this.save(this.rows.filter(r=>r.id!==id));}
 candidates(record){const cs=coords(record);if(cs.length<2)return [];const found=new Map(),step=Math.max(1,Math.ceil(cs.length/200));
  for(let i=0;i<cs.length;i+=step){const x=Math.floor(cs[i][0]*100),y=Math.floor(cs[i][1]*100);for(let dx=-1;dx<=1;dx++)for(let dy=-1;dy<=1;dy++)for(const r of this.index.get((x+dx)+':'+(y+dy))||[])found.set(r.id,r);}
  const out=[];for(const r of [...found.values()].sort((a,b)=>b.updatedAt-a.updatedAt).slice(0,96)){
   const enter=D.closest(cs,r.points[0]),exit=D.closest(cs,r.points.at(-1));
   if(!enter||!exit||enter.distance>85||exit.distance>85||exit.along-enter.along<45)continue;
   if(angle(heading(toPoint(enter.coord),toPoint(exit.coord)),r.heading)>55)continue;
   if(r.points.slice(1,-1).every(p=>(D.closest(cs,p)?.distance||0)<25))continue;
   out.push({...r,along:enter.along});
  }
  out.sort((a,b)=>(b.source==='edit')-(a.source==='edit')||b.count-a.count||b.updatedAt-a.updatedAt);return out.slice(0,3);
 }
}
function reasonablePreference(baseline,candidate){return !!candidate&&Number.isFinite(candidate.distance)&&Number.isFinite(candidate.duration)&&candidate.distance<=baseline.distance*1.18+120&&candidate.duration<=baseline.duration*1.20+35;}
const SETTINGS={
 '581-door-theme':['dark','light'],'581-door-avatar':null,'581-door-pip-view':['0','1'],
 '581-door-route-enabled-v2':['0','1'],'581-avoid-overlay-visible-v1':['0','1'],
 '581-door-buildings3d-v1':['0','1'],'581-route-memory-enabled-v1':['0','1']
};
function sanitizeSettings(raw){const out={};for(const [k,allowed] of Object.entries(SETTINGS)){const v=raw?.[k];if(typeof v==='string'&&v.length<=80&&(!allowed||allowed.includes(v)))out[k]=v;}return out;}
function makeBackup(storage){const settings={};for(const k of Object.keys(SETTINGS)){const v=storage.getItem(k);if(v!==null)settings[k]=v;}
 return validateBackup({schema:'581-doormap-personal',version:1,createdAt:Date.now(),settings,areas:JSON.parse(storage.getItem('581-delivery-areas-v1')||'[]'),memories:JSON.parse(storage.getItem(MEMORY_KEY)||'[]')});}
function validateBackup(value){
 const raw=typeof value==='string'?value:JSON.stringify(value);if(new TextEncoder().encode(raw).length>MAX_BACKUP_BYTES)throw Error('個人備份太大');const x=typeof value==='string'?JSON.parse(value):value;
 if(x?.schema!=='581-doormap-personal'||x.version!==1)throw Error('不是可支援的 Door Map 個人備份版本');
 if(!Array.isArray(x.areas)||x.areas.length>50||!x.areas.every(point))throw Error('避開區格式錯誤');
 return {schema:'581-doormap-personal',version:1,createdAt:Number(x.createdAt)||Date.now(),settings:sanitizeSettings(x.settings),areas:D.sanitizeAreas(x.areas),memories:sanitizeMemories(x.memories)};
}
function restoreBackup(storage,value){const x=validateBackup(value);const changes={...x.settings,'581-delivery-areas-v1':JSON.stringify(x.areas),[MEMORY_KEY]:JSON.stringify(x.memories)};
 const old={};for(const k of Object.keys(changes))old[k]=storage.getItem(k);
 try{for(const [k,v] of Object.entries(changes))storage.setItem(k,v);}catch(e){for(const [k,v] of Object.entries(old)){try{v===null?storage.removeItem(k):storage.setItem(k,v);}catch(_){}}throw e;}return x;
}
return {MAX_POINTS,MAX_MEMORIES,MAX_BACKUP_BYTES,MEMORY_KEY,SETTINGS,Editor,Memory,cleanVias,simplify,plannedDifferences,sanitizeMemories,reasonablePreference,makeBackup,validateBackup,restoreBackup,copy};
});
