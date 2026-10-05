/* Extra map layers. All station work is gated behind an explicit, default-OFF toggle. */
(function(root){'use strict';
const E=root.DoorExtras,empty=()=>({type:'FeatureCollection',features:[]});
class MapExtras {
 constructor({map,getState,offlineHouses,navigateStation,pauseCamera,notify}){
  Object.assign(this,{map,getState,offlineHouses,navigateStation,pauseCamera,notify});
  this.stationOn=false;this.stationRows=[];this.stationFetchedAt=0;this.stationSeq=0;this.navSeq=0;
  this.houseCache=new Map();this.houseControllers=new Set();this.housePending=new Set();this.houseRetry=new Map();
  this.houseRenderAt=0;this.houseFetchAt=-Infinity;this.houseKey='';this.houseReadKey='';this.offlineRows=[];
  this.visibleHouseTiles=[];this.houseEpoch=0;this.busy=false;this.selected=null;this.houseStatus='門牌：等待視野';this.houseStatusResult=null;this.houseStatusSeq=0;
  this.idb=null;this.bound=false;this.housePaintTimer=null;this.houseFetchTimer=null;this.houseLayoutStats=null;this.houseBaseLayers=[];this.houseLayerFallback=false;this.native=null;this.nativeRouteKey='';this.nativeCompiled=null;this.houseReadCell='';this.houseRefreshPending=false;this.houseCheckAt=0;this.houseInputRefs=null;this.nativeRouteRef=null;this.nativeDestKey='';this.vectorRevision=0;this.vectorCacheRevision=-1;this.vectorCacheRows=[];this.vectorViewKey='';this.perf={builds:0,skips:0,vectorReads:0,lastBuildMs:0,totalBuildMs:0};
 }
 init(){
  this.toggle=document.getElementById('gogoroToggle');this.status=document.getElementById('gogoroStatus');this.panel=document.getElementById('gogoroPanel');
  this.toggle.checked=false;
  this.toggle.addEventListener('change',()=>this.setStationOn(this.toggle.checked));
  document.getElementById('gogoroRefreshBtn').addEventListener('click',()=>{if(this.stationOn)this.loadStations(true);});
  document.getElementById('gogoroCloseBtn').addEventListener('click',()=>this.closeStation());
  document.getElementById('gogoroViaBtn').addEventListener('click',()=>this.goStation('via'));
  document.getElementById('gogoroDirectBtn').addEventListener('click',()=>this.goStation('direct'));
  this.native=new root.DoorNativeHouses.Renderer(this.map,{onChange:d=>{if(this.houseStatusResult?.kind==='ok'){this.houseStatusResult.rendered=d.rendered;this.showHouseStatus();}}});this.native.init();
  this.map.on('load',()=>this.ensureLayers());this.map.on('style.load',()=>this.ensureLayers());
  this.map.on('moveend',e=>{if(root.DoorVisualMotion&&!root.DoorVisualMotion.sceneEvent(e))return;this.syncHouseVisibility();this.maybeReadHouses(true);});
  // Native symbols transform on MapLibre's own render frames. Camera events never
  // run screen-space house layout, project points, set offsets, or resubmit data.
  this.map.on('move',e=>{if(root.DoorVisualMotion&&!root.DoorVisualMotion.sceneEvent(e))return;this.syncHouseVisibility();this.maybeReadHouses();});
  this.map.on('zoom',e=>{if(root.DoorVisualMotion&&!root.DoorVisualMotion.sceneEvent(e))return;const view=this.syncHouseVisibility();if(!view.active)this.cancelHouseWork();});
  this.map.on('sourcedata',e=>{
   if(e.sourceId==='reference-route'){
    const state=this.getState(),route=state.houseRoute||state.route||[];
    if(route!==this.houseRouteRef||state.destination!==this.houseDestRef){this.houseRouteRef=route;this.houseDestRef=state.destination;this.scheduleHousePaint();this.scheduleHouses();}
   }
   if(e.sourceId===this.houseVectorSource&&e.sourceDataType!=='visibility'&&(e.sourceDataType==='content'||e.tile||e.isSourceLoaded)){this.vectorRevision++;this.scheduleHousePaint();}
  });
  document.addEventListener('visibilitychange',()=>{
   if(document.hidden){if(this.houseTimer)clearTimeout(this.houseTimer);this.houseTimer=null;this.native?.setVisible(false);this.cancelHouseWork();this.stationController?.abort();this.navSeq++;this.busy=false;}
   else{this.scheduleHouses();if(this.panel&&!this.panel.hidden)this.syncStationButtons();if(this.stationOn&&!this.stationRows.length)this.loadStations();}
  });
  this.syncStationUi();this.ensureLayers();this.scheduleHousePaint();
 }
 ensureLayers(){
  this.native?.ensure();this.vectorRevision++;
  const m=this.map,style=m.getStyle?.();if(!style||!Array.isArray(style.layers))return;
  const layers=style.layers;
  this.houseVectorSource=layers.find(l=>l['source-layer']==='housenumber')?.source||layers.find(l=>l['source-layer']==='transportation')?.source;
  const base=layers.filter(l=>l['source-layer']==='housenumber'&&l.type==='symbol'&&l.id!=='extra-house-labels');
  for(const l of base)if(!this.houseBaseLayers.some(x=>x.id===l.id))this.houseBaseLayers.push({id:l.id,visibility:m.getLayoutProperty(l.id,'visibility')||'visible'});
  this.syncBaseHouseLayers();if(this.stationOn)this.ensureStationLayers();
  this.setTheme(this.getState().theme);this.scheduleHouses();
 }
 ensureStationLayers(){
  if(!this.stationOn)return;const m=this.map;if(!m.getStyle()?.layers)return;
  if(!m.getSource('extra-gogoro'))m.addSource('extra-gogoro',{type:'geojson',data:empty(),cluster:true,clusterRadius:42,clusterMaxZoom:14});
  const common={source:'extra-gogoro'};
  const layers=[
   {id:'extra-gogoro-clusters',type:'circle',...common,filter:['has','point_count'],paint:{'circle-color':'#438464','circle-radius':17,'circle-stroke-width':1.5,'circle-stroke-color':'#d2dfd6','circle-opacity':.94}},
   {id:'extra-gogoro-count',type:'symbol',...common,filter:['has','point_count'],layout:{'text-field':['concat',['to-string',['get','point_count']],'站'],'text-font':['Noto Sans Regular'],'text-size':11.5,'text-allow-overlap':true},paint:{'text-color':'#edf4ef'}},
   {id:'extra-gogoro-points',type:'circle',...common,filter:['!', ['has','point_count']],paint:{'circle-color':['case',['==',['get','unavailable'],true],'#7c8189','#57a17a'],'circle-radius':7.5,'circle-stroke-width':1.5,'circle-stroke-color':'#d0e1d7'}},
   {id:'extra-gogoro-hit',type:'circle',...common,filter:['!', ['has','point_count']],paint:{'circle-radius':22,'circle-opacity':0}},
   {id:'extra-gogoro-names',type:'symbol',...common,minzoom:15,filter:['!', ['has','point_count']],layout:{'text-field':['get','name'],'text-font':['Noto Sans Regular'],'text-size':11,'text-anchor':'top','text-offset':[0,1.1],'text-max-width':10,'text-allow-overlap':false},paint:{'text-color':'#bbd6c6','text-halo-color':'#252b34','text-halo-width':1.2}}
  ];for(const l of layers)if(!m.getLayer(l.id))m.addLayer(l);
  if(!this.bound){this.bound=true;
   const pick=e=>{if(document.body.dataset.routeEditing==='1'||!this.stationOn)return;e.originalEvent?.stopPropagation?.();const id=e.features?.[0]?.properties?.id;this.openStation(String(id));};
   m.on('click','extra-gogoro-hit',pick);m.on('click','extra-gogoro-names',pick);
   m.on('click','extra-gogoro-clusters',async e=>{if(document.body.dataset.routeEditing==='1')return;if(!this.stationOn)return;const f=e.features?.[0];if(!f)return;const seq=this.stationSeq;try{const z=await m.getSource('extra-gogoro').getClusterExpansionZoom(f.properties.cluster_id);if(!this.stationOn||seq!==this.stationSeq)return;this.pauseCamera();m.easeTo({center:f.geometry.coordinates,zoom:z,duration:450});}catch(_){}});
  }
  this.applyStationData();
 }
 order(){this.native?.order();const m=this.map;for(const id of ['extra-gogoro-clusters','extra-gogoro-count','extra-gogoro-points','extra-gogoro-hit','extra-gogoro-names'])if(m.getLayer(id)){try{m.moveLayer(id,m.getLayer('reference-route-casing')?'reference-route-casing':undefined);}catch(_){}}}
 setTheme(theme){this.order();this.native?.setTheme(theme);}
 setHouseStatus(text){this.houseStatus=text;const el=document.getElementById('houseLayerStatus');if(el&&el.textContent!==text)el.textContent=text;}
 houseSpan(view=this.houseViewState){return view?.viewWidthM?` · 街區橫幅約 ${Math.round(view.viewWidthM)}m`:'';}
 showHouseStatus(view=this.houseViewState){
  if(!view)return this.setHouseStatus('門牌：等待有效地圖視野');
  const span=this.houseSpan(view);
  if(!view.active){this.houseStatusResult=null;return this.setHouseStatus(view.reason+span);}
  if(this.native?.error)return this.setHouseStatus(`原生門牌圖層：${this.native.error}${span}`);
  const r=this.houseStatusResult,mode=view.mode==='route'?'路徑兩側':'近距離',detail=view.originalDetail?' · 原始底圖／NLSC 同步':'';
  if(!r)return this.setHouseStatus(`${mode}門牌已啟用${detail}${span} · 準備原生門牌資料`);
  if(r.kind==='ok'){
   const source=r.officialCount?` · 官方 GIS ${r.officialCount} 筆（2026-08）`:' · OSM／已下載索引';
   const render=Number.isFinite(r.rendered)?(r.rendered===0?' · 引擎可見 0 筆（可能避讓／視野外／字型尚未就緒）':` · 引擎可見 ${r.rendered} 筆`):' · 原生圖層載入中';
   return this.setHouseStatus(`${mode}門牌資料 ${r.selected} 筆${source}${span}${detail} · 固定座標／正向小字${render}`);
  }
  if(r.kind==='filtered')return this.setHouseStatus(`此視野讀到門牌 ${r.nearby} 筆，但路徑兩側範圍內為 0 筆${span}${detail}`);
  if(r.kind==='load-error'||r.kind==='read-error')return this.setHouseStatus(`門牌載入失敗；保留既有資料，可稍後重試${span}${detail}`);
  if(r.kind==='paint-error')return this.setHouseStatus(`門牌排版失敗；原始門牌／小地圖仍可使用${span}${detail}`);
  return this.setHouseStatus(`此視野尚未讀到門牌${span}${detail}；近距離仍保留自製門牌`);
 }
 cancelHouseWork(){this.houseEpoch++;for(const c of this.houseControllers)c.abort();if(this.housePaintTimer){clearTimeout(this.housePaintTimer);this.housePaintTimer=null;}if(this.houseFetchTimer){clearTimeout(this.houseFetchTimer);this.houseFetchTimer=null;}}
 houseOptions(){const v=this.view(),state=this.getState();return {...v,zoom:this.map.getZoom(),route:state.route||[],position:state.position,destination:state.destination,project:p=>this.map.project(p)};}
 syncBaseHouseLayers(view=this.houseViewState||E.houseView(this.houseOptions())){
  const show=!!view?.originalDetail&&!document.hidden,m=this.map;
  for(const item of this.houseBaseLayers){if(!m.getLayer(item.id))continue;const want=show?item.visibility:'none';try{if(m.getLayoutProperty(item.id,'visibility')!==want)m.setLayoutProperty(item.id,'visibility',want);}catch(_){}}
 }
 syncHouseVisibility(options=this.houseOptions()){
  const view=E.houseView(options),m=this.map;this.houseViewState=view;
  this.native?.setVisible(view.active&&!document.hidden);
  if(view.active&&!this.houseViewWasActive){this.houseViewWasActive=true;this.scheduleHouses();}else if(!view.active)this.houseViewWasActive=false;
  this.syncBaseHouseLayers(view);
  this.showHouseStatus(view);
  return view;
 }
 scheduleHousePaint(){
  if(document.hidden||this.housePaintTimer)return;
  this.housePaintTimer=setTimeout(()=>{this.housePaintTimer=null;try{this.paintHouses();}catch(e){this.houseStatusResult={kind:'paint-error',error:String(e),selected:0,officialCount:0,nearby:0,rendered:null};this.showHouseStatus();}},Math.max(0,800-(Date.now()-this.houseRenderAt)));
 }
 maybeReadHouses(force=false){
  if(document.hidden||!this.houseViewState?.active||(!force&&Date.now()-this.houseCheckAt<750))return;
  this.houseCheckAt=Date.now();const v=this.view(),keys=E.tilesForView(v.bounds,v.center).map(t=>t.key).sort().join('|');
  if(keys!==this.houseReadCell){this.houseReadCell=keys;this.scheduleHouses();}
 }
 scheduleHouses(){if(this.houseTimer||document.hidden)return;this.houseTimer=setTimeout(()=>{this.houseTimer=null;this.refreshHouses().catch(e=>{this.houseStatusResult={kind:'read-error',error:String(e),selected:0,officialCount:0,nearby:0,rendered:null};this.showHouseStatus();});},160);}
 view(){
  const c=this.map.getCenter(),r=this.map.getContainer().getBoundingClientRect();let b;
  try{const q=this.map.getBounds();b={west:q.getWest(),east:q.getEast(),north:q.getNorth(),south:q.getSouth()};}catch(_){b={west:c.lng-.008,east:c.lng+.008,south:c.lat-.008,north:c.lat+.008};}
  // Use camera zoom/latitude for the street-width gate. unproject() on a pitched
  // navigation view can report ~700m repeatedly even while the user pinches in.
  const center={lat:c.lat,lng:c.lng},viewWidthM=E.viewWidthMeters(center,this.map.getZoom(),r.width);
  return {center,width:r.width,height:r.height,bounds:b,viewWidthM};
 }
 houseObstacles(){
  const outer=this.map.getContainer().getBoundingClientRect(),out=[];
  for(const id of ['topHud','insetCard','controls','gogoroPanel','routeEditPanel']){
   const el=document.getElementById(id);if(!el||el.hidden)continue;
   const r=el.getBoundingClientRect();if(r.width<=0||r.height<=0)continue;
   out.push({left:r.left-outer.left-3,right:r.right-outer.left+3,top:r.top-outer.top-3,bottom:r.bottom-outer.top+3});
  }
  return out;
 }
 diagnostics(){return {zoom:this.map.getZoom(),view:this.houseViewState||null,layout:this.houseLayoutStats,...(this.native?.diagnostics()||{}),localTiles:this.visibleHouseTiles.length,requests:this.housePending.size,work:{...this.perf}};}
 vectorRows(){
  if(this.vectorCacheRevision===this.vectorRevision)return this.vectorCacheRows;
  this.perf.vectorReads++;this.vectorCacheRevision=this.vectorRevision;
  if(!this.houseVectorSource||!this.map.querySourceFeatures)return this.vectorCacheRows;
  try{const rows=this.map.querySourceFeatures(this.houseVectorSource,{sourceLayer:'housenumber'}).filter(f=>f.geometry.type==='Point').map(f=>({lng:f.geometry.coordinates[0],lat:f.geometry.coordinates[1],houseNumber:String(f.properties.housenumber||f.properties['addr:housenumber']||''),source:'OpenMapTiles / OSM'}));
   rows.sort((a,b)=>a.lng-b.lng||a.lat-b.lat||a.houseNumber.localeCompare(b.houseNumber));const key=JSON.stringify(rows);
   if(this.vectorDataKey!==key){this.vectorDataKey=key;this.vectorCacheRows=rows;}
  }catch(_){}return this.vectorCacheRows;
 }
 updateHouseProgress(state){if(this.nativeCompiled&&E.point(state.position)){const pos=this.nativeCompiled.classify(state.position);if(Number.isFinite(pos.distance)&&pos.distance<80)this.native.setProgress(pos.along);}}

 paintHouses(){
  root.DoorPowerDiag?.mark?.('houseBuildAttempt');
  const options=this.houseOptions(),view=this.syncHouseVisibility(options);if(document.hidden||!view.active)return;
  const state=this.getState(),route=state.houseRoute||state.route||[],destKey=state.destination?`${state.destination.lng},${state.destination.lat}`:'';
  const destinationHouse=String(state.destinationInfo?.houseNumber||'').replace(/號$/,'').trim(),destinationRoad=String(state.destinationInfo?.road||'').trim();
  const vector=this.vectorRows(),tiles=this.visibleHouseTiles.slice().sort((a,b)=>a.key.localeCompare(b.key)),tileKey=tiles.map(t=>t.key).join('|');
  const refs=[this.offlineRows,state.addresses,vector,route,destKey,destinationHouse,destinationRoad,tileKey,...tiles.map(t=>this.houseCache.get(t.key)?.rows)];
  // All geometry inputs are immutable snapshots; identical references mean the
  // same world-space labels. Pan/zoom/bearing are handled natively by MapLibre.
  if(this.houseStatusResult&&this.houseInputRefs&&refs.length===this.houseInputRefs.length&&refs.every((v,i)=>v===this.houseInputRefs[i])){
   this.perf.skips++;root.DoorPowerDiag?.mark?.('houseBuildSkip');this.updateHouseProgress(state);this.native.ensure();this.showHouseStatus(view);return;
  }
  const started=performance.now();
  if(route!==this.nativeRouteRef||destKey!==this.nativeDestKey||!this.nativeCompiled){this.nativeRouteRef=route;this.nativeDestKey=destKey;this.nativeRouteKey=root.DoorNativeHouses.routeKey(route,state.destination);this.nativeCompiled=root.DoorNativeHouses.compileRoute(route,state.destination);}
  const rows=[...this.offlineRows,...(state.addresses||[]),...vector];
  for(const t of tiles)rows.push(...(this.houseCache.get(t.key)?.rows||[]));
  root.DoorPowerDiag?.mark?.('houseBuild');
  const fc=root.DoorNativeHouses.features(rows,{compiled:this.nativeCompiled,destinationHouse,destinationRoad});
  this.houseLayoutStats=fc.houseDiagnostics;this.houseRenderAt=Date.now();
  const changed=this.native.setData(fc),d=this.native.diagnostics();
  this.updateHouseProgress(state);this.houseInputRefs=refs;this.perf.builds++;this.perf.lastBuildMs=performance.now()-started;this.perf.totalBuildMs+=this.perf.lastBuildMs;
  this.houseStatusResult=fc.features.length?{kind:'ok',selected:fc.features.length,officialCount:fc.houseDiagnostics.official,nearby:rows.length,rendered:changed?null:d.rendered}:
   (this.houseLoadError?{kind:'load-error',nearby:rows.length}:rows.length?{kind:'filtered',nearby:rows.length}:{kind:'empty',nearby:0});
  this.showHouseStatus(view);
 }
 async refreshHouses(){
  root.DoorPowerDiag?.mark?.('houseReadAttempt');
  if(this.houseRefreshPending){this.houseReadAgain=true;return;}
  this.houseRefreshPending=true;
  try{await this.readHouses();}finally{this.houseRefreshPending=false;if(this.houseReadAgain){this.houseReadAgain=false;this.scheduleHouses();}}
 }
 async readHouses(){
  const options=this.houseOptions(),view=this.syncHouseVisibility(options);if(document.hidden||!view.active)return;
  const z=options.zoom,v=options;if(!E.point(v.center))return;const tiles=E.tilesForView(v.bounds,v.center);this.visibleHouseTiles=tiles;
  const key=tiles.map(t=>t.key).sort().join('|');
  const vectorKey=`${key}|${Math.floor(z)}`;if(this.vectorViewKey!==vectorKey){this.vectorViewKey=vectorKey;this.vectorRevision++;}
  if(key!==this.houseReadKey){this.houseOfflineReadAt=Date.now();this.houseReadKey=key;const current=key;try{root.DoorPowerDiag?.mark?.('houseRead');const rows=await this.offlineHouses(v.center,1100);if(this.houseReadKey===current)this.offlineRows=rows;}catch(_){}}
  if(root.DoorOfficial){
   const missingLocal=tiles.filter(t=>!this.houseCache.has(t.key));
   if(missingLocal.length){root.DoorPowerDiag?.mark?.('houseRead');const current=key,local=await root.DoorOfficial.cachedTiles(missingLocal.map(t=>t.key)).catch(()=>[]);
    if(this.houseReadKey===current&&!document.hidden)for(const tile of local){this.houseCache.set(tile.tile,{rows:tile.rows,fetchedAt:Date.now()});while(this.houseCache.size>12)this.houseCache.delete(this.houseCache.keys().next().value);}
   }
  }
  // Local data arrival must paint even at the same center/zoom: no stale render-key gate.
  if(document.hidden||!this.syncHouseVisibility().active)return;
  this.paintHouses();
  if(root.navigator?.onLine===false)return;
  const missing=tiles.filter(t=>!this.housePending.has(t.key)&&(!this.houseCache.has(t.key)||Date.now()-this.houseCache.get(t.key).fetchedAt>7*86400000)&&(Date.now()-(this.houseRetry.get(t.key)||0)>60000));
  if(!missing.length)return;
  const wait=8000-(Date.now()-this.houseFetchAt);
  // A single pending-view wake-up avoids requiring another finger movement after throttle.
  // Never schedule it for warm tiles, offline mode, a failed tile's retry penalty, or hidden view.
  if(wait>0){if(!this.houseFetchTimer)this.houseFetchTimer=setTimeout(()=>{this.houseFetchTimer=null;this.refreshHouses().catch(()=>{});},wait+20);return;}
  if(this.houseFetchTimer){clearTimeout(this.houseFetchTimer);this.houseFetchTimer=null;}
  this.houseFetchAt=Date.now();const epoch=this.houseEpoch;
  const queue=missing.slice();await Promise.all([0,1].map(async()=>{while(queue.length&&!document.hidden&&E.houseView(this.houseOptions()).active&&epoch===this.houseEpoch){const t=queue.shift();this.housePending.add(t.key);const ac=new AbortController();this.houseControllers.add(ac);let timedOut=false;const timer=setTimeout(()=>{timedOut=true;ac.abort();},24000);
   try{const r=await fetch(`/api/house-numbers?x=${t.x}&y=${t.y}`,{signal:ac.signal,cache:'no-store'});if(!r.ok)throw Error();const obj=await r.json();if(!Array.isArray(obj.rows)||obj.rows.length>10000)throw Error();if(epoch!==this.houseEpoch||document.hidden)continue;
    this.houseLoadError=false;
    if(obj.official)root.DoorOfficial?.rememberTile?.(t.key,obj).catch(()=>{});
    this.houseCache.set(t.key,{rows:obj.rows.filter(E.point),fetchedAt:Date.now()});while(this.houseCache.size>12)this.houseCache.delete(this.houseCache.keys().next().value);
    this.paintHouses();
   }catch(_){if(!ac.signal.aborted||timedOut){this.houseLoadError=true;this.paintHouses();this.houseRetry.set(t.key,Date.now());while(this.houseRetry.size>64)this.houseRetry.delete(this.houseRetry.keys().next().value);}}finally{clearTimeout(timer);this.houseControllers.delete(ac);this.housePending.delete(t.key);}
  }}));
 }
 syncStationUi(){this.toggle.checked=this.stationOn;document.getElementById('gogoroRefreshBtn').hidden=!this.stationOn;this.status.textContent=this.stationOn?(this.stationMessage||'載入官方站點…'):'已關閉 · 不載入站點';}
 setStationOn(value){
  this.stationOn=!!value;this.stationSeq++;this.stationController?.abort();
  if(!this.stationOn){this.closeStation();this.stationMessage='';for(const id of ['extra-gogoro-clusters','extra-gogoro-count','extra-gogoro-points','extra-gogoro-hit','extra-gogoro-names'])if(this.map.getLayer(id))this.map.setLayoutProperty(id,'visibility','none');this.map.getSource('extra-gogoro')?.setData(empty());this.syncStationUi();return;}
  this.ensureStationLayers();this.syncStationUi();this.loadStations();
 }
 applyStationData(){if(!this.stationOn)return;const source=this.map.getSource('extra-gogoro');if(!source)return;source.setData(E.stationFeatures(this.stationRows));for(const id of ['extra-gogoro-clusters','extra-gogoro-count','extra-gogoro-points','extra-gogoro-hit','extra-gogoro-names'])if(this.map.getLayer(id))this.map.setLayoutProperty(id,'visibility','visible');this.order();}
 async loadStations(force=false){
  if(!this.stationOn||document.hidden)return;
  if(!force&&this.stationRows.length&&Date.now()-this.stationFetchedAt>=0&&Date.now()-this.stationFetchedAt<6*3600000){this.stationMessage=`${this.stationStale?'舊快取 · ':''}站點 ${this.stationRows.length} 站 · 數字為站數，非電池數`;this.applyStationData();this.syncStationUi();return;}
  const seq=++this.stationSeq;this.stationController?.abort();const ac=new AbortController();this.stationController=ac;const timer=setTimeout(()=>ac.abort(),15000);
  this.stationMessage='載入官方站點…';this.syncStationUi();
  try{const r=await fetch('/api/gogoro-stations',{signal:ac.signal,cache:'no-store'});const data=await r.json();if(!r.ok)throw Error(data.error||'官方站點暫時不可用');const rows=E.safeStationRows(data.stations);if(!rows.length)throw Error('未取得有效站點');if(!this.stationOn||seq!==this.stationSeq)return;
   this.stationRows=rows;const at=Number(data.fetchedAt);this.stationFetchedAt=Number.isFinite(at)&&at>0&&at<=Date.now()+60000?at:Date.now();this.stationStale=!!data.stale;
   this.stationMessage=`${data.stale?'舊快取 · ':''}站點 ${rows.length} 站 · 數字為站數，非電池數`;this.applyStationData();
  }catch(e){if(seq!==this.stationSeq||!this.stationOn)return;this.stationMessage=this.stationRows.length?'更新失敗 · 顯示上次站點，站況請查官方 App':'官方站點載入失敗 · 可稍後重試';this.stationStale=true;
  }finally{clearTimeout(timer);if(seq===this.stationSeq&&this.stationOn)this.syncStationUi();}
 }
 openStation(id){if(!this.stationOn)return;const r=this.stationRows.find(x=>x.id===id);if(!r)return;
  this.closeStation();this.selected=r;this.panel.hidden=false;
  document.getElementById('gogoroName').textContent=r.name;
  document.getElementById('gogoroAddress').textContent=r.address||`${r.city||''}${r.district||''}`||'官方未提供地址';
  const pos=this.getState().position,dist=E.point(pos)?`${(E.meters(pos,r)/1000).toFixed(1)} km 直線距離 · `:'';
  document.getElementById('gogoroInfo').textContent=`${dist}${r.hours?`開放資訊：${r.hours} · `:''}未取得即時電池／營運狀態`;
  const dt=new Date(this.stationFetchedAt);document.getElementById('gogoroStamp').textContent=`${this.stationStale?'舊資料 · ':''}Gogoro 站點資料 ${Number.isFinite(dt.getTime())?dt.toLocaleString('zh-TW'):''}`;
  this.stationError(r.unavailable?'官方資料標示維修／暫停／建置中，暫不提供導航':'');this.syncStationButtons();
 }
 stationError(msg){document.getElementById('gogoroRouteStatus').textContent=msg;}
 syncStationButtons(){const s=this.getState(),via=document.getElementById('gogoroViaBtn'),direct=document.getElementById('gogoroDirectBtn');via.hidden=!s.destination;via.disabled=this.busy||!s.position||(s.via?.length||0)>=2||this.selected?.unavailable;direct.disabled=this.busy||!s.position||this.selected?.unavailable;direct.textContent=s.destination?'改目的地：只去這站':'導航到這站';if(!s.position)this.stationError('等待 GPS；不使用虛構起點');else if(s.destination&&(s.via?.length||0)>=2)this.stationError('已有 2 個途經點；先到「管理途經點」刪除一點，或選只去這站。');}
 closeStation(){this.navSeq++;this.busy=false;this.selected=null;if(this.panel)this.panel.hidden=true;}
 async goStation(mode){
  if(this.busy||!this.selected||!this.stationOn)return;const row={...this.selected},seq=++this.navSeq;this.busy=true;this.syncStationButtons();this.stationError('規劃機車路線中…原路線先保留');
  try{await this.navigateStation(row,mode,()=>this.stationOn&&seq===this.navSeq&&!document.hidden);if(seq!==this.navSeq)return;this.busy=false;this.panel.hidden=true;this.selected=null;this.notify(mode==='via'?'已排入先換電，原目的地保留':'已導航到交換站');}
  catch(e){if(seq!==this.navSeq)return;this.busy=false;this.syncStationButtons();this.stationError(String(e.message||'規劃失敗；原目的地與路線保留'));}
 }
}
root.DoorMapExtras=MapExtras;
})(globalThis);
