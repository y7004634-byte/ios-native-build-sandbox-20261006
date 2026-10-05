/* 581 v0.3.48 — two modes only: 2D / adaptive 3D.
 * Presentation only: no camera/GPS/network owner, no source-data mutation, no
 * address interpolation or moving anchors. FIT and inset styles are excluded.
 */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.DoorAdaptiveScene=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
'use strict';
const HOUSE='extra-house-labels', GUARD='extra-house-context-labels', SOURCE='extra-house-numbers';
const normalize=s=>String(s||'').replace(/臺/g,'台').replace(/[\s·・]/g,'').toLowerCase();
const AREA_TYPES=new Set(['marketplace','park','university','college','school','kindergarten','campus','cemetery','recreation_ground']);
const copy=v=>v===undefined?null:JSON.parse(JSON.stringify(v));
const equal=(a,b)=>JSON.stringify(a??null)===JSON.stringify(b??null);
function displayName(state={}){const i=state.destinationInfo||{};return String(i.parentName||i.placeName||'').trim();}
function isAreaIntent(state={}){
 const name=normalize(displayName(state));if(!name)return false;
 return (state.placeItems||[]).some(p=>normalize(p.name)===name&&AREA_TYPES.has(String(p.feature||'')));
}
function targetNames(state={}){
 const name=displayName(state), n=normalize(name);if(!n)return [];
 return [...new Set([name,...[...(state.placeItems||[]),...(state.communityItems||[])].filter(p=>normalize(p.name)===n).map(p=>p.name)])];
}
function contextLayer(theme='dark'){
 const dark=theme!=='light';
 return {id:GUARD,type:'symbol',source:SOURCE,minzoom:15,
  filter:['all',['==',['get','nearDestination'],1],['==',['get','densityTier'],0],['!=',['get','targetDestination'],1]],layout:{
   visibility:'none','symbol-placement':'point','symbol-sort-key':['get','rank'],
   'text-field':['get','label'],'text-font':['Noto Sans Regular'],'text-size':10.25,
   'text-anchor':'center','text-offset':[0,0],'text-rotate':0,
   'text-rotation-alignment':'viewport','text-pitch-alignment':'viewport','text-max-width':0,
   // A protected label is not rejected by a roof/POI label's collision box.
   // Co-located/dense real addresses can still overlap: never relocate or invent them.
   'text-allow-overlap':true,'text-ignore-placement':true,'text-padding':1
  },paint:{'text-color':dark?'#c1c8d1':'#414b57','text-opacity':.74,
   'text-halo-color':dark?'#202832':'#f4f6f8','text-halo-width':1.05,'text-halo-blur':.2,
   'text-opacity-transition':{duration:120,delay:0}}};
}
function sceneRules(state={},zoom=18){
 const names=targetNames(state),target=names.length?['in',['get','name'],['literal',names]]:['==',1,0];
 const noDuplicate=names.length?['!',target]:null;
 const ctx=['interpolate',['linear'],['zoom'],16.6,.48,18.1,.56,19.1,.68];
 return {
  target,noDuplicate,
  // Area destinations retain a ground boundary. A matched single building uses
  // the roof accent; no duplicate colored ground sheet over the 3D mass.
  areaFill:['case',target,state.areaDestination ? .055 : (state.exactBuilding ? 0 : .035),0],
  areaLine:['case',target,state.exactBuilding && !state.areaDestination ? .18 : .78,.19],
  areaWidth:['case',target,state.exactBuilding && !state.areaDestination ? .8 : 1.4,.75],
  contextOpacity:ctx,
  hitOpacity:.72,
  mode:'3D 自適應導航',
  zoom
 };
}
class Controller {
 constructor(map,{getState=()=>({}),getNative=()=>null,documentRef=null}={}){
  this.map=map;this.getState=getState;this.getNative=getNative;this.doc=documentRef;
  this.originals=new Map();this.applying=false;this.bound=false;this.active=false;this.error='';
  this.metrics={syncs:0,styleWrites:0,guardInstalls:0,cameraWrites:0,networkRequests:0};
 }
 init(){if(this.bound)return;this.bound=true;
  this.onSync=e=>{if(e?.doorVisualFrame&&!e.doorVisualRefresh)return;this.sync();};
  // styledata may already install us before style.load; do not discard
  // the originals on that later event. Entries are bound to layer identity.
  this.onReload=()=>this.sync();
  for(const e of ['load','zoom','moveend','styledata'])this.map.on(e,this.onSync);
  this.map.on('style.load',this.onReload);this.doc?.addEventListener('visibilitychange',this.onSync);this.sync();
 }
 remember(id,kind,key){
  const k=id+'|'+kind+'|'+(key||'');
  const m=this.map,layerRef=m.getLayer(id),old=this.originals.get(k);
  if(old?.layerRef===layerRef)return;
  const value=kind==='filter'?m.getFilter(id):kind==='layout'?m.getLayoutProperty(id,key):m.getPaintProperty(id,key);
  this.originals.set(k,{id,kind,key,layerRef,value:copy(value)});
 }
 write(id,kind,key,value,remember=true){
  const m=this.map;if(!m.getLayer(id))return;
  if(remember)this.remember(id,kind,key);
  const current=kind==='filter'?m.getFilter(id):kind==='layout'?m.getLayoutProperty(id,key):m.getPaintProperty(id,key);
  if(equal(current,value))return;
  if(kind==='filter')m.setFilter(id,value);else if(kind==='layout')m.setLayoutProperty(id,key,value);else m.setPaintProperty(id,key,value);
  this.metrics.styleWrites++;
 }
 filterWithoutDuplicate(id,exclude){
  if(!this.map.getLayer(id))return;
  this.remember(id,'filter','');const orig=this.originals.get(id+'|filter|').value;
  this.write(id,'filter','',exclude?(orig?['all',orig,exclude]:exclude):orig);
 }
 ensureGuard(){
  if(!this.map.getSource(SOURCE)||this.map.getLayer(GUARD))return;
  this.map.addLayer(contextLayer(this.getState().theme),this.map.getLayer('reference-route-casing')?'reference-route-casing':undefined);
  this.metrics.guardInstalls++;
 }
 order(){
  const m=this.map;if(!m.getLayer(GUARD)||!m.getLayer('reference-route-casing'))return;
  const ids=m.getStyle()?.layers?.map(l=>l.id)||[];
  if(ids.indexOf(GUARD)!==ids.indexOf('reference-route-casing')-1)m.moveLayer(GUARD,'reference-route-casing');
 }
 restore(){
  for(const o of this.originals.values())if(this.map.getLayer(o.id)===o.layerRef)this.write(o.id,o.kind,o.key,copy(o.value),false);
  this.originals.clear();
 }
 sync(){
  if(this.applying)return;this.applying=true;
  try{
   const s=this.getState()||{},z=Number(this.map.getZoom());
   // Do not change the FIT appearance/obstacles or the original mini map.
   const active=!!(s.threeD&&!s.fitLocked&&!this.doc?.hidden);
   const native=this.getNative();if(native)native.adaptiveGuard=active;
   this.active=active;this.metrics.syncs++;
   if(!active){this.restore();this.write(GUARD,'layout','visibility','none',false);return;}
   this.ensureGuard();const r=sceneRules(s,z);
   for(const kind of ['community','place']){
    this.write('main-'+kind+'-fill','paint','fill-opacity',r.areaFill);
    this.write('main-'+kind+'-outline','paint','line-opacity',r.areaLine);
    this.write('main-'+kind+'-outline','paint','line-width',r.areaWidth);
    for(const suffix of ['macro','detail','hit']){
     const id='main-'+kind+'-label-'+suffix;
     this.write(id,'paint','text-opacity',suffix==='hit'?r.hitOpacity:r.contextOpacity);
     this.write(id,'paint','text-halo-width',.9);
     this.filterWithoutDuplicate(id,r.noDuplicate);
     if(suffix==='hit')this.write(id,'layout','text-field',['get','name']);
    }
   }
   // Entrance dots and names stay available as geographic context, not removed.
   this.write('main-entrance-labels','paint','text-opacity',.82);
   const dark=s.theme!=='light';
   this.write(GUARD,'paint','text-color',dark?'#c1c8d1':'#414b57',false);
   this.write(GUARD,'paint','text-halo-color',dark?'#202832':'#f4f6f8',false);
   const visible=!!native?.wanted&&!!s.destination;
   this.write(GUARD,'layout','visibility',visible?'visible':'none',false);
   // The same features are drawn once: ordinary collision layer OR protected
   // neighboring-address layer. Coordinates, size and rotation remain unchanged.
   // Preserve the native density-tier filter; only the sparse tier-0 labels
   // near the destination move to the protected 3D guard layer.
   this.filterWithoutDuplicate(HOUSE,visible?['!=',['get','nearDestination'],1]:null);
   this.order();this.error='';
  }catch(e){this.error=String(e.message||e).slice(0,200);}
  finally{this.applying=false;}
 }
 diagnostics(){return {active:this.active,mode:this.active?'3D 自適應導航':'2D / FIT 原樣',guardLayer:!!this.map.getLayer(GUARD),error:this.error,...this.metrics};}
 destroy(){for(const e of ['load','zoom','moveend','styledata'])this.map.off(e,this.onSync);this.map.off('style.load',this.onReload);this.doc?.removeEventListener('visibilitychange',this.onSync);this.restore();if(this.map.getLayer(GUARD))this.map.removeLayer(GUARD);const n=this.getNative();if(n)n.adaptiveGuard=false;this.bound=false;}
}
return {Controller,GUARD,contextLayer,sceneRules,displayName,isAreaIntent,targetNames};
});
