/* Reads only the bundled accepted datasets. No new integration/provider. */
(function(root){'use strict';
const empty=()=>({type:'FeatureCollection',features:[]}),pending=new Map(),cache=new Map(),cacheBytes=new Map();
let officialManifest=null,osmManifest=null,lastOSMKey='',timer=null,seq=0,context=null,cacheEpoch=0;
const counters={officialTiles:0,osmTiles:0,hashFailures:0,errors:[],source:'accepted-bundle-fitlock6'};
const xy=(lng,lat,z)=>({x:Math.floor((lng+180)/360*2**z),y:Math.floor((1-Math.asinh(Math.tan(lat*Math.PI/180))/Math.PI)/2*2**z)});
async function verified(meta){
 if(cache.has(meta.path))return cache.get(meta.path);if(pending.has(meta.path))return pending.get(meta.path);
  const epoch=cacheEpoch,task=(async()=>{const r=await fetch(meta.path,{cache:'force-cache'});if(!r.ok)throw Error('Bundled data '+r.status);const bytes=await r.arrayBuffer();const digest=await root.crypto.subtle.digest('SHA-256',bytes),sha=Array.from(new Uint8Array(digest),b=>b.toString(16).padStart(2,'0')).join('');if(bytes.byteLength!==meta.bytes||sha!==meta.sha256){counters.hashFailures++;throw Error('Bundled data integrity mismatch: '+meta.path);}const d=JSON.parse(new TextDecoder().decode(bytes));if(epoch===cacheEpoch&&!root.document.hidden){cache.set(meta.path,d);cacheBytes.set(meta.path,bytes.byteLength);while(cache.size>64||[...cacheBytes.values()].reduce((a,b)=>a+b,0)>24*1024*1024){const key=cache.keys().next().value;cache.delete(key);cacheBytes.delete(key);}}return d;})();pending.set(meta.path,task);try{return await task;}finally{pending.delete(meta.path);}
}
function releaseDisposableCaches(){cacheEpoch++;cache.clear();cacheBytes.clear();}
async function officialNear(point,radius=140){
 if(!root.DoorExtras?.point(point))return [];
 if(!officialManifest){const r=await fetch('/offline/taichung-official-202608-v1/manifest.json');if(!r.ok)throw Error('Official manifest unavailable');officialManifest=await r.json();if(officialManifest.version!=='tcg-official-202608-v1'||officialManifest.addressCount!==756225)throw Error('Official manifest mismatch');}
 const dlat=Math.min(1500,Math.max(0,Number(radius)||0))/111320,dlng=dlat/Math.max(.3,Math.cos(point.lat*Math.PI/180)),lo=xy(point.lng-dlng,point.lat+dlat,15),hi=xy(point.lng+dlng,point.lat-dlat,15),metas=[];
 for(let x=lo.x;x<=hi.x;x++)for(let y=lo.y;y<=hi.y;y++){const m=officialManifest.tiles[x+'/'+y];if(m)metas.push(m);}
 const out=[];let cursor=0;await Promise.all([0,1].map(async()=>{while(cursor<Math.min(25,metas.length)){const m=metas[cursor++],d=await verified(m);if(d.version!==officialManifest.version||d.rows.length!==m.count)throw Error('Official count mismatch');counters.officialTiles++;for(const row of root.DoorExtras.officialRows(d.rows)){const distance=root.DoorExtras.meters(point,row);if(distance<=radius)out.push({...row,distance,containsDestination:distance<=6});}}}));
 return out.sort((a,b)=>a.distance-b.distance).slice(0,16000);
}
async function refreshOSM(){
 const map=root.__581NativeMap;if(!map||root.document.hidden||map.getZoom()<15)return;
 const token=++seq,b=map.getBounds(),a=xy(b.getWest(),b.getNorth(),14),c=xy(b.getEast(),b.getSouth(),14);
 if(!osmManifest){const r=await fetch('/native-data/osm-manifest.json');if(!r.ok)throw Error('OSM render index unavailable');osmManifest=await r.json();}
 const keys=[];for(let x=a.x;x<=c.x;x++)for(let y=a.y;y<=c.y;y++){const key=x+'-'+y;if(osmManifest.tiles[key])keys.push(key);}
 if(keys.length>64)throw Error('Native OSM viewport exceeds 64 tiles; zoom closer');
 const key=keys.sort().join('|');if(key===lastOSMKey)return;
 let cursor=0;const features=new Map(),failures=[];
 await Promise.all([0,1].map(async()=>{while(cursor<keys.length){const name=keys[cursor++];try{const d=await verified(osmManifest.tiles[name]);counters.osmTiles++;for(const f of d.features||[])features.set(f.id,f);}catch(e){failures.push(String(e.message||e));}}}));
 if(token!==seq||root.document.hidden)return;
 if(failures.length){counters.errors=failures;return;} // retain last complete source on failure
 lastOSMKey=key;counters.errors=[];
 map.getSource('native-osm-buildings')?.setData({type:'FeatureCollection',features:[...features.values()].filter(f=>f.geometry.type==='Polygon')});
 if(!map.getSource('native-osm-roads'))map.addSource('native-osm-roads',{type:'geojson',data:empty()});
 map.getSource('native-osm-roads').setData({type:'FeatureCollection',features:[...features.values()].filter(f=>f.geometry.type==='LineString')});
}
function scheduleOSM(){if(timer)return;timer=setTimeout(()=>{timer=null;refreshOSM().catch(e=>{counters.errors=[String(e.message||e)];});},350);}
function installStateBridge(ctx){
  context=ctx;const {state,map,inset,cameraInteraction}=ctx;
  root.__581NativePreferenceState=()=>({followHeading:state.mode==='heading',routeVisible:state.routeEnabled,stations:root.document.getElementById('gogoroToggle')?.checked||false,miniMode:root.document.getElementById('insetCard').hidden?'hidden':state.insetCollapsed?'collapsed':'expanded'});
 map.on('moveend',scheduleOSM);map.on('load',scheduleOSM);root.document.addEventListener('visibilitychange',()=>{if(root.document.hidden){seq++;if(timer){clearTimeout(timer);timer=null;}releaseDisposableCaches();}else scheduleOSM();});
 root.__581NativeSettings=value=>{
  root.__581DoorMapCanary.setTheme(value.appearance==='system'?(value.effectiveTheme||'dark'):value.appearance,{persist:false});
  if(typeof value.followHeading==='boolean')ctx.setMode(value.followHeading?'heading':'north');
   if(value.miniMode!==undefined){if(value.miniMode==='hidden')root.document.getElementById('insetCard').hidden=true;else{root.document.getElementById('insetCard').hidden=false;root.__581DoorMapCanary.setInsetCollapsed(value.miniMode!=='expanded');}}
  if(typeof value.routeVisible==='boolean')root.__581DoorMapCanary.setRouteEnabled(value.routeVisible);
  if(value.manualCamera){cameraInteraction.handle({originalEvent:{type:'wheel'}});if(state.fitLocked)root.__581DoorMapCanary.setFitLock(false);state.following=false;state.cameraUserOverride=true;cameraInteraction.selectionChanged();map.jumpTo({bearing:value.heading,pitch:value.pitch,zoom:value.zoom??map.getZoom()});}
 };
 root.__581NativeHandoff=payload=>{
  if(payload?.coordinate){ctx.setDestination({...payload.coordinate,__sourceMeta:payload.meta},{fit:true,persist:!String(payload.meta?.source||'').startsWith('apple')});return;}
  if(payload?.destination){const point=root.__581DoorMapCanary.parseDestination(payload.destination);if(point)ctx.setDestination(point,{fit:true,persist:true});return;}
  if(payload?.url){const u=new URL(payload.url);root.location.hash=u.hash||new URLSearchParams({gmap:u.href}).toString();}
 };
 root.__581NativeExpiredApple=()=>{if(root.__581AppleDestination){for(const k of ['581-door-dest','581-door-dest-raw','581-door-dest-meta'])localStorage.removeItem(k);}};
  root.__581NativeCluster=point=>{root.__581DoorMapCanary.setFitLock(false);state.following=false;state.cameraUserOverride=true;cameraInteraction.selectionChanged();ctx.map.easeTo({center:[point.lng,point.lat],zoom:point.zoom,duration:450});};
 root.__581NativeClearDestination=()=>{ctx.clearDestination();};
 root.addEventListener('pagehide',root.__581NativeExpiredApple);
  root.__581NativeBundleDiagnostics=()=>({...counters,officialCount:officialManifest?.addressCount||0,osmCounts:osmManifest?.counts||null,cache:cache.size,cacheBytes:[...cacheBytes.values()].reduce((a,b)=>a+b,0),pending:pending.size});
 scheduleOSM();
}
function installUITestTools(){
 if(!context)return;root.document.body.dataset.nativeTest='1';
 const {state,map,inset,cameraInteraction}=context,tools=root.document.createElement('div');tools.id='nativeTestTools';
  tools.innerHTML='<strong>模擬測試事件</strong><button id="testFreshGPS">GPS</button><button id="testNextGPS">前進</button><button id="testFailGPS">GPS失敗</button><button id="testRecoverGPS">恢復</button><button id="testHeadingWrap">359→1°</button><button id="testLifecycle">背景返回</button><button id="testRoute">測試路線</button><button id="testRealCommunity">實際社區資料</button><button id="testMiniPan">小窗移動</button><button id="testStatus">讀狀態</button><output id="nativeTestStatus"></output>';
 root.document.body.append(tools);let step=0,fixCount=0;
 const route=[[120.668,24.12],[120.668,24.121],[120.668,24.122],[120.668,24.123]],fix=()=>{const p=route[Math.min(2,step)],pos={coords:{longitude:p[0],latitude:p[1]+.00015,accuracy:5,speed:8,heading:0},timestamp:Date.now()+(++fixCount)};context.position(pos);};
  const status=()=>{const d=root.__581DoorMapCanary.nativeDiagnostics(),r=map.diagnostics(),bundle=root.__581NativeBundleDiagnostics(),out=root.document.getElementById('nativeTestStatus');const data={memoryPhase:root.__581NativeMemoryPhase||0,memoryAPI:root.__581NativeMemoryAPI||null,bundleCacheItems:bundle.cache,bundlePending:bundle.pending,sourceCount:r.sourceCount,layerCount:r.layerCount,fit:d.fitLocked,following:d.following,pip:d.pip,route:d.routeEnabled,zoom:Math.round(inset.getZoom()*100)/100,miniCenter:inset.getCenter(),goal:d.destination,hold:state.cameraGestureHold,heading:Math.round(state.displayHeading),gpsState:root.document.getElementById('gpsState').textContent,community:root.__581DoorMapCanary.communityDiagnostics?.().features||0,vias:state.deliveryVia.length,areas:root.__581DoorMapCanary.deliveryDiagnostics().areas,publicGeometry:r.native.publicGeometryFeatures||0,publicSymbols:r.native.publicSymbols||0,officialTiles:bundle.officialTiles,osmTiles:bundle.osmTiles,hashFailures:bundle.hashFailures,styleErrors:r.styleErrors,sensor:'SIMULATED',lastMapClick:r.lastMapClick,webHeartbeatMaxMillis:Number(tools.dataset.heartbeatMax)||0,bundleCacheBytes:bundle.cacheBytes,positionAgeMillis:state.position?Date.now()-state.position.ts:null,moreViewport:(()=>{const q=root.document.getElementById('morePanel').getBoundingClientRect();return {x:q.x,y:q.y,width:q.width,height:q.height};})()};out.textContent=JSON.stringify(data);root.webkit.messageHandlers.appleMapEngine.postMessage({type:'testStatus',payload:data});};
 tools.querySelector('#testFreshGPS').onclick=()=>{step=0;fix();status();};tools.querySelector('#testNextGPS').onclick=()=>{step=Math.min(2,step+1);fix();status();};
 tools.querySelector('#testFailGPS').onclick=()=>{context.locationError({code:2,message:'模擬 GPS 無法定位'});status();};tools.querySelector('#testRecoverGPS').onclick=()=>{fix();status();};
 tools.querySelector('#testHeadingWrap').onclick=()=>{for(const heading of [359,1])root.dispatchEvent(new CustomEvent('door581:nativeHeading',{detail:{heading,accuracy:3,timestamp:Date.now()}}));status();};
 tools.querySelector('#testLifecycle').onclick=()=>{cameraInteraction.lifecycle(false);cameraInteraction.lifecycle(true);status();};
  tools.querySelector('#testRoute').onclick=()=>{fix();context.setDestination({lng:120.668,lat:24.123},{fit:false,persist:true,planRoute:false});state.routeEnabled=true;context.acceptDeliveryRoute({geometry:{type:'LineString',coordinates:route},distance:334,duration:90,maneuvers:[]},state.routeRequestSeq,{lng:120.668,lat:24.12});status();};
  tools.querySelector('#testRealCommunity').onclick=async()=>{const rows=await root.DoorCommunities.ensureSearch(),row=rows.find(r=>r.communityId==='tcg-community/9b97260a5a38f937527a');if(!row)throw Error('Actual bundled community identity absent');context.position({coords:{latitude:row.lat-.0004,longitude:row.lng,accuracy:5,speed:0,heading:null},timestamp:Date.now()+(++fixCount)});context.setDestination({lng:row.lng,lat:row.lat,__sourceMeta:row},{fit:false,persist:true,planRoute:false});state.following=false;state.cameraUserOverride=true;cameraInteraction.selectionChanged();map.jumpTo({center:[row.lng,row.lat],zoom:18.6,bearing:0,pitch:0});status();};
  tools.querySelector('#testMiniPan').onclick=()=>{const c=inset.getCenter();inset.jumpTo({center:[c.lng+.0001,c.lat+.0001],zoom:20});status();};
 if(root.__581NativeMemoryProfile){let phase=0,apiSequence=0;const mark=root.document.createElement('button');mark.id='testMemoryPhase';mark.textContent='標記量測階段';tools.append(mark);mark.onclick=()=>{root.__581NativeMemoryPhase=++phase;status();};const api=root.document.createElement('button');api.textContent='量測 OSM 查詢';tools.append(api);api.onclick=async()=>{const request=++apiSequence;root.__581NativeMemoryAPI={request,pending:true};status();try{const response=await fetch('/api/osm',{method:'POST',headers:{'Content-Type':'text/plain;charset=UTF-8'},body:'[out:json];(way(around:250,24.147663,120.672973);relation(around:250,24.147663,120.672973););out geom;'});const data=await response.json();root.__581NativeMemoryAPI={request,status:response.status,elements:data.elements?.length||0,source:data.source};}catch(e){root.__581NativeMemoryAPI={request,error:String(e.message||e)};}status();};}
 tools.querySelector('#testStatus').onclick=status;
  let beat=performance.now(),maximum=0;setInterval(()=>{const t=performance.now();maximum=Math.max(maximum,t-beat-100);beat=t;tools.dataset.heartbeatMax=maximum.toFixed(1);},100);
  root.__581NativeUITest={status,fix};setInterval(status,1000);status();
}
root.DoorNativeBundle={officialNear,installStateBridge,refreshOSM,installUITestTools,releaseDisposableCaches};
})(globalThis);
