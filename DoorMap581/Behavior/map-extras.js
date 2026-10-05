/* 581 v0.3.45. Pure bounded data/geometry helpers; no tracking or external calls. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.DoorExtras=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
'use strict';
const MIN_ZOOM=15,RASTER_ZOOM=19.35,GRID_Z=15,WORLD_METERS=40075016.68557849;
const finite=x=>typeof x==='number'&&Number.isFinite(x);
const point=p=>!!p&&finite(p.lat)&&finite(p.lng)&&p.lat>=20&&p.lat<=27&&p.lng>=117&&p.lng<=123;
const clean=(v,max=140)=>String(v??'').replace(/[\u0000-\u001f<>]/g,' ').trim().slice(0,max);
function localized(v){
 if(typeof v==='string'){try{return localized(JSON.parse(v));}catch(_){return clean(v);}}
 if(v&&typeof v==='object'){
  const direct=v['zh-TW']??v['zh-Hant']??v['zh-tw']??v['en-US'];
  if(typeof direct==='string')return clean(direct);
  if(Array.isArray(v.List)){const p=v.List.find(x=>x.Lang==='zh-TW')||v.List.find(x=>/zh/i.test(x.Lang))||v.List[0];return clean(p?.Value);}
 }
 return '';
}
function stations(raw){
 const rows=Array.isArray(raw)?raw:Array.isArray(raw?.Data)?raw.Data:Array.isArray(raw?.data)?raw.data:null;
 if(!rows||rows.length>15000)throw Error('官方站點清單格式不符');
 const groups=new Map();
 for(const r of rows){if(!r||typeof r!=='object')continue;
  const lat=Number(r.Latitude),lng=Number(r.Longitude),name=localized(r.LocName);
  if(!point({lat,lng})||!name)continue;
  const cabinetId=clean(r.Id??r.ID??r.StationId??`${lat.toFixed(6)},${lng.toFixed(6)}`,80);
  const siteId=clean(r.GoStationSiteId??'',80),id=siteId?`site:${siteId}`:cabinetId;
  const state=r.State===undefined||r.State===null?null:clean(r.State,30);
  const row={id,lat,lng,name,address:localized(r.Address)||localized(r.LocAddress),city:localized(r.City),district:localized(r.District),
   hours:localized(r.OpeningHours)||localized(r.OpenHours),state,batteries:null,
   unavailable:[98,99,100,102].includes(Number(state))||/維修中|暫停服務|建置中|尚未啟用/.test(name),
   _rid:clean(r.RId??cabinetId,80),_state:state===null?Infinity:Number(state),_cabinet:cabinetId};
  if(!Number.isFinite(row._state))row._state=Infinity;
  if(!groups.has(id))groups.set(id,[]);
  if(!groups.get(id).some(x=>x._cabinet===cabinetId))groups.get(id).push(row);
 }
 const out=[];
 for(const rows of groups.values()){
  // Same site grouping and coordinate choice as the recovered official website model:
  // representative state/RId; position from the lowest RId, never an average.
  const lexical=(a,b)=>a._rid<b._rid?-1:a._rid>b._rid?1:0;
  const position=rows.slice().sort(lexical)[0],chosen=rows.slice().sort((a,b)=>a._state-b._state||lexical(a,b))[0];
  const {_rid,_state,_cabinet,...row}=chosen;out.push({...row,lat:position.lat,lng:position.lng});
 }
 if(!out.length)throw Error('官方回應沒有有效站點');return out;
}
function officialRows(raw){
 if(!Array.isArray(raw)||raw.length>10000)throw Error('官方門牌分片格式不符');
 return raw.map(r=>{
  if(!Array.isArray(r)||r.length!==8)throw Error('官方門牌欄位不符');
  const [lat,lng,num,road,lane,alley,area,district]=r;
  if(!point({lat,lng})||typeof num!=='string'||!num.trim())throw Error('官方門牌點位不符');
  return {lat,lng,houseNumber:clean(num,40),road:clean(road,100),lane:clean(lane,60),alley:clean(alley,60),area:clean(area,80),district:clean(district,50),source:'taichung-official-address'};
 });
}
function safeStationRows(rows){if(!Array.isArray(rows))throw Error('站點資料格式不符');return rows.slice(0,15000).filter(r=>point(r)&&typeof r.name==='string'&&typeof r.id==='string').map(r=>({...r,name:clean(r.name),address:clean(r.address),city:clean(r.city,30),district:clean(r.district,30),hours:clean(r.hours),batteries:null,unavailable:r.unavailable===true}));}
function stationFeatures(rows){return {type:'FeatureCollection',features:rows.map(r=>({type:'Feature',id:r.id,geometry:{type:'Point',coordinates:[r.lng,r.lat]},properties:{id:r.id,name:r.name,unavailable:!!r.unavailable}}))};}
function meters(a,b){const x=(a.lng-b.lng)*111320*Math.cos((a.lat+b.lat)*Math.PI/360),y=(a.lat-b.lat)*111320;return Math.hypot(x,y);}
function xy(lat,lng){const n=2**GRID_Z;return {x:Math.floor((lng+180)/360*n),y:Math.floor((1-Math.asinh(Math.tan(lat*Math.PI/180))/Math.PI)/2*n)};}
function gridBounds(x,y){const n=2**GRID_Z;if(!Number.isInteger(x)||!Number.isInteger(y)||x<0||x>=n||y<0||y>=n)throw Error('invalid address tile');const latitude=t=>Math.atan(Math.sinh(Math.PI*(1-2*t/n)))*180/Math.PI;const b={west:x/n*360-180,east:(x+1)/n*360-180,north:latitude(y),south:latitude(y+1)};if(!point({lat:(b.north+b.south)/2,lng:(b.west+b.east)/2}))throw Error('address tile outside Taiwan');return b;}
function tilesForView(bounds,center){
 if(!point(center)||!bounds)return [];
 const a=xy(Math.min(27,bounds.north),Math.max(117,bounds.west)),b=xy(Math.max(20,bounds.south),Math.min(123,bounds.east));
 const out=[],count=(b.x-a.x+1)*(b.y-a.y+1);
 // A pitched map can expose a distant skyline and make getBounds() enormous even
 // when the rider's lower street band is already close enough for house numbers.
 // Never turn that into zero local tiles: fall back to the center 3x3 and keep
 // only the four nearest. This remains bounded and does not scan/download Taiwan.
 const candidates=[];
 if(count>30){const c=xy(center.lat,center.lng);for(let x=c.x-1;x<=c.x+1;x++)for(let y=c.y-1;y<=c.y+1;y++)candidates.push([x,y]);}
 else for(let x=a.x;x<=b.x;x++)for(let y=a.y;y<=b.y;y++)candidates.push([x,y]);
 for(const [x,y] of candidates){try{const g=gridBounds(x,y);out.push({x,y,key:`${x}/${y}`,distance:meters(center,{lat:(g.north+g.south)/2,lng:(g.east+g.west)/2})});}catch(_){}}
 return out.sort((a,b)=>a.distance-b.distance).slice(0,4);
}
function houseRows(data){if(!Array.isArray(data?.elements))throw Error('門牌來源格式不符');const out=[];for(const e of data.elements.slice(0,6000)){if(e.type!=='node')continue;const p={lat:Number(e.lat),lng:Number(e.lon)};const num=clean(e.tags?.['addr:housenumber'],30);if(!point(p)||!num)continue;out.push({...p,houseNumber:num,road:clean(e.tags?.['addr:street'],80),source:'OSM address node'});}return out;}
function segmentDistance(p,a,b){const dx=b.x-a.x,dy=b.y-a.y,l=dx*dx+dy*dy;const t=l?Math.max(0,Math.min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/l)):0;return Math.hypot(p.x-a.x-t*dx,p.y-a.y-t*dy);}
function lineHitsRect(a,b,r){let t0=0,t1=1;const dx=b.x-a.x,dy=b.y-a.y;for(const [p,q] of [[-dx,a.x-r.left],[dx,r.right-a.x],[-dy,a.y-r.top],[dy,r.bottom-a.y]]){if(!p){if(q<0)return false;continue;}const u=q/p;if(p<0){if(u>t1)return false;t0=Math.max(t0,u);}else{if(u<t0)return false;t1=Math.min(t1,u);}}return true;}
// Food-delivery-style house labels: fixed small type in the medium/close street
// range. The map scale changes, but the rider should not have to re-learn the
// text size while approaching an address.
const HOUSE_FONT_PX=10.25;
const HOUSE_CORRIDOR_M=50,HOUSE_DESTINATION_M=90,HOUSE_MAX_OFFSET_PX=24;
const clamp=(x,a,b)=>Math.max(a,Math.min(b,x));
const validScreen=p=>!!p&&finite(p.x)&&finite(p.y);
const validCoordinate=p=>Array.isArray(p)&&point({lng:p[0],lat:p[1]});
function houseFontSize(){return HOUSE_FONT_PX;}
function houseFontExpression(){return HOUSE_FONT_PX;}
function viewWidthMeters(center,zoom,width){
 if(!point(center)||!finite(zoom)||!finite(width)||width<=0)return null;
 // MapLibre's camera zoom is defined on a 512 CSS-pixel world tile. Using the
 // zoom/latitude scale avoids perspective-dependent unproject() widths that can
 // stay near the same value while the rider pinches a pitched navigation map.
 const span=width*WORLD_METERS*Math.cos(center.lat*Math.PI/180)/(512*2**zoom);
 return finite(span)&&span>0?span:null;
}
function houseView({center,zoom,route=[],project,width=390,height=740,viewWidthM}={}){
 route=Array.isArray(route)?route:[];
 const originalDetail=finite(zoom)&&zoom>=RASTER_ZOOM;
 const hidden=reason=>({active:false,mode:'hidden',reason,viewWidthM:null,originalDetail,fontPx:houseFontSize(zoom),limit:0,opacity:0});
 if(!point(center)||!finite(zoom)||typeof project!=='function'||!(width>0&&height>0))return hidden('等待有效地圖視野');
 if(zoom<MIN_ZOOM)return hidden('視野較遠：路徑兩側門牌暫隱藏');
 let span=finite(viewWidthM)&&viewWidthM>0?viewWidthM:viewWidthMeters(center,zoom,width);
 if(!finite(span)||span<=0)return hidden('等待可換算的地圖比例');
 let navigating=false;
 for(let i=1;i<Math.min(route.length,8192);i++)if(validCoordinate(route[i-1])&&validCoordinate(route[i])&&
  (route[i-1][0]!==route[i][0]||route[i-1][1]!==route[i][1])){navigating=true;break;}
 const maxSpan=navigating?720:320,fadeSpan=navigating?260:80;
 if(span>=maxSpan||(!navigating&&zoom<17.5))return {...hidden(navigating?'視野較遠：再接近街區後顯示路徑兩側':'一般瀏覽：再放近才顯示門牌'),viewWidthM:span};
 const density=clamp((maxSpan-span)/fadeSpan,0,1),area=clamp(width*height/(390*740),.65,1.5);
 // Keep the labels readable as soon as they appear. Distance changes density,
 // not type size; muted opacity prevents a dense street from overpowering route UI.
 // At very close zoom the custom layer remains available while the original
 // NLSC/base-map detail is revealed, so a slow/missing raster never creates a blank.
 const opacity=navigating?.56+.18*density:.58+.12*density;
 return {active:true,mode:navigating?'route':'browse',reason:navigating?'路徑兩側輔助門牌':'近距離輔助門牌',viewWidthM:span,originalDetail,
  fontPx:houseFontSize(zoom),opacity,limit:Math.round((navigating?20+40*density:28+40*density)*area)};
}
function nearestOnSegment(p,a,b){
 const dx=b.x-a.x,dy=b.y-a.y,len=Math.hypot(dx,dy),rawT=len?((p.x-a.x)*dx+(p.y-a.y)*dy)/(len*len):0,t=clamp(rawT,0,1);
 const foot={x:a.x+t*dx,y:a.y+t*dy};
 return {distance:Math.hypot(p.x-foot.x,p.y-foot.y),foot,t,rawT,len,cross:len?(dx*(p.y-a.y)-dy*(p.x-a.x))/len:0};
}
function rectOverlap(a,b){return !(a.right<b.left||a.left>b.right||a.bottom<b.top||a.top>b.bottom);}
function houseTextBox(label,font,x,y,pad=3){
 // Conservative glyph extents, including the halo. No wrapping/rotation in the layer.
 let em=0;for(const c of label)em+=c.codePointAt(0)>255?1:/[0-9]/.test(c)?.64:.7;
 const w=em*font+2*pad,h=font*1.2+2*pad;
 return {left:x-w/2,right:x+w/2,top:y-h/2,bottom:y+h/2};
}
function houses(rows,options={}){
 const {center,zoom,destination=null,position=null,project,width=390,height=740}=options;
 const route=Array.isArray(options.route)?options.route:[],obstacles=Array.isArray(options.obstacles)?options.obstacles:[];
 const view=houseView(options),stats={mode:view.mode,viewWidthM:view.viewWidthM,input:0,insideCorridor:0,offCorridor:0,offscreen:0,routeOverlap:0,crowded:0,shifted:0};
 const result=features=>({type:'FeatureCollection',features,houseDiagnostics:{...stats,selected:features.length,fontPx:view.fontPx,reason:view.reason}});
 if(!view.active)return result([]);
 const font=view.fontPx,R=111320,cos=Math.cos(center.lat*Math.PI/180),world=p=>({x:(p.lng-center.lng)*R*cos,y:(p.lat-center.lat)*R});
 const screen=p=>{try{const s=project(p);return validScreen(s)?s:null;}catch(_){return null;}};
 const segments=[],allSegments=[],viewRect={left:-100,right:width+100,top:-100,bottom:height+100};let cumulative=0;
 // Consecutive original segments only: never decimate vertices into corner-cutting chords.
 for(let i=1;i<Math.min(route.length,8192);i++){
  const pa=route[i-1],pb=route[i];if(!validCoordinate(pa)||!validCoordinate(pb))continue;
  const wa=world({lng:pa[0],lat:pa[1]}),wb=world({lng:pb[0],lat:pb[1]}),len=Math.hypot(wb.x-wa.x,wb.y-wa.y);
  if(len<.05)continue;const a=screen(pa),b=screen(pb),seg={a,b,wa,wb,len,start:cumulative,index:i};cumulative+=len;allSegments.push(seg);
  if(a&&b&&lineHitsRect(a,b,viewRect)&&segments.length<512)segments.push(seg);
 }
 let progress=0;
 if(point(position)){let best=Infinity;const p=world(position);for(const s of allSegments){const hit=nearestOnSegment(p,s.wa,s.wb);if(hit.distance<best){best=hit.distance;progress=s.start+hit.t*s.len;}}}
 const seen=new Set(),items=[];
 for(const row of (Array.isArray(rows)?rows:[]).slice(0,16000)){
  stats.input++;if(!row||typeof row!=='object')continue;const num=clean(row.houseNumber,30);if(!point(row)||!num||meters(row,center)>1800)continue;
  const key=`${num.replace(/號$/,'')}:${row.lat.toFixed(5)}:${row.lng.toFixed(5)}`;if(seen.has(key))continue;seen.add(key);
  const p=screen([row.lng,row.lat]);if(!p||p.x<4||p.x>width-4||p.y<4||p.y>height-4){stats.offscreen++;continue;}
  let routeM=Infinity,near=null,hit=null;const w=world(row);
  for(const seg of segments){const h=nearestOnSegment(w,seg.wa,seg.wb);if(h.distance<routeM){routeM=h.distance;near=seg;hit=h;}}
  const destM=point(destination)?meters(row,destination):Infinity;
  // Never widen to unrelated streets when zooming closer during navigation.
  if(view.mode==='route'&&routeM>HOUSE_CORRIDOR_M&&destM>HOUSE_DESTINATION_M){stats.offCorridor++;continue;}
  stats.insideCorridor++;
  const label=/號$/.test(num)?num:`${num}號`,base=houseTextBox(label,font,p.x,p.y);
  const ahead=near?near.start+(near===allSegments[0]&&hit.rawT<0?hit.rawT:hit.t)*near.len-progress:Infinity;
  const behind=ahead < -15,band=behind?3:routeM<=HOUSE_CORRIDOR_M?(ahead<=300?0:2):destM<=HOUSE_DESTINATION_M?1:2;
  const priority=band*1e6+(finite(ahead)?Math.max(0,Math.floor(ahead/25))*100:0)+Math.min(routeM,destM,meters(row,center));
  const side=hit&&Math.abs(hit.cross)>.5?(hit.cross>0?'left':'right'):'unknown';
  items.push({row,key,label,p,base,near,hit,routeM,destM,priority,side,ahead,behind});
 }
 items.sort((a,b)=>a.priority-b.priority||a.key.localeCompare(b.key));
 const chosen=[],routePad=8,sideCounts={left:0,right:0,unknown:0},bothSides=['left','right'].every(s=>items.some(a=>a.side===s));
 for(const a of items){
  const {p,near,base}=a,offsets=[];let normal=null,signed=null;
  // Neaten the near-road row on the SAME side. Do not change geometry or source coordinates.
  if(view.mode==='route'&&near&&a.routeM<=HOUSE_CORRIDOR_M&&a.side!=='unknown'){
   const h=nearestOnSegment(p,near.a,near.b);
   if(h.len>1&&h.t>.015&&h.t<.985&&Math.abs(h.cross)>.6){
    const sign=Math.sign(h.cross);normal={x:-(near.b.y-near.a.y)/h.len*sign,y:(near.b.x-near.a.x)/h.len*sign};signed=h;
    const support=(base.right-base.left)/2*Math.abs(normal.x)+(base.bottom-base.top)/2*Math.abs(normal.y);
    const preferred=support+routePad+2,delta=preferred-Math.abs(h.cross);
    if(Math.abs(delta)<=HOUSE_MAX_OFFSET_PX)offsets.push({x:normal.x*delta,y:normal.y*delta});
   }
  }
  offsets.push({x:0,y:0});
  if(normal)for(const extra of [6,12,18])offsets.push({x:normal.x*extra,y:normal.y*extra});
  let selected=null,sawCollision=false;
  for(const candidate of offsets){
   // Round the actual em offset first, then test precisely the same position sent to MapLibre.
   const offset=[Math.round(candidate.x/font*100)/100,Math.round(candidate.y/font*100)/100],dx=offset[0]*font,dy=offset[1]*font;
   if(Math.hypot(dx,dy)>HOUSE_MAX_OFFSET_PX+.01)continue;
   const q={x:p.x+dx,y:p.y+dy},box=houseTextBox(a.label,font,q.x,q.y);
   if(box.left<6||box.right>width-6||box.top<6||box.bottom>height-6)continue;
   if(normal&&signed){const end=nearestOnSegment(q,near.a,near.b);if(end.cross*signed.cross<=0)continue;}
   if(dx||dy){
    // Avoid crossing any branch of a bend/hairpin even when both ends look locally valid.
    if(segments.some(s=>{const h1=nearestOnSegment(p,s.a,s.b),h2=nearestOnSegment(q,s.a,s.b);return h1.cross*h2.cross<0&&lineHitsRect(s.a,s.b,{left:Math.min(p.x,q.x),right:Math.max(p.x,q.x),top:Math.min(p.y,q.y),bottom:Math.max(p.y,q.y)});}))continue;
   }
   const padded={left:box.left-routePad,right:box.right+routePad,top:box.top-routePad,bottom:box.bottom+routePad};
   if(segments.some(s=>lineHitsRect(s.a,s.b,padded)))continue;
   if(obstacles.some(b=>rectOverlap(box,b))||chosen.some(b=>rectOverlap(box,b.box))){sawCollision=true;continue;}
   selected={...a,offset,box};break;
  }
  if(!selected){stats[sawCollision?'crowded':'routeOverlap']++;continue;}
  if(bothSides&&a.side!=='unknown'&&sideCounts[a.side]>=Math.ceil(view.limit*.65))continue;
  chosen.push(selected);sideCounts[a.side]++;if(selected.offset.some(v=>v!==0))stats.shifted++;
  if(chosen.length>=view.limit)break;
 }
 return result(chosen.map((a,i)=>({type:'Feature',id:a.key,geometry:{type:'Point',coordinates:[a.row.lng,a.row.lat]},
  properties:{label:a.label,distance:i,source:a.row.source||'known address',offset:a.offset,side:a.side,
   opacity:Math.round(view.opacity*(a.behind ? .68 : 1)*100)/100,layoutOnly:true}})));
}

return Object.freeze({MIN_ZOOM,RASTER_ZOOM,GRID_Z,HOUSE_FONT_PX,point,clean,localized,stations,safeStationRows,stationFeatures,meters,gridBounds,tilesForView,houseRows,officialRows,houseView,viewWidthMeters,houseFontSize,houseFontExpression,HOUSE_CORRIDOR_M,HOUSE_DESTINATION_M,HOUSE_MAX_OFFSET_PX,houseTextBox,houses,lineHitsRect});
});
