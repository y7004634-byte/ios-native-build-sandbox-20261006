/* 581 v0.3.63: fixed geographic anchors, MapLibre-native symbol rendering.
 * No canvas overlay, map.project(), camera-frame setData, variable anchor or text offset.
 * GeoJSON is a bounded local-data transport; MapLibre's worker tiles and GPU render it.
 */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.DoorNativeHouses=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
'use strict';
const SOURCE='extra-house-numbers',LAYER='extra-house-labels',FONT=10.25;
const HOUSE_DENSITY_SPACING=[180,110,68],HOUSE_DETAIL_Z=[15,16.4,17.6,18.8],HOUSE_AHEAD=[560,320,180,95];
const MAX_ROWS=40000,MAX_FEATURES=8000,MAX_SEGMENTS=8192,R=111320,CELL=120;
const empty=()=>({type:'FeatureCollection',features:[]});
const valid=p=>p&&Number.isFinite(p.lat)&&Number.isFinite(p.lng)&&p.lat>=20&&p.lat<=27&&p.lng>=117&&p.lng<=123;
const coordinate=p=>Array.isArray(p)&&valid({lng:p[0],lat:p[1]});
const clean=v=>String(v??'').replace(/[\u0000-\u001f<>]/g,' ').trim().slice(0,30).replace(/號$/,'');
function hash(s){let h=2166136261;for(let i=0;i<s.length;i++){h^=s.charCodeAt(i);h=Math.imul(h,16777619);}return h>>>0;}
function keyOf(r){return `${clean(r.houseNumber)}:${r.lat.toFixed(7)}:${r.lng.toFixed(7)}`;}
function hit(p,a,b){const dx=b.x-a.x,dy=b.y-a.y,l=dx*dx+dy*dy,t=l?Math.max(0,Math.min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/l)):0;return {d:Math.hypot(p.x-a.x-dx*t,p.y-a.y-dy*t),t,cross:dx*(p.y-a.y)-dy*(p.x-a.x)};}
function routeKey(route,dest){return JSON.stringify([Array.isArray(route)?route:[],valid(dest)?[dest.lng,dest.lat]:null]);}
function compileRoute(route=[],destination=null){
 const points=Array.isArray(route)?route:[],origin=points.find(coordinate)||[120.67,24.14],cos=Math.cos(origin[1]*Math.PI/180);
 const world=p=>({x:(p.lng-origin[0])*R*cos,y:(p.lat-origin[1])*R});
 const segments=[],bins=new Map(),wide=[];let length=0;
 for(let i=1;i<Math.min(points.length,MAX_SEGMENTS+1);i++){
  if(!coordinate(points[i-1])||!coordinate(points[i]))continue;
  const a=world({lng:points[i-1][0],lat:points[i-1][1]}),b=world({lng:points[i][0],lat:points[i][1]}),len=Math.hypot(b.x-a.x,b.y-a.y);if(len<.05)continue;
  const seg={a,b,len,start:length};length+=len;const id=segments.push(seg)-1;
  const x0=Math.floor((Math.min(a.x,b.x)-51)/CELL),x1=Math.floor((Math.max(a.x,b.x)+51)/CELL),y0=Math.floor((Math.min(a.y,b.y)-51)/CELL),y1=Math.floor((Math.max(a.y,b.y)+51)/CELL);
  // Bounding-box indexing is exact. Unusually long segments are tested separately,
  // never simplified into corner-cutting chords and never expanded to huge grids.
  if((x1-x0+1)*(y1-y0+1)>256){wide.push(id);continue;}
  for(let x=x0;x<=x1;x++)for(let y=y0;y<=y1;y++){const k=`${x}/${y}`;if(!bins.has(k))bins.set(k,[]);bins.get(k).push(id);}
 }
 const dest=valid(destination)?world(destination):null;
 function classify(row){const p=world(row),ids=bins.get(`${Math.floor(p.x/CELL)}/${Math.floor(p.y/CELL)}`)||[];let nearest=null,d=Infinity;
  for(const id of [...ids,...wide]){const s=segments[id],h=hit(p,s.a,s.b);if(h.d<d){d=h.d;nearest={...h,along:s.start+h.t*s.len};}}
  const destDistance=dest?Math.hypot(p.x-dest.x,p.y-dest.y):Infinity;
  return {keep:!segments.length||d<=50.001||destDistance<=90.001,distance:d,along:nearest?.along??0,side:nearest?(Math.abs(nearest.cross)<.001?'unknown':nearest.cross>0?'left':'right'):'unknown',destinationDistance:destDistance};
 }
 return {classify,navigating:segments.length>0,segments:segments.length,length};
}
function features(rows,{route=[],destination=null,compiled=null,destinationHouse='',destinationRoad=''}={}){
 const c=compiled||compileRoute(route,destination),seen=new Map();let rejected=0,inspected=0;
 const wantedHouse=clean(destinationHouse),wantedRoad=String(destinationRoad||'').replace(/臺/g,'台').replace(/\s+/g,'').trim();
 for(const r of Array.isArray(rows)?rows:[]){if(inspected++>=MAX_ROWS)break;if(!valid(r)||!clean(r.houseNumber))continue;
  const id=keyOf(r),old=seen.get(id);if(old&&old.properties.official)continue;
  const h=c.classify(r);if(!h.keep||(c.navigating&&h.distance<2)){rejected++;continue;}
  const official=r.source==='taichung-official-address',rowRoad=String(r.road||'').replace(/臺/g,'台').replace(/\s+/g,'').trim();
  const roadOk=!wantedRoad||!rowRoad||wantedRoad.includes(rowRoad)||rowRoad.includes(wantedRoad);
  const targetDestination=!!wantedHouse&&clean(r.houseNumber)===wantedHouse&&h.destinationDistance<=45.001&&roadOk;
  seen.set(id,{type:'Feature',id,geometry:{type:'Point',coordinates:[r.lng,r.lat]},properties:{id,label:clean(r.houseNumber)+(clean(r.houseNumber).includes('號')?'':'號'),official,source:r.source||'known address',side:h.side,along:Math.round(h.along),nearDestination:h.destinationDistance<=90.001?1:0,targetDestination:targetDestination?1:0,rank:targetDestination?-1000000:hash(id)%1000000,densityTier:3}});
 }
 // Route-side sampling is world-space and stable: no camera-frame rebuilds.
 // Far zoom shows only representative numbers; zooming in progressively reveals
 // more. The exact destination number is always a separate top-priority layer.
 const all=[...seen.values()];
 const chosen=new Set(all.filter(f=>f.properties.targetDestination).map(f=>f.id));
 for(let tier=0;tier<HOUSE_DENSITY_SPACING.length;tier++){
  const spacing=HOUSE_DENSITY_SPACING[tier],buckets=new Map();
  for(const f of all){if(chosen.has(f.id))continue;const p=f.properties,along=Number(p.along)||0;
   const local=p.nearDestination===1?Math.max(22,spacing*.58):spacing;const bucket=`${p.side||'unknown'}:${Math.floor(along/local)}`;
   const score=(p.nearDestination===1?-1e9:0)+(p.official?-1e6:0)+p.rank;const prev=buckets.get(bucket);if(!prev||score<prev.score)buckets.set(bucket,{f,score});
  }
  for(const {f} of buckets.values()){f.properties.densityTier=Math.min(f.properties.densityTier,tier);chosen.add(f.id);}
 }
 const out=all.sort((a,b)=>(b.properties.targetDestination-a.properties.targetDestination)||(a.properties.densityTier-b.properties.densityTier)||(b.properties.official-a.properties.official)||a.properties.rank-b.properties.rank||a.id.localeCompare(b.id)).slice(0,MAX_FEATURES);
 return {type:'FeatureCollection',features:out,houseDiagnostics:{input:Math.min(inspected,MAX_ROWS),offCorridor:rejected,selected:out.length,official:out.filter(f=>f.properties.official).length,segments:c.segments,capReached:seen.size>MAX_FEATURES,renderer:'native-symbol',offsets:0}};
}
function houseLayer(id,tier,minzoom,theme='dark'){
 return {id,type:'symbol',source:SOURCE,minzoom,filter:['all',['!=',['get','targetDestination'],1],['==',['get','densityTier'],tier]],layout:{
  'symbol-placement':'point','symbol-sort-key':['get','rank'],
  'text-field':['get','label'],'text-font':['Noto Sans Regular'],'text-size':FONT,
  'text-anchor':'center','text-offset':[0,0],'text-rotate':0,
  'text-rotation-alignment':'viewport','text-pitch-alignment':'viewport',
  // Context doorplates yield collision priority to place/community labels.
  'text-max-width':0,'text-padding':5,'text-allow-overlap':false,'text-ignore-placement':true,
  'visibility':'none'
 },paint:{'text-color':theme==='light'?'#59616c':'#aab3bf','text-opacity':.66,
  'text-halo-color':theme==='light'?'#f5f6f8':'#202832','text-halo-width':.65,'text-halo-blur':.2,
  'text-opacity-transition':{duration:120,delay:0}}};
}
function layer(theme='dark'){return houseLayer(LAYER,0,HOUSE_DETAIL_Z[0],theme);}
function additionalLayers(theme='dark'){return [
 houseLayer('extra-house-context-labels',1,HOUSE_DETAIL_Z[1],theme),
 houseLayer('extra-house-detail-labels',2,HOUSE_DETAIL_Z[2],theme),
 houseLayer('extra-house-close-labels',3,HOUSE_DETAIL_Z[3],theme)
];}
function destinationLayer(theme='dark'){
 return {id:'extra-house-destination-label',type:'symbol',source:SOURCE,minzoom:15,filter:['==',['get','targetDestination'],1],layout:{
  'symbol-placement':'point','symbol-sort-key':-1000000,'text-field':['get','label'],'text-font':['Noto Sans Regular'],'text-size':13.5,
  'text-anchor':'center','text-offset':[0,0],'text-rotate':0,'text-rotation-alignment':'viewport','text-pitch-alignment':'viewport',
  'text-max-width':0,'text-padding':4,'text-allow-overlap':true,'text-ignore-placement':true,'visibility':'none'
 },paint:{'text-color':theme==='light'?'#111827':'#ffffff','text-opacity':1,'text-halo-color':theme==='light'?'#ffffff':'#202832','text-halo-width':1.15,'text-halo-blur':.15}};
}
class Renderer {
 constructor(map,{onChange=()=>{}}={}){this.map=map;this.onChange=onChange;this.data=empty();this.signature='';this.wanted=true;this.theme='dark';this.error='';this.installing=false;this.installs=0;this.submits=0;this.revision=0;this.lastQuery=0;this.lastCount=null;this.sourceLoaded=false;this.bound=false;this.progress=null;this.measureTimer=null;}
 init(){if(this.bound)return;this.bound=true;
  this.onStyle=()=>this.ensure();
  this.onData=e=>{if(e.sourceId===SOURCE){this.sourceLoaded=!!e.isSourceLoaded;if(e.isSourceLoaded){this.error='';if(Date.now()-this.lastQuery>=900)this.measure();this.queueMeasure();}}};
  this.onRender=()=>{if(this.wanted&&Date.now()-this.lastQuery>900)this.measure();};
  this.onIdle=()=>{if(this.wanted&&Date.now()-this.lastQuery>=900)this.measure();};
  this.onError=e=>{const msg=String(e.error?.message||e.message||'');if(e.sourceId===SOURCE||msg.includes(SOURCE)||msg.includes(LAYER)){this.error=msg.slice(0,200);this.onChange(this.diagnostics());}};
  for(const e of ['style.load','load','styledata'])this.map.on(e,this.onStyle);
  this.map.on('sourcedata',this.onData);this.map.on('idle',this.onIdle);this.map.on('render',this.onRender);this.map.on('error',this.onError);
  this.ensure();
 }
 ensure(){const m=this.map;if(this.installing)return false;this.installing=true;
  try{
   if(m.getSource(SOURCE)&&m.getLayer(LAYER)&&additionalLayers(this.theme).every(x=>m.getLayer(x.id))&&m.getLayer('extra-house-destination-label'))return true;
   // isStyleLoaded() also waits for ALL sources. The main controller installs
   // asynchronous sources in its earlier style.load handler, making that query
   // false for later handlers. Do NOT gate installation on global source idleness.
   const style=m.getStyle?.();if(!style||!Array.isArray(style.layers))return false;
   let added=false;
   if(!m.getSource(SOURCE)){m.addSource(SOURCE,{type:'geojson',data:this.data,maxzoom:20,buffer:64,tolerance:0,promoteId:'id'});if(!m.getSource(SOURCE))throw Error('門牌資料源未建立');this.submits++;added=true;}
   if(!m.getLayer(LAYER)){const spec=layer(this.theme);spec.layout.visibility=this.wanted?'visible':'none';m.addLayer(spec,m.getLayer('reference-route-casing')?'reference-route-casing':undefined);if(!m.getLayer(LAYER))throw Error('門牌原生文字層未建立');this.installs++;added=true;}
   for(const spec0 of additionalLayers(this.theme)){if(m.getLayer(spec0.id))continue;const spec={...spec0,layout:{...spec0.layout,visibility:this.wanted?'visible':'none'}};m.addLayer(spec,m.getLayer('reference-route-casing')?'reference-route-casing':undefined);if(!m.getLayer(spec.id))throw Error('門牌密度文字層未建立：'+spec.id);added=true;}
   if(!m.getLayer('extra-house-destination-label')){const spec=destinationLayer(this.theme);spec.layout.visibility=this.wanted?'visible':'none';m.addLayer(spec,m.getLayer('reference-route-casing')?'reference-route-casing':undefined);if(!m.getLayer('extra-house-destination-label'))throw Error('目的地門牌文字層未建立');added=true;}
   if(added){this.error='';this.lastCount=null;this.order();this.onChange(this.diagnostics());}
   return true;
  }catch(e){this.error=String(e.message||e).slice(0,200);this.onChange(this.diagnostics());return false;}
  finally{this.installing=false;}
 }
 queueMeasure(){if(this.measureTimer||!this.wanted)return;this.measureTimer=setTimeout(()=>{this.measureTimer=null;if(this.bound&&this.wanted)this.measure();},600);}
 setData(fc){const data={type:'FeatureCollection',features:fc.features||[]},signature=JSON.stringify(data.features);if(signature===this.signature){this.ensure();return false;}
  this.signature=signature;this.data=data;this.revision++;this.sourceLoaded=false;this.lastCount=null;
  const existed=!!this.map.getSource(SOURCE);if(!this.ensure())return false;
  if(existed){try{this.map.getSource(SOURCE).setData(data);this.submits++;}catch(e){this.error=String(e.message||e);this.onChange(this.diagnostics());return false;}}
  this.queueMeasure();return true;
 }
 setVisible(show){const wanted=!!show;if(this.wanted===wanted)return;this.wanted=wanted;
  for(const id of [LAYER,...additionalLayers(this.theme).map(x=>x.id),'extra-house-destination-label'])if(this.map.getLayer(id))try{this.map.setLayoutProperty(id,'visibility',wanted?'visible':'none');}catch(e){this.error=String(e.message||e);}
  if(wanted)this.queueMeasure();
 }
 setTheme(theme){if(this.theme===theme)return;this.theme=theme;for(const spec of [layer(theme),...additionalLayers(theme)])if(this.map.getLayer(spec.id))for(const k of ['text-color','text-halo-color'])this.map.setPaintProperty(spec.id,k,spec.paint[k]);if(this.map.getLayer('extra-house-destination-label')){const paint=destinationLayer(theme).paint;for(const k of ['text-color','text-halo-color'])this.map.setPaintProperty('extra-house-destination-label',k,paint[k]);}}
 setProgress(along){if(!Number.isFinite(along)||this.progress!==null&&Math.abs(along-this.progress)<60)return;this.progress=along;
  const layers=[LAYER,...additionalLayers(this.theme).map(x=>x.id)],opacities=[.66,.66,.66,.66];
  for(let tier=0;tier<layers.length;tier++){const id=layers[tier];if(!this.map.getLayer(id))continue;const ahead=HOUSE_AHEAD[tier]??HOUSE_AHEAD.at(-1),back=Math.max(0,along-35),front=along+ahead;
   this.map.setPaintProperty(id,'text-opacity',['case',['<',['get','along'],back],0,['>',['get','along'],front],0,opacities[tier]]);
  }
 }
 order(){const m=this.map;if(m.getLayer(LAYER)&&m.getLayer('reference-route-casing'))try{
  const group=[LAYER,...additionalLayers(this.theme).map(x=>x.id),'extra-house-destination-label'].filter(id=>m.getLayer(id)),actual=m.getStyle()?.layers?.map(l=>l.id)||[],wanted=actual.filter(id=>!group.includes(id));
  wanted.splice(wanted.indexOf('reference-route-casing'),0,...group);
  if(actual.length===wanted.length&&actual.every((id,i)=>id===wanted[i]))return;
  for(const id of group)m.moveLayer(id,'reference-route-casing');
 }catch(_){} }
 measure(){this.lastQuery=Date.now();if(!this.map.getLayer(LAYER)||!this.wanted){this.lastCount=0;return;}
  try{const fs=this.map.queryRenderedFeatures({layers:[LAYER,...additionalLayers(this.theme).map(x=>x.id).filter(id=>this.map.getLayer(id)),...(this.map.getLayer('extra-house-destination-label')?['extra-house-destination-label']:[])]});this.lastCount=new Set(fs.map(f=>f.id??f.properties?.id)).size;}catch(e){this.error=String(e.message||e).slice(0,200);this.lastCount=null;}
  this.onChange(this.diagnostics());
 }
 diagnostics(){return {renderer:'MapLibre native symbol',source:!!this.map.getSource?.(SOURCE),layer:!!this.map.getLayer?.(LAYER),selected:this.data.features.length,rendered:this.lastCount,sourceLoaded:this.sourceLoaded,installs:this.installs,submits:this.submits,revision:this.revision,error:this.error,canvas:false,offsets:0};}
 destroy(){if(this.measureTimer){clearTimeout(this.measureTimer);this.measureTimer=null;}if(!this.bound)return;for(const e of ['style.load','load','styledata'])this.map.off(e,this.onStyle);this.map.off('sourcedata',this.onData);this.map.off('idle',this.onIdle);this.map.off('render',this.onRender);this.map.off('error',this.onError);this.bound=false;}
}
return Object.freeze({SOURCE,LAYER,FONT,MAX_ROWS,MAX_FEATURES,HOUSE_DENSITY_SPACING,HOUSE_DETAIL_Z,HOUSE_AHEAD,routeKey,compileRoute,features,layer,additionalLayers,destinationLayer,Renderer});
});
