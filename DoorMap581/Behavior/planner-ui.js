/* Door Map 0.3.78 UI. Editors are explicitly gated; no GPS-history learning. */
(function(root){'use strict';
function install(h){
 const C=root.DoorSearchCore,P=root.DoorRoutePersonal,D=root.DoorDelivery,s=h.state,map=h.map,doc=document;
 const editor=new P.Editor(),memory=new P.Memory(localStorage);let routeTimer=null,routeAbort=null,searchTimer=null,appleSuggestTimer=null,searchSeq=0,composing=false,editorGesture=null,suppressTapUntil=0,backupTimer=null,suggestAbort=null,lastSuggestAt=0,lastPointKey=null,lastSearchRows=[],candidateRows=[],activeSearchQuery='',searchAreaDirty=false,manualSearchMove=false;
 const $=id=>doc.getElementById(id),clone=P.copy;
 const section=doc.createElement('section');section.id='plannerSearch';section.className='glass';section.setAttribute('aria-label','搜尋目的地');
 section.innerHTML='<form id="plannerSearchForm"><span aria-hidden="true">⌕</span><input id="plannerQuery" type="search" inputmode="search" placeholder="搜尋地址、店家、地標或座標" autocomplete="off" autocapitalize="off" spellcheck="false" aria-label="搜尋地址、店家、地標或座標" aria-controls="plannerSuggestions" aria-expanded="false"><button id="plannerPaste" type="button">貼上</button><button id="plannerSearchGo" type="submit" aria-label="搜尋">搜尋</button></form><button id="plannerSearchArea" type="button" hidden>搜尋這個區域</button><div id="plannerSuggestions" hidden></div><p id="plannerSearchStatus" role="status" hidden></p>';
 $('app').append(section);
 const launch=doc.createElement('button');launch.id='plannerEditBtn';launch.className='glass';launch.type='button';launch.textContent='編輯路線';launch.hidden=true;$('app').append(launch);
 const bar=doc.createElement('section');bar.id='plannerEditor';bar.className='glass';bar.hidden=true;bar.setAttribute('aria-label','編輯路線');
 bar.innerHTML='<div class="planner-editor-head"><strong>編輯路線</strong><span id="plannerCount"></span><button id="plannerDone" type="button" class="primary-btn">完成</button></div><p id="plannerEditStatus" role="status">點道路新增控制點；點編號後再點別處可移動。</p><div class="planner-editor-actions"><button id="plannerUndo" type="button">↶ 上一步</button><button id="plannerDelete" type="button" disabled>刪除選取</button><button id="plannerClear" type="button">清除修改</button><button id="plannerCancel" type="button">取消</button></div>';
 $('app').append(bar);
 const personal=doc.createElement('dialog');personal.id='plannerPersonal';personal.className='dialog-card';personal.innerHTML='<h2>路線記憶與個人備份</h2><p>只記你確認的規劃，不記 GPS 軌跡。圖資與快取不放進備份。</p><label class="planner-check"><input id="plannerMemoryToggle" type="checkbox"> 規劃時參考個人路線記憶</label><div class="planner-editor-actions"><button id="plannerExport" type="button">匯出備份</button><label class="planner-import">匯入備份<input id="plannerImport" type="file" accept="application/json,.json"></label></div><p id="plannerBackupStatus" role="status"></p><div id="plannerMemories"></div><form method="dialog"><button class="primary-btn">關閉</button></form>';
 doc.body.append(personal);
 const menu=doc.createElement('button');menu.className='more-option';menu.type='button';menu.textContent='路線記憶／備份';$('morePanel').querySelector('.more-grid').append(menu);
 const nativeMenu=doc.createElement('button');nativeMenu.id='plannerNativeInfo';nativeMenu.className='more-option';nativeMenu.type='button';nativeMenu.textContent='App 資訊／診斷';nativeMenu.hidden=!root.__door581Probe?.openDiagnostics;$('morePanel').querySelector('.more-grid').append(nativeMenu);
 nativeMenu.onclick=()=>{h.closeMore();root.__door581Probe?.openDiagnostics?.();};
 const status=(id,text)=>{const e=$(id);e.textContent=text||'';e.hidden=!text;};
 const SEARCH_SOURCE='planner-search-results',DISPLAY_LIMIT=30,BUILD_LABEL='v0.3.78',PRIMARY_RADIUS_M=3000,EXPANDED_RADIUS_M=8000,PRIMARY_MIN_RESULTS=6;let searchLayersBound=false,searchCenter=null,renderLimit=DISPLAY_LIMIT,trace={};
 function ensureSearchLayers(){
  if(!map?.isStyleLoaded?.())return false;
  if(!map.getSource(SEARCH_SOURCE))map.addSource(SEARCH_SOURCE,{type:'geojson',cluster:true,clusterRadius:42,clusterMaxZoom:16,data:{type:'FeatureCollection',features:[]}});
  if(!map.getLayer('planner-search-cluster'))map.addLayer({id:'planner-search-cluster',type:'circle',source:SEARCH_SOURCE,filter:['has','point_count'],paint:{'circle-radius':17,'circle-color':'#a93929','circle-stroke-color':'#fff','circle-stroke-width':2}});
  if(!map.getLayer('planner-search-count'))map.addLayer({id:'planner-search-count',type:'symbol',source:SEARCH_SOURCE,filter:['has','point_count'],layout:{'text-field':['get','point_count_abbreviated'],'text-font':['Noto Sans Regular'],'text-size':12,'text-allow-overlap':true},paint:{'text-color':'#fff'}});
  if(!map.getLayer('planner-search-dot'))map.addLayer({id:'planner-search-dot',type:'circle',source:SEARCH_SOURCE,filter:['!', ['has','point_count']],paint:{'circle-radius':6,'circle-color':'#e65c47','circle-stroke-color':'#ffffff','circle-stroke-width':2}});
  if(!map.getLayer('planner-search-label'))map.addLayer({id:'planner-search-label',type:'symbol',source:SEARCH_SOURCE,minzoom:15,filter:['!', ['has','point_count']],layout:{'text-field':['get','label'],'text-font':['Noto Sans Regular'],'text-size':11,'text-max-width':10,'text-offset':[0,1.1],'text-anchor':'top','text-padding':8,'symbol-sort-key':['get','index'],'text-allow-overlap':false,'text-ignore-placement':false},paint:{'text-color':'#ffffff','text-halo-color':'rgba(18,23,30,.92)','text-halo-width':2}});
  if(!searchLayersBound){searchLayersBound=true;map.on('click','planner-search-dot',e=>{const i=Number(e.features?.[0]?.properties?.index);if(Number.isInteger(i)&&lastSearchRows[i])pick(lastSearchRows[i]);});
   map.on('click','planner-search-cluster',async e=>{const f=e.features?.[0];if(!f)return;const zoom=await map.getSource(SEARCH_SOURCE).getClusterExpansionZoom(Number(f.properties.cluster_id));map.easeTo({center:f.geometry.coordinates,zoom:Math.min(19,zoom),duration:300});});
  }
  return true;
 }
 function clearSearchPins(){lastSearchRows=[];activeSearchQuery='';searchCenter=null;searchAreaDirty=false;manualSearchMove=false;if($('plannerSearchArea'))$('plannerSearchArea').hidden=true;try{map.getSource(SEARCH_SOURCE)?.setData({type:'FeatureCollection',features:[]});}catch(_){}}
 function isAddressLikeQuery(query){return /(?:\d+.*(?:號|路|街|大道|段|巷|弄)|(?:路|街|大道|段|巷|弄).*[0-9０-９]|(?:市|縣).*(?:區|鄉|鎮).*(?:路|街|大道))/i.test(String(query||''));}
 function searchWindow(rows,center,query=''){
  const source=Array.isArray(rows)?rows:[];
  if(!center||isAddressLikeQuery(query))return {rows:source.slice(),radiusM:null,expanded:false,primaryCount:source.length};
  const ranked=source.map(r=>({r,d:C.meters(center,r)})).filter(x=>Number.isFinite(x.d)).sort((a,b)=>a.d-b.d);
  const primary=ranked.filter(x=>x.d<=PRIMARY_RADIUS_M).map(x=>x.r);
  if(primary.length>=PRIMARY_MIN_RESULTS)return {rows:primary,radiusM:PRIMARY_RADIUS_M,expanded:false,primaryCount:primary.length};
  const expanded=ranked.filter(x=>x.d<=EXPANDED_RADIUS_M).map(x=>x.r);
  return {rows:expanded,radiusM:EXPANDED_RADIUS_M,expanded:true,primaryCount:primary.length};
 }
 function setSearchPins(rows,query,center){
  const c=center||h.searchCenter?.()||null,windowed=searchWindow(rows,c,query),addressLike=isAddressLikeQuery(query),near=(!c||addressLike)?windowed.rows:windowed.rows.filter(r=>C.meters(c,r)<=PRIMARY_RADIUS_M);
  trace={...trace,query,center:c,radiusM:(!c||addressLike)?windowed.radiusM:PRIMARY_RADIUS_M,listRadiusM:windowed.radiusM,candidateCount:rows.length,primaryCount:windowed.primaryCount,inRadiusMatchedCount:near.length,geoJSONFeatureCount:near.length,identityPreserved:near.every(r=>!!r.displayName)};
  lastSearchRows=near;activeSearchQuery=String(query||'').trim();searchCenter=c?{lat:Number(c.lat),lng:Number(c.lng)}:null;searchAreaDirty=false;if($('plannerSearchArea'))$('plannerSearchArea').hidden=true;
  if(!ensureSearchLayers())return;
  map.getSource(SEARCH_SOURCE)?.setData({type:'FeatureCollection',features:near.map((r,index)=>({type:'Feature',id:index,properties:{poiId:C.key(r),index,name:r.displayName||r.name,branch:r.branch||'',location:C.locationText(r),osmKey:r.osmKey||'',distanceM:C.meters(c,r),label:String(r.displayName||r.name||'位置')+'\n'+String(r.branch||r.address||r.locationHint||C.locationText(r)).split(' · ')[0]},geometry:{type:'Point',coordinates:[Number(r.lng),Number(r.lat)]}}))});
 }
 function mergeCandidates(groups,center,query){
  const ranked=C.rankResults(groups,query||activeSearchQuery||$('plannerQuery').value,center);
  const existing=ranked.filter(r=>r.source!=='apple-mklocalsearch');
  return ranked.filter(r=>{
   if(r.source!=='apple-mklocalsearch'||!r.appleBrandKey)return true;
   return !existing.some(x=>C.meters(x,r)<=30);
  });
 }
 function focusSearchPins(center){
  const pts=[...(center?[center]:[]),...lastSearchRows].filter(Boolean);if(!pts.length)return;
  if(pts.length===1){map.easeTo?.({center:[pts[0].lng,pts[0].lat],zoom:16,duration:300});return;}
  const lngs=pts.map(p=>Number(p.lng)),lats=pts.map(p=>Number(p.lat));
  map.fitBounds?.([[Math.min(...lngs),Math.min(...lats)],[Math.max(...lngs),Math.max(...lats)]],{padding:{top:150,bottom:130,left:48,right:48},maxZoom:15.8,duration:320});
 }
 function publishSearchPool(pool,query,center){
  const view=searchWindow(pool,center,query);
  results(view.rows);
  setSearchPins(pool,query,center);
  return view;
 }
 function rangeStatus(view){
  if(!view?.rows?.length)return '';
  return view.radiusM===EXPANDED_RADIUS_M
    ? `附近 3 公里結果較少，已擴到 8 公里 · ${view.rows.length} 筆`
    : `附近 3 公里 · ${view.rows.length} 筆`;
 }
 function sync(){
  const navigating=!!(s.navigationRequested||s.navigationActive);section.hidden=navigating||editor.active;launch.hidden=navigating||editor.active||!s.destination||h.routeCoordinates().length<2;
  doc.body.classList.toggle('planning-search',!navigating&&!editor.active);doc.body.classList.toggle('route-editing',editor.active);doc.body.dataset.routeEditing=editor.active?'1':'0';
  bar.hidden=!editor.active;const nav=$('routeBtn');if(nav)nav.disabled=editor.active;
  if(editor.active){$('plannerCount').textContent=editor.via.length+' 個控制點';$('plannerDone').disabled=!editor.ready;$('plannerUndo').disabled=!editor.history.length;$('plannerDelete').disabled=editor.selected===null;
   status('plannerEditStatus',editor.selected!==null?'已選控制點 '+(editor.selected+1)+'：點新道路移動，或按「刪除選取」。':editor.error?'無法套用：'+editor.error+'。可上一步或修正；原路線保留。':editor.ready?'點道路新增；點編號後再點別處可移動。':'重新規劃中…可以繼續選點。');}
  renderPoints();
 }
 function snapshot(){return {via:clone(s.deliveryVia),record:h.captureRoute(),alternates:clone(s.alternateRoutes||[]),camera:{fitLocked:!!s.fitLocked,following:!!s.following,cameraUserOverride:!!s.cameraUserOverride}};}
 function invalidateEdit(){clearTimeout(routeTimer);routeTimer=null;routeAbort?.abort();routeAbort=null;}
 function openEditor(){
  if(editor.active)return;if(s.navigationActive||s.navigationRequested){h.toast('請先結束導航，再編輯路線');return;}
  if(!s.position||!s.destination||h.routeCoordinates().length<2){h.toast('先設定目的地並等路線出來');return;}
  editor.begin(snapshot());h.invalidateRoute();h.closeMore();h.clearLegacy();h.pauseCamera();clearSuggestions();$('plannerQuery').blur();sync();
 }
 function apply(record,via,alts){h.applyRoute(record,via,alts);}
 function cancel({restore=true}={}){if(!editor.active)return;invalidateEdit();const base=editor.cancel();if(restore&&base){apply(base.record,base.via,base.alternates);h.restoreCamera(base.camera);}sync();}
 function finish(){try{const out=editor.finish();invalidateEdit();apply(out.record,out.via,out.alternates);if(out.changed)remember(out.base.record,out.record,'edit');sync();h.toast('編輯完成；可直接開始導航');}catch(e){h.toast(e.message);}}
 function clear(){invalidateEdit();editor.clear();apply(editor.record,editor.via,editor.alternates);sync();}
 function undo(){invalidateEdit();if(!editor.undo())return;if(editor.ready)apply(editor.record,editor.via,editor.alternates);else schedule();sync();}
 function mutate(kind,value){try{editor.change(kind,value);schedule();sync();}catch(e){h.toast(e.message);}}
 function schedule(){invalidateEdit();const version=editor.version,revision=s.deliveryRevision,target=s.destination?clone(s.destination):null;
  routeTimer=setTimeout(async()=>{routeTimer=null;const ctl=new AbortController();routeAbort=ctl;
   try{const set=await h.fetchEdited(editor.via,ctl.signal);
    if(!editor.active||version!==editor.version||!target||!s.destination||D.meters(target,s.destination)>1||revision!==s.deliveryRevision)return;
    if(editor.accept(version,set.routes[0],set.routes.slice(1)))apply(editor.record,editor.via,editor.alternates);
   }catch(e){if(!ctl.signal.aborted)editor.fail(version,e.message||e);}finally{if(routeAbort===ctl)routeAbort=null;sync();}
  },220);
 }
 function renderPoints(){if(!map)return;const points=editor.active?editor.via:[];
  const data={type:'FeatureCollection',features:points.map((p,i)=>({type:'Feature',properties:{index:i,label:String(i+1),selected:i===editor.selected,invalid:!!editor.error&&!editor.ready},geometry:{type:'Point',coordinates:[p.lng,p.lat]}}))};
  try{const key=JSON.stringify(data);let source=map.getSource('planner-points');if(source&&key===lastPointKey)return;lastPointKey=key;if(source)source.setData(data);else map.addSource('planner-points',{type:'geojson',data});
   if(!map.getLayer('planner-points-dot'))map.addLayer({id:'planner-points-dot',type:'circle',source:'planner-points',paint:{'circle-radius':['case',['get','selected'],12,9],'circle-color':['case',['get','invalid'],'#ef6d5b',['get','selected'],'#ffc857','#24778d'],'circle-stroke-color':'#ffffff','circle-stroke-width':2}});
   if(!map.getLayer('planner-points-label'))map.addLayer({id:'planner-points-label',type:'symbol',source:'planner-points',layout:{'text-field':['get','label'],'text-size':11,'text-allow-overlap':true,'text-ignore-placement':true,'text-rotation-alignment':'viewport'},paint:{'text-color':'#ffffff','text-halo-width':1,'text-halo-color':'#164559'}});
   for(const id of ['delivery-vias-circle','delivery-vias-label'])if(map.getLayer(id))map.setLayoutProperty(id,'visibility',editor.active?'none':'visible');
  }catch(_){/* style.load re-installs these optional controls */}
 }
 // MapLibre already separates pan from click; this additional gesture gate also rejects long press and multi-touch.
 const surface=map.getCanvasContainer();
 surface.addEventListener('pointerdown',e=>{if(!editor.active)return;if(e.isPrimary===false){editorGesture=null;suppressTapUntil=Date.now()+600;return;}editorGesture={x:e.clientX,y:e.clientY,at:Date.now(),id:e.pointerId};},{passive:true});
 surface.addEventListener('pointermove',e=>{if(editorGesture&&(Math.hypot(e.clientX-editorGesture.x,e.clientY-editorGesture.y)>7))editorGesture=null;},{passive:true});
 surface.addEventListener('pointercancel',()=>{editorGesture=null;suppressTapUntil=Date.now()+400;},{passive:true});
 surface.addEventListener('touchstart',e=>{if(e.touches.length>1){editorGesture=null;suppressTapUntil=Date.now()+800;}},{passive:true});
 map.on('click',e=>{
  if(!editor.active||!e.lngLat||Date.now()<suppressTapUntil)return;
  if(e.originalEvent&&(!editorGesture||Date.now()-editorGesture.at>600)){editorGesture=null;return;}editorGesture=null;
  const near=editor.via.map((p,index)=>{const q=map.project([p.lng,p.lat]);return {index,d:Math.hypot(q.x-e.point.x,q.y-e.point.y)};}).filter(x=>x.d<22).sort((a,b)=>a.d-b.d)[0];
  if(near){editor.selected=editor.selected===near.index?null:near.index;sync();return;}
  const p={lat:e.lngLat.lat,lng:e.lngLat.lng};
  if(editor.selected!==null)mutate('move',{index:editor.selected,point:p});else mutate('add',p);
 });
 map.on('style.load',()=>{renderPoints();if(lastSearchRows.length)setSearchPins(lastSearchRows,activeSearchQuery,searchCenter);});map.on('load',()=>{renderPoints();ensureSearchLayers();});
 map.on('movestart',e=>{if(e?.originalEvent)manualSearchMove=true;});
 map.on('dragstart',()=>{manualSearchMove=true;});
 map.on('moveend',()=>{if(!manualSearchMove)return;manualSearchMove=false;if(!activeSearchQuery||editor.active||s.navigationRequested||s.navigationActive||!searchCenter)return;const c=map.getCenter(),moved=D.meters(searchCenter,{lat:c.lat,lng:c.lng});searchAreaDirty=moved>300;if($('plannerSearchArea'))$('plannerSearchArea').hidden=!searchAreaDirty;});
 async function searchAreaNow(){
  const raw=activeSearchQuery;if(!raw)return;const c=map.getCenter(),center={lat:c.lat,lng:c.lng},seq=++searchSeq;suggestAbort?.abort();searchAreaDirty=false;doc.getElementById('plannerSearchArea').hidden=true;
  let local=[];try{local=await (h.searchLocalAll?h.searchLocalAll(raw,center):h.searchLocalAt(raw,center));}catch(_){}
  if(seq!==searchSeq)return;
  let pool=mergeCandidates([local],center,raw),view=publishSearchPool(pool,raw,center),focused=false;
  if(lastSearchRows.length){focusSearchPins(center);focused=true;}
  collapseSearchPanel();
  status('plannerSearchStatus',rangeStatus(view)||'附近搜尋中…');
  const ctl=new AbortController();suggestAbort=ctl;trace={...trace,localCount:local.length,phase:'progressive'};
  const applyRows=(label,rows)=>{
   if(seq!==searchSeq||ctl.signal.aborted)return null;
   pool=mergeCandidates([pool,rows],center,raw);
   trace={...trace,[label+'Count']:Number(trace[label+'Count']||0)+rows.length,phase:'progressive'};
   view=publishSearchPool(pool,raw,center);
   if(!focused&&lastSearchRows.length){focusSearchPins(center);focused=true;}
   status('plannerSearchStatus',rangeStatus(view)||'附近搜尋中…');
   return view;
  };
  const appleTask=(async()=>{
   const first=h.searchApple?await h.searchApple(raw,center,PRIMARY_RADIUS_M).catch(()=>[]):[];
   let current=applyRows('apple',first);if(!current)return;
   if(!isAddressLikeQuery(raw)&&current.primaryCount<PRIMARY_MIN_RESULTS&&h.searchApple){
    const expanded=await h.searchApple(raw,center,EXPANDED_RADIUS_M).catch(()=>[]);
    current=applyRows('apple',expanded)||current;
   }
  })();
  const remoteTask=(async()=>{const rows=h.searchRemote?await h.searchRemote(raw,ctl.signal,center).catch(()=>[]):[];applyRows('remote',rows);})();
  const poiTask=(async()=>{const rows=h.searchPoi?await h.searchPoi(raw,center).catch(()=>[]):[];applyRows('poi',rows);})();
  await Promise.allSettled([appleTask,remoteTask,poiTask]);
  if(seq!==searchSeq||ctl.signal.aborted)return;
  trace={...trace,phase:'complete'};
  status('plannerSearchStatus',view.rows.length?rangeStatus(view):'8 公里內找不到符合店家或地標');
 }
 doc.getElementById('plannerSearchArea').onclick=searchAreaNow;
 launch.onclick=openEditor;$('plannerCancel').onclick=()=>cancel();$('plannerDone').onclick=finish;$('plannerUndo').onclick=undo;$('plannerClear').onclick=clear;$('plannerDelete').onclick=()=>mutate('delete',editor.selected);
 function collapseSearchPanel(){section.classList.add('map-results');$('plannerSuggestions').hidden=true;$('plannerQuery').setAttribute('aria-expanded','false');status('plannerSearchStatus','');}
 function expandSearchPanel(){section.classList.remove('map-results');}
 function clearSuggestions(){searchSeq++;clearTimeout(searchTimer);clearTimeout(appleSuggestTimer);suggestAbort?.abort();candidateRows=[];$('plannerSuggestions').replaceChildren();$('plannerSuggestions').hidden=true;$('plannerQuery').setAttribute('aria-expanded','false');status('plannerSearchStatus','');}
 function pick(result){clearSuggestions();clearSearchPins();h.selectResult(result);$('plannerQuery').value='';$('plannerQuery').blur();section.classList.remove('map-results');sync();}
 function results(rows,{more=false}={}){candidateRows=Array.isArray(rows)?rows.slice():[];if(!more)renderLimit=DISPLAY_LIMIT;const shown=candidateRows.slice(0,renderLimit),box=$('plannerSuggestions'),frag=doc.createDocumentFragment();box.replaceChildren();for(const r of shown){
  const b=doc.createElement('button');b.type='button';b.className='address-result';const title=doc.createElement('span');title.className='address-result-title';title.textContent=r.displayName||r.name||'位置';
  const sub=doc.createElement('span');sub.className='address-result-sub';sub.textContent=[C.locationText(r),Number.isFinite(r.distanceM)?r.distanceM<1000?Math.round(r.distanceM)+' m':(r.distanceM/1000).toFixed(1)+' km':'',r.approximate?'僅路段約略位置':''].filter(Boolean).join(' · ');b.append(title,sub);b.onclick=()=>pick(r);frag.append(b);
 }box.append(frag);if(candidateRows.length>shown.length){const more=doc.createElement('button');more.type='button';more.className='address-result';more.textContent='顯示更多（'+shown.length+' / '+candidateRows.length+'）';more.onclick=()=>{renderLimit+=DISPLAY_LIMIT;results(candidateRows,{more:true});};box.append(more);}box.hidden=!shown.length;$('plannerQuery').setAttribute('aria-expanded',String(!!shown.length));}
 async function submit({automatic=false}={}){if(composing)return;const raw=$('plannerQuery').value.trim();if(!raw)return;const seq=++searchSeq;trace={query:raw,phase:'loading'};clearTimeout(searchTimer);clearTimeout(appleSuggestTimer);suggestAbort?.abort();status('plannerSearchStatus','搜尋中…');
  try{const direct=h.parse(raw);if(direct){if(seq===searchSeq){clearSearchPins();h.selectPoint(direct);clearSuggestions();$('plannerQuery').value='';$('plannerQuery').blur();sync();}return;}
   if(h.isMaps(raw)){const dest=await h.resolve(raw);if(seq!==searchSeq)return;clearSearchPins();h.selectPoint(dest);clearSuggestions();$('plannerQuery').value='';$('plannerQuery').blur();sync();return;}
   if(/https?:\/\//i.test(raw))throw Error('目前只接受 Google Maps 分享網址');
   const center=h.searchCenter?.()||null,addressLike=isAddressLikeQuery(raw);
   let local=[];try{local=await (h.searchLocalAll?h.searchLocalAll(raw,center):h.searchLocalAt(raw,center));}catch(_){}
   if(seq!==searchSeq)return;
   let pool=mergeCandidates([local],center,raw),view=publishSearchPool(pool,raw,center),focused=false;
   if(lastSearchRows.length){focusSearchPins(center);focused=true;}
   $('plannerQuery').blur();collapseSearchPanel();
   if(automatic)return;
   if(addressLike&&!view.rows.length){
    let full=[];try{full=await h.searchFullAt(raw,center);}catch(_){}
    if(seq!==searchSeq)return;
    pool=mergeCandidates([pool,full],center,raw);view=publishSearchPool(pool,raw,center);
    if(!focused&&lastSearchRows.length){focusSearchPins(center);focused=true;}
    status('plannerSearchStatus',view.rows.length?`候選 ${view.rows.length} 筆 · ${BUILD_LABEL}`:'找不到這個地址');return;
   }
   const ctl=new AbortController();suggestAbort=ctl;trace={...trace,localCount:local.length,phase:'progressive'};
   status('plannerSearchStatus',rangeStatus(view)||'附近搜尋中…');
   const applyRows=(label,rows)=>{
    if(seq!==searchSeq||ctl.signal.aborted)return null;
    pool=mergeCandidates([pool,rows],center,raw);
    trace={...trace,[label+'Count']:Number(trace[label+'Count']||0)+rows.length,phase:'progressive'};
    view=publishSearchPool(pool,raw,center);
    if(!focused&&lastSearchRows.length){focusSearchPins(center);focused=true;}
    status('plannerSearchStatus',rangeStatus(view)||'附近搜尋中…');
    return view;
   };
   const appleTask=(async()=>{
    const first=h.searchApple?await h.searchApple(raw,center,PRIMARY_RADIUS_M).catch(()=>[]):[];
    let current=applyRows('apple',first);if(!current)return;
    if(!addressLike&&current.primaryCount<PRIMARY_MIN_RESULTS&&h.searchApple){
      const expanded=await h.searchApple(raw,center,EXPANDED_RADIUS_M).catch(()=>[]);
      current=applyRows('apple',expanded)||current;
    }
   })();
   const remoteTask=(async()=>{const rows=h.searchRemote?await h.searchRemote(raw,ctl.signal,center).catch(()=>[]):[];applyRows('remote',rows);})();
   const poiTask=(async()=>{const rows=h.searchPoi?await h.searchPoi(raw,center).catch(()=>[]):[];applyRows('poi',rows);})();
   await Promise.allSettled([appleTask,remoteTask,poiTask]);
   if(seq!==searchSeq||ctl.signal.aborted)return;
   if(!view.rows.length){
    let full=[];try{full=await h.searchFullAt(raw,center);}catch(_){}
    if(seq!==searchSeq)return;
    pool=mergeCandidates([pool,full],center,raw);view=publishSearchPool(pool,raw,center);
    if(!focused&&lastSearchRows.length){focusSearchPins(center);focused=true;}
   }
   trace={...trace,phase:'complete'};
   status('plannerSearchStatus',view.rows.length?`${rangeStatus(view)} · ${BUILD_LABEL}`:'8 公里內找不到符合店家、地標或地址');
  }catch(e){if(seq===searchSeq)status('plannerSearchStatus',String(e.message||e));}
 }
 function suggest(){clearTimeout(searchTimer);clearTimeout(appleSuggestTimer);suggestAbort?.abort();const seq=++searchSeq,raw=$('plannerQuery').value.trim();if(composing)return;if(!raw){clearSearchPins();clearSuggestions();return;}if(activeSearchQuery&&raw!==activeSearchQuery)clearSearchPins();
  if(h.parse(raw)||h.isMaps(raw)){results([]);status('plannerSearchStatus',`按搜尋套用；貼上座標或分享網址會直接解析 · ${BUILD_LABEL}`);return;}
  searchTimer=setTimeout(async()=>{
   const center=h.searchCenter?.()||null,found=raw.length>=2&&h.searchLocalAll?await h.searchLocalAll(raw,center):await h.searchLocal(raw);
   if(seq!==searchSeq||composing)return;
   let all=mergeCandidates([found],center,raw),view=searchWindow(all,center,raw);
   results(view.rows);status('plannerSearchStatus',view.rows.length?`本機附近命中 ${view.rows.length} 筆 · ${BUILD_LABEL}`:`附近本機暫無候選 · ${BUILD_LABEL}`);
   if(raw.length<2||!h.searchApple)return;
   appleSuggestTimer=setTimeout(async()=>{
    if(seq!==searchSeq||composing||doc.activeElement!==$('plannerQuery'))return;
    const apple=await h.searchApple(raw,center,PRIMARY_RADIUS_M).catch(()=>[]);
    if(seq!==searchSeq||composing||doc.activeElement!==$('plannerQuery'))return;
    all=mergeCandidates([all,apple],center,raw);view=searchWindow(all,center,raw);results(view.rows);
    status('plannerSearchStatus',view.rows.length?`附近即時候選 ${view.rows.length} 筆 · Apple 已補充 · ${BUILD_LABEL}`:`附近暫無候選；按「搜尋」可擴大到 8 公里 · ${BUILD_LABEL}`);
   },360);
  },120);
 }
 $('plannerQuery').addEventListener('focus',()=>{expandSearchPanel();if(activeSearchQuery===$('plannerQuery').value.trim()&&candidateRows.length){results(candidateRows);return;}if($('plannerQuery').value.trim())suggest();});$('plannerQuery').addEventListener('input',()=>{expandSearchPanel();suggest();});$('plannerQuery').addEventListener('compositionstart',()=>{composing=true;searchSeq++;clearTimeout(searchTimer);clearTimeout(appleSuggestTimer);});$('plannerQuery').addEventListener('compositionend',()=>{composing=false;suggest();});
 $('plannerQuery').addEventListener('paste',()=>setTimeout(()=>{const raw=$('plannerQuery').value;if(h.parse(raw)||h.isMaps(raw))submit();else suggest();},0));
 $('plannerSearchForm').onsubmit=e=>{e.preventDefault();submit();};
 $('plannerPaste').onclick=async()=>{try{const text=await navigator.clipboard.readText();if(!text.trim())throw Error('剪貼簿沒有文字');$('plannerQuery').value=text.trim();if(h.parse(text)||h.isMaps(text))await submit();else suggest();}catch(_){$('plannerQuery').focus();status('plannerSearchStatus','請在輸入框長按並選「貼上」，或使用鍵盤的貼上功能。');}};
 function remember(before,after,source){try{const count=memory.learn(before,after,source);if(count){queueBackup();h.toast('已記住 '+count+' 段規劃偏好（不含 GPS 軌跡）');}return count;}catch(e){h.toast('路線已保留；偏好儲存失敗：'+e.message);return 0;}}
 async function preferred(main,alternates,from,to,options,isCurrent){if(localStorage.getItem('581-route-memory-enabled-v1')==='0'||editor.active||options.via.length)return {main,alternates};
  const match=memory.candidates(main)[0];if(!match)return {main,alternates};
  const ctl=new AbortController(),deadline=setTimeout(()=>ctl.abort(),3500);try{const candidate=await h.fetchPreference(from,to,match.points,options,ctl.signal);if(!isCurrent()||!P.reasonablePreference(main,candidate))return {main,alternates};candidate.memoryApplied=match.id;return {main:candidate,alternates:[main,...alternates].slice(0,2)};}catch(_){return {main,alternates};}finally{clearTimeout(deadline); }
 }
 function memoryAge(ts){const d=Math.max(0,Date.now()-Number(ts||0)),day=Math.floor(d/86400000);if(day<1)return '今天';if(day<30)return day+' 天前';const m=Math.floor(day/30);return m<12?m+' 個月前':Math.floor(m/12)+' 年前';}
 function previewMemory(r){if(!r?.points?.length)return;const xs=r.points.map(p=>p.lng),ys=r.points.map(p=>p.lat);personal.close();map.fitBounds([[Math.min(...xs),Math.min(...ys)],[Math.max(...xs),Math.max(...ys)]],{padding:70,maxZoom:17.5,duration:500});}
 function showPersonal(){h.closeMore();$('plannerMemoryToggle').checked=localStorage.getItem('581-route-memory-enabled-v1')!=='0';const rows=$('plannerMemories');rows.replaceChildren();
  const heading=doc.createElement('p');heading.textContent='已記住 '+memory.rows.length+' 段路線偏好';rows.append(heading);
  if(memory.rows.length){const manage=doc.createElement('button');manage.type='button';manage.textContent='管理路線記憶';manage.className='secondary-btn';rows.append(manage);const list=doc.createElement('div');list.hidden=true;rows.append(list);
   manage.onclick=()=>{list.hidden=!list.hidden;manage.textContent=list.hidden?'管理路線記憶':'收合記憶清單';};
   const clearAll=doc.createElement('button');clearAll.type='button';clearAll.textContent='清除全部路線記憶';clearAll.className='secondary-btn';clearAll.onclick=()=>{if(root.confirm('清除全部路線記憶？避開區與其他設定不會刪除。')){memory.save([]);queueBackup();showPersonal();}};list.append(clearAll);
   for(const r of memory.rows.slice().sort((a,b)=>b.updatedAt-a.updatedAt).slice(0,100)){const row=doc.createElement('div');row.className='planner-memory-row';const text=doc.createElement('span');text.textContent=(r.source==='edit'?'手動規劃':'替代路線')+' · '+memoryAge(r.updatedAt)+' · 使用 '+r.count+' 次';const view=doc.createElement('button');view.type='button';view.textContent='地圖查看';view.onclick=()=>previewMemory(r);const b=doc.createElement('button');b.type='button';b.textContent='刪除';b.onclick=()=>{memory.remove(r.id);queueBackup();showPersonal();};row.append(text,view,b);list.append(row);}
  }
  status('plannerBackupStatus',backupStatus);if(!personal.open)personal.showModal();
 }
 let backupStatus='自動備份尚未連線；可先匯出個人備份。';
 function queueBackup(){clearTimeout(backupTimer);backupTimer=setTimeout(()=>{if(root.DoorPersonalSync?.save)root.DoorPersonalSync.save(P.makeBackup(localStorage)).then(msg=>{backupStatus=msg;status('plannerBackupStatus',msg);}).catch(e=>{backupStatus='備份未完成：'+e.message;status('plannerBackupStatus',backupStatus);});},1200);}
 menu.onclick=showPersonal;$('plannerMemoryToggle').onchange=e=>{localStorage.setItem('581-route-memory-enabled-v1',e.target.checked?'1':'0');queueBackup();};
 $('plannerExport').onclick=async()=>{try{const text=JSON.stringify(P.makeBackup(localStorage),null,2);if(root.__door581Probe?.exportPersonalBackup){root.__door581Probe.exportPersonalBackup(text);return;}const file=new File([text],'581-DoorMap-個人備份.json',{type:'application/json'});
  if(navigator.canShare?.({files:[file]})){await navigator.share({files:[file],title:'Door Map 個人備份'});return;}
  const url=URL.createObjectURL(file),a=doc.createElement('a');a.href=url;a.download=file.name;doc.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),30000);
  status('plannerBackupStatus','備份已交給瀏覽器匯出；請確認檔案已儲存。');
 }catch(e){if(e.name!=='AbortError')status('plannerBackupStatus','匯出失敗：'+e.message);}};
 $('plannerImport').onchange=async e=>{const f=e.target.files?.[0];if(!f)return;try{if(f.size>P.MAX_BACKUP_BYTES)throw Error('備份檔太大');const data=P.validateBackup(await f.text());if(!root.confirm('還原 '+data.memories.length+' 段路線記憶與 '+data.areas.length+' 個避開區？目前個人資料將被替換，圖資不會更動。'))return;
  const old=P.makeBackup(localStorage);localStorage.setItem('581-personal-before-restore-v1',JSON.stringify(old));P.restoreBackup(localStorage,data);memory.load();h.refreshSettings();queueBackup();showPersonal();status('plannerBackupStatus','個人資料已還原；原本資料留有一份還原前備份。');
 }catch(err){status('plannerBackupStatus','未還原：'+err.message);}finally{e.target.value='';}};
 sync();return {get editing(){return editor.active;},openEditor,cancel,sync,renderPoints,remember,preferred,queueBackup,showPersonal,diagnostics:()=>({editing:editor.active,points:editor.via?.length||0,selected:editor.selected,ready:editor.ready,error:editor.error||'',memories:memory.rows.length,learnsGPS:false,search:{...trace,rows:candidateRows.map(r=>({...r})),pins:lastSearchRows.map(r=>({...r}))}}),test:{editor,memory}};
}
root.DoorPlanner={install};
})(globalThis);
