/* Official Taichung community overlay. Static, versioned, viewport-bounded data only. */
(function(root,factory){const api=factory(root);if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.DoorCommunities=api;})(globalThis,function(root){
 'use strict';
 const VERSION='tcg-community-1150630-v2',BASE='/offline/taichung-community-1150630-v2',SOURCE='official-communities';
 const SCOPE={community:'已核對社區範圍',building:'已確認建物（非完整社區範圍）',point:'官方門牌位置（非入口）'};
 const IDS=['official-community-fill','official-community-outline','official-building-outline','official-community-point','official-community-entrance','official-community-label'];
 const Core=root.DoorSearchCore||(typeof require==='function'?require('./search-core.js'):null);
 let manifest=null,manifestPending=null,searchRows=null,searchPending=null;
 const memory=new Map(),inflight=new Map(),retryAfter=new Map();
 const counters={networkRequests:0,cacheHits:0,sourceWrites:0,sourceSkips:0};
 const empty=()=>({type:'FeatureCollection',features:[]});
 const validPoint=p=>Array.isArray(p)&&p.length>=2&&Number.isFinite(p[0])&&Number.isFinite(p[1])&&p[0]>=119&&p[0]<=122&&p[1]>=23&&p[1]<=25;
 function validateFeatures(data){
  if(data?.version!==VERSION||data.type!=='FeatureCollection'||!Array.isArray(data.features))throw Error('社區圖資版本不符');
  const ids=new Set();
  for(const f of data.features){
   const p=f?.properties,g=f?.geometry;
   if(!f.id||ids.has(f.id)||!p?.communityId||!p.name||!SCOPE[p.scope]||p.source!=='tcg-official-community')throw Error('社區圖資識別不符');
   ids.add(f.id);
   if(p.role==='shape'){
    if(!['community','building'].includes(p.scope)||!['Polygon','MultiPolygon'].includes(g?.type)||!p.osmId)throw Error('社區範圍證據不符');
    const polygons=g.type==='Polygon'?[g.coordinates]:g.coordinates;
    if(!Array.isArray(polygons)||!polygons.length||polygons.some(poly=>!Array.isArray(poly)||!poly.length||poly.some(r=>!Array.isArray(r)||r.length<4||!r.every(validPoint)||JSON.stringify(r[0])!==JSON.stringify(r[r.length-1]))))throw Error('社區幾何不完整');
    if(p.scope==='community'&&p.evidenceRule!=='osm_name_and_all_gis_addresses_contained')throw Error('缺少社區範圍核對');
    if(p.scope==='building'&&p.evidenceRule!=='unique_building_contains_official_address')throw Error('缺少建物核對');
   }else if(!['label','entrance'].includes(p.role)||g?.type!=='Point'||!validPoint(g.coordinates))throw Error('社區位置不完整');
   if(p.role==='entrance'&&(!p.entranceVerified||!p.osmId||p.evidenceRule!=='exact_permit_address_and_confirmed_geometry'))throw Error('入口來源不完整');
  }
  return data;
 }
 function db(action,key,value){return new Promise((resolve,reject)=>{
  if(!root.indexedDB)return resolve(null);
  const op=root.indexedDB.open('581-official-community-v1',1);
  op.onupgradeneeded=()=>{if(!op.result.objectStoreNames.contains('files'))op.result.createObjectStore('files');};
  op.onerror=()=>reject(op.error);
  op.onsuccess=()=>{const conn=op.result,tx=conn.transaction('files',action==='get'?'readonly':'readwrite'),store=tx.objectStore('files'),q=action==='get'?store.get(key):store.put(value,key);let result=null;q.onsuccess=()=>{result=q.result;};tx.oncomplete=()=>{conn.close();resolve(result);};tx.onerror=tx.onabort=()=>{conn.close();reject(tx.error);};};
 });}
 async function digest(buffer){if(!root.crypto?.subtle)throw Error('社區圖資完整性驗證不可用');return [...new Uint8Array(await root.crypto.subtle.digest('SHA-256',buffer))].map(x=>x.toString(16).padStart(2,'0')).join('');}
 async function getManifest(){
  if(manifest)return manifest;if(manifestPending)return manifestPending;
  if(Date.now()<(retryAfter.get('manifest')||0))throw Error('社區索引暫時無法讀取');
  manifestPending=(async()=>{let d=await db('get',VERSION+'|manifest').catch(()=>null);if(d?.version===VERSION&&d.tileZoom===14&&d.tiles&&d.searchIndex)counters.cacheHits++;else{counters.networkRequests++;const r=await fetch(BASE+'/manifest.json?v='+VERSION,{cache:'no-cache'});if(!r.ok)throw Error('社區索引 HTTP '+r.status);d=await r.json();if(d.version!==VERSION||d.tileZoom!==14||!d.tiles||!d.searchIndex)throw Error('社區索引格式不符');await db('put',VERSION+'|manifest',d).catch(()=>{});}manifest=d;return d;})();
  try{return await manifestPending;}catch(e){retryAfter.set('manifest',Date.now()+60000);throw e;}finally{manifestPending=null;}
 }
 async function file(meta){
  if(!meta?.path?.startsWith(BASE.slice(1)+'/')||meta.path.includes('..')||!/^[a-f0-9]{64}$/.test(meta.sha256))throw Error('社區檔案路徑不符');
  const key=VERSION+'|'+meta.path+'|'+meta.sha256;
  if(memory.has(key)){const data=memory.get(key);memory.delete(key);memory.set(key,data);counters.cacheHits++;return data;}
  if(inflight.has(key))return inflight.get(key);
  if(Date.now()<(retryAfter.get(key)||0))throw Error('社區圖資暫時無法讀取');
  const task=(async()=>{
   const saved=await db('get',key).catch(()=>null);let data;
   if(saved?.sha256===meta.sha256&&saved.data?.version===VERSION){data=saved.data;counters.cacheHits++;}
   else{counters.networkRequests++;const r=await fetch('/'+meta.path+'?v='+VERSION,{cache:'force-cache'});if(!r.ok)throw Error('社區圖資 HTTP '+r.status);const bytes=await r.arrayBuffer();if(bytes.byteLength!==meta.bytes||await digest(bytes)!==meta.sha256)throw Error('社區圖資完整性檢查失敗');data=JSON.parse(new TextDecoder().decode(bytes));if(data.version!==VERSION)throw Error('社區圖資版本不符');await db('put',key,{sha256:meta.sha256,data}).catch(()=>{});}
   memory.set(key,data);while(memory.size>24)memory.delete(memory.keys().next().value);return data;
  })();inflight.set(key,task);try{return await task;}catch(e){retryAfter.set(key,Date.now()+60000);throw e;}finally{inflight.delete(key);}
 }
 async function ensureSearch(){
  if(searchRows)return searchRows;if(searchPending)return searchPending;
  searchPending=(async()=>{const m=await getManifest(),d=await file(m.searchIndex);if(!Array.isArray(d.rows))throw Error('社區搜尋索引不符');const seen=new Set(),owners=new Map();for(const r of d.rows){if(!r.communityId||seen.has(r.communityId)||!r.displayName||!SCOPE[r.scope]||r.source!=='official-community'||!validPoint([r.lng,r.lat]))throw Error('社區搜尋資料不完整');seen.add(r.communityId);const aliases=r.osmAliases||[],sources=r.identitySources||[],evidence=r.identityEvidence||[];if(new Set(aliases).size!==aliases.length||sources.length>aliases.length||evidence.length!==aliases.length)throw Error('社區身分來源不完整');for(const id of aliases){if(!/^(node|way|relation)\/\d+$/.test(id)||owners.has(id)||!(sources.filter(s=>s.osmKey===id&&s.source==='offline-index'&&s.displayName&&validPoint([s.lng,s.lat])).length===1||evidence.some(e=>e.osmId===id&&e.retainedOutsideBaselineIndex&&e.containedAddressKeys?.length))||evidence.filter(e=>e.osmId===id&&e.rule).length!==1)throw Error('社區身分歸屬不唯一');owners.set(id,r.communityId);}}searchRows=d.rows;return searchRows;})();
  try{return await searchPending;}finally{searchPending=null;}
 }
 async function search(query,center=null,limit=Infinity){if(!String(query||'').trim()||!Core)return [];return Core.rankResults([await ensureSearch()],query,center).slice(0,limit);}
 function tileXY(lng,lat,z=14){return [Math.floor((lng+180)/360*2**z),Math.floor((1-Math.asinh(Math.tan(lat*Math.PI/180))/Math.PI)/2*2**z)];}
 function viewportKeys(bounds,tiles){
  const [x1,y2]=tileXY(bounds.west,bounds.south),[x2,y1]=tileXY(bounds.east,bounds.north);
  if(x2<x1||y2<y1||x2-x1>12||y2-y1>12)return [];
  const out=[];for(let x=x1;x<=x2;x++)for(let y=y1;y<=y2;y++)if(tiles[x+'/'+y])out.push(x+'/'+y);return out;
 }
 function uniqueFeatures(groups){return [...new Map(groups.flatMap(d=>d.features).map(f=>[f.id,f])).values()];}
 function createLayers(){return [
  {id:IDS[0],type:'fill',source:SOURCE,filter:['==',['get','role'],'shape'],paint:{'fill-color':['case',['==',['get','scope'],'community'],'#30b99b','#e6ad4b'],'fill-opacity':0.12}},
  {id:IDS[1],type:'line',source:SOURCE,filter:['all',['==',['get','role'],'shape'],['==',['get','scope'],'community']],paint:{'line-color':'#30b99b','line-width':2}},
  {id:IDS[2],type:'line',source:SOURCE,filter:['all',['==',['get','role'],'shape'],['==',['get','scope'],'building']],paint:{'line-color':'#e6ad4b','line-width':1.6,'line-dasharray':[3,2]}},
  {id:IDS[3],type:'circle',source:SOURCE,filter:['==',['get','role'],'label'],paint:{'circle-radius':4,'circle-color':'#ecfff7','circle-stroke-color':'#278674','circle-stroke-width':2}},
  {id:IDS[4],type:'circle',source:SOURCE,filter:['==',['get','role'],'entrance'],minzoom:17,paint:{'circle-radius':4,'circle-color':'#62e3bc','circle-stroke-color':'#123d33','circle-stroke-width':1}},
  {id:IDS[5],type:'symbol',source:SOURCE,filter:['==',['get','role'],'label'],layout:{'text-field':['get','name'],'text-font':['Noto Sans Regular'],'text-size':12,'text-offset':[0,1.1],'text-anchor':'top','text-padding':5,'text-allow-overlap':false,'text-ignore-placement':false,'text-max-width':12},paint:{'text-color':'#b4f3e3','text-halo-color':'#152c28','text-halo-width':1.7}}
 ];}
 class Controller{
  constructor(map,{select=()=>{},documentRef=root.document}={}){this.map=map;this.select=select;this.doc=documentRef;this.timer=null;this.sequence=0;this.data=empty();this.key=null;this.error='';this.selected='';this.disposed=false;this.popup=null;this.currentKeys=[];}
  init(){
   this.changed=e=>{if(!root.DoorVisualMotion||root.DoorVisualMotion.sceneEvent(e))this.queue();};this.style=()=>{this.key=null;this.ensureLayers();this.queue();};this.visibility=()=>{if(!this.doc?.hidden)this.queue();else{clearTimeout(this.timer);this.sequence++;}};
   this.map.on('moveend',this.changed);this.map.on('style.load',this.style);this.map.on('load',this.style);this.doc?.addEventListener('visibilitychange',this.visibility);
   this.click=e=>this.open(e);for(const id of [IDS[0],IDS[3],IDS[5]])this.map.on('click',id,this.click);
   this.style();return this;
  }
  ensureLayers(){if(this.disposed||(!this.map.getStyle?.()?.sources&&!this.map.isStyleLoaded?.()))return;try{if(!this.map.getSource(SOURCE))this.map.addSource(SOURCE,{type:'geojson',data:this.data,attribution:'社區：臺中市政府開放資料 · 輪廓 © OpenStreetMap contributors (ODbL)'});for(const layer of createLayers())if(!this.map.getLayer(layer.id))this.map.addLayer({...layer,minzoom:layer.minzoom||15});}catch(e){this.error=String(e.message||e);}}
  queue(){clearTimeout(this.timer);if(this.doc?.hidden||this.disposed)return;this.timer=setTimeout(()=>this.refresh(),350);}
  apply(data){const key=data.features.map(f=>f.id).sort().join('|');if(key===this.key){counters.sourceSkips++;return;}this.key=key;this.data=data;const source=this.map.getSource(SOURCE);if(source){source.setData(data);counters.sourceWrites++;}}
  async refresh(){
   const seq=++this.sequence;if(this.doc?.hidden||this.disposed)return;
   this.ensureLayers();if(this.map.getZoom()<15){this.currentKeys=[];this.apply(empty());return;}
   try{
    const m=await getManifest();if(seq!==this.sequence||this.doc?.hidden)return;
    const b=this.map.getBounds(),keys=viewportKeys({west:b.getWest(),east:b.getEast(),south:b.getSouth(),north:b.getNorth()},m.tiles);this.currentKeys=keys;
    const groups=[],failures=[];let next=0;
    const work=async()=>{while(next<keys.length){if(seq!==this.sequence||this.doc?.hidden||this.disposed)return;const key=keys[next++];try{groups.push(validateFeatures(await file(m.tiles[key])));}catch(e){failures.push({key,error:String(e.message||e)});}}};
    await Promise.all([work(),work()]);if(seq!==this.sequence||this.doc?.hidden||this.disposed)return;
    if(groups.length||!failures.length)this.apply({type:'FeatureCollection',features:uniqueFeatures(groups)});this.error=failures.length?'部分社區瓦片暫時無法讀取（'+failures.length+'）':'';
   }catch(e){if(seq===this.sequence)this.error=String(e.message||e);}
  }
  open(e){
   const feature=e.features?.[0];if(!feature)return;const p=feature.properties,doc=this.doc;if(!doc||!root.maplibregl?.Popup)return;
   const box=doc.createElement('div');box.className='official-community-card';box.style.cssText='font:13px/1.5 sans-serif;max-width:260px;color:#152c28';
   const title=doc.createElement('strong');title.textContent=p.name;box.append(title);
   for(const line of [SCOPE[p.scope],p.address,'使照：'+p.fullLicenses]){const el=doc.createElement('div');el.textContent=line;box.append(el);}
   const source=doc.createElement('a');source.href='https://thd.taichung.gov.tw/1041716/post';source.target='_blank';source.rel='noopener';source.textContent='官方名冊與來源';box.append(source);
   const credit=doc.createElement('div');credit.textContent='臺中市政府開放資料；輪廓 © OSM／ODbL';credit.style.fontSize='11px';box.append(credit);
   this.popup?.remove();this.popup=new root.maplibregl.Popup({closeButton:true,maxWidth:'290px'}).setLngLat(e.lngLat).setDOMContent(box).addTo(this.map);
  }
  diagnostics(){return {version:VERSION,features:this.data.features.length,communities:new Set(this.data.features.map(f=>f.properties.communityId)).size,scopes:[...new Set(this.data.features.map(f=>f.properties.scope))],visibleTileCount:this.currentKeys.length,error:this.error,selected:this.selected,...counters};}
  destroy(){this.disposed=true;this.sequence++;clearTimeout(this.timer);this.map.off('moveend',this.changed);this.map.off('style.load',this.style);this.map.off('load',this.style);for(const id of [IDS[0],IDS[3],IDS[5]])this.map.off('click',id,this.click);this.doc?.removeEventListener('visibilitychange',this.visibility);this.popup?.remove();}
 }
 return {VERSION,BASE,SOURCE,IDS,SCOPE,validateFeatures,viewportKeys,uniqueFeatures,createLayers,ensureSearch,search,Controller,diagnostics:()=>({searchRows:searchRows?.length||0,cacheEntries:memory.size,...counters})};
});
