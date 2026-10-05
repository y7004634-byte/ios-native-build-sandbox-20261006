(() => {
  'use strict';

  // Refuse a partially loaded release. SRI prevents stale script execution;
  // the document's final boot check offers recovery without erasing user data.
  if(window.__581AssetFailure)return;

  const VERSION = '0.3.78-standalone';
  const cameraResumePreference=window.DoorCameraInteraction?.readPreference?.(localStorage);
  let cameraInteraction=null;
  let planner = null;
  let mapExtras = null;
  let buildings3d = null;
  let adaptiveScene = null;
  const DEFAULT_CENTER = [120.6736, 24.1477]; // Taichung fallback view only; never treated as destination.
  const NLSC_STYLE = {
    version: 8,
    glyphs: 'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf',
    sources: {
      nlsc: {
        type: 'raster',
        tiles: ['https://wmts.nlsc.gov.tw/wmts/EMAP/default/GoogleMapsCompatible/{z}/{y}/{x}'],
        tileSize: 256,
        maxzoom: 19,
        attribution: '國土測繪中心 NLSC'
      }
    },
    layers: [{ id: 'nlsc', type: 'raster', source: 'nlsc', minzoom: 0, maxzoom: 22 }]
  };
  // IMPORTANT: one immutable base style for the lifetime of the map.
  // Day/night switching changes paint properties only. Do NOT call setStyle()
  // from theme switching: setStyle destroys all custom sources/layers.
  const MAIN_STYLE_BASE = 'https://tiles.openfreemap.org/styles/dark';
  const NLSC_DOORPLATE_MIN_ZOOM = 19.35; // close-only raster fallback; independent labels use projected street-block scale
  const ROUTE_REROUTE_DEVIATION_M = 35;
  const ROUTE_HARD_DEVIATION_M = 65;
  const ROUTE_MIN_REROUTE_INTERVAL_MS = 7000;
  const NAVIGATION_PITCH = 62;
  const NAVIGATION_ZOOM = 16.2;
  // v0.3.66 stable-forward 3D: keep a fixed riding composition instead of
  // repeatedly zooming/pitching for every maneuver. FIT remains the 2D overview.
  const STABLE_3D_PITCH = 58;
  const STABLE_3D_ZOOM = 16.8;
  const STABLE_3D_ARRIVAL_ZOOM = 18.15;
  const STABLE_3D_BEARING_DEADZONE = 3;
  const STABLE_3D_BEARING_RATE_DPS = 58;
  const ROUTE_ALTERNATE_MAX = 2;
  const DESTINATION_CORRECTION_MIN_M = 4;
  const DESTINATION_CORRECTION_MAX_M = 90;
  const DESTINATION_ROAD_CENTER_M = 8;

  const DESTINATION_PRIMARY_RADIUS_M = 150;
  const DESTINATION_FALLBACK_RADIUS_M = 200;
  const ENTRANCE_MAX_RESULTS = 12;
  const COMMUNITY_MAX_RESULTS = 8;
  const PLACE_MAX_RESULTS = 12;
  const OSM_CACHE_TTL_MS = 24 * 60 * 60 * 1000;
  const OSM_STALE_FALLBACK_MS = 7 * 24 * 60 * 60 * 1000;

  const els = Object.fromEntries([
    'topHud','hudCollapseBtn','hudDetails','moreBtn','morePanel','pipViewBtn','routeVisibilityBtn','creditsBtn','creditsDialog','creditsIntro',
    'gpsState','modeText','distanceText','permissionCard','startSensorsBtn','setDestFromSheetBtn',
    'overviewBtn','followBtn','headingBtn','destBtn','destDialog','destInput','destError','applyDestBtn','searchHint',
    'centerPickReticle','centerCoordPanel','centerCoordToggle','centerCoordBody','centerCoordModeText','centerCoordText','copyCenterCoordBtn','navigateCenterBtn',
    'insetMap','insetEmpty','insetRecenterBtn','insetCorrectBtn','insetCorrectionReticle','insetCollapseBtn','osmStatus','routeStatus',
    'mainSceneStatus','addressResults','avatarDialog','avatarBtn','themeBtn','northModeBtn','routeBtn',
    'quickDistance','quickEta','powerDiagBtn','powerDiagDialog','powerDiagStatus','powerDiagReport','powerDiagStartBtn','powerDiagStopBtn','powerDiagCloseBtn',
    'insetTitleText','insetHouseNumber','toast','offlineBtn','offlineDialog','offlinePackStatus','offlineCoreStatus','offlinePlacesStatus','offlineAddressStatus','routeDataStatus','offlineProgressBar','offlineProgressText','offlineDownloadBtn','offlineDeleteBtn','offlineCloseBtn'
  ].map(id => [id, document.getElementById(id)]));

  const state = {
    destination: null,
    rawDestination: null,
    destinationIntent: null,
    destinationCorrection: { applied:false, source:'', distanceM:null, checked:false },
    // When an address-search result is picked, the bottom "導航到這裡" button
    // must keep that exact destination. It only falls back to map center after
    // the rider manually moves the map.
    centerNavigateSelectedDestination: null,
    // Map-center targeting is explicit: collapsed == disabled, expanded == enabled.
    centerPickEnabled: false,
    position: null,
    displayPosition: null,
    displayLeadMeters: 0,
    prevPosition: null,
    warmPosition: null,
    nativeNetworkOnline: null,
    compassHeading: null,
    gpsCourse: null,
    displayHeading: 0,
    mode: cameraResumePreference?.mode || 'north', // north | heading
    following: cameraResumePreference ? !['fit','manual'].includes(cameraResumePreference.owner) : true,
    cameraUserOverride: cameraResumePreference?.owner==='manual',
    cameraRestorePending: !!cameraResumePreference && cameraResumePreference.owner!=='manual',
    cameraGestureHold: false,
    cameraZoomOffset: 0,
    cameraGestureStartZoom: null,
    cameraLastFollowAt: 0,
    cameraPlan: null,
    arrivalCamera: { active:false, locked:false, zoom:null, pitch:null },
    deliveryVia:[],deliveryViaProgress:[],deliveryPicked:null,deliveryPreview:null,
    deliveryEditIndex:null,deliveryAwaitPick:false,deliveryManagerOpen:false,deliveryPreviewBusy:false,
    deliveryEditorKey:'', 
    deliveryPreviewSeq:0,deliveryRevision:0,deliveryLongPressAt:0,
    deliveryRenderCache:new Map(),deliveryRendering:false,deliveryRenderDirty:true,deliverySyncTimer:null,
    areaOverlayVisible:(()=>{try{return localStorage.getItem('581-avoid-overlay-visible-v1')!=='0';}catch(_){return true;}})(),
    areaBoundaryTimer:null,areaActiveKey:null,areaDetailId:null,areaRoutePhase:'idle',areaRouteNeedsRefresh:false,
    areaRouteIds:[],areaRouteExempt:[],areaRouteExemptIds:[],
    sanityRetryCache:new Map(),
    fitLocked: cameraResumePreference?.owner==='fit',
    fitGestureHold: false,
    fitGestureOrigin: null,
    fitLastEvalAt: -Infinity,
    fitLastPosition: null,
    fitLastRoute: null,
    fitLastLayout: '',
    fitLastFullAt: -Infinity,
    fitLastFullPosition: null,
    fitLastPlan: null,
    fitRouteWaiting: false,
    fitNeedsRefresh: false,
    fitStats: {evaluations:0,animations:0,fullSearches:0,lastComputeMs:0},
    pipView: localStorage.getItem('581-door-pip-view') !== '0',
    navigationRequested: !!cameraResumePreference?.navigationRequested,
    destinationDialogEpoch: 0,
    cleanDetailTimer: null,
    cleanDetailSeq: 0,
    cleanDetailAt: 0,
    cleanDetailCenter: null,
    cleanAddressCandidates: [],
    cleanAddressCount: 0,
    hudCollapsed: true,
    moreOpen: false,
    sensorStarted: false,
    geoStarted: false,
    orientationAttached: false,
    orientationEventSeen: false,
    lastOrientationAt: 0,
    orientationResumeTimer: null,
    watchId: null,
    lastPositionAt: 0,
    geoRecoveryTimer: null,
    geoRecoveryAttempts: 0,
    geoAttemptToken: 0,
    geoPermissionState: 'unknown',
    geoUserActionRequired: false,
    destinationHandoffSeq: 0,
    destinationHandoffBusy: false,
    destinationHandoffSource: '',
    destSyncLastAppliedAt: Number(localStorage.getItem('581-door-dest-sync-applied-at') || 0),
    destSyncPollSeq: 0,
    destSyncPollTimer: null,
    compassGrantedThisDocument: false,
    insetZoom: 19.5,
    mapsReady: false,
    firstFix: true,
    toastTimer: null,
    insetCollapsed: true,
    entranceRequestSeq: 0,
    entranceMarkers: [],
    insetEntranceMarkers: [],
    communityData: { type:'FeatureCollection', features:[] },
    communityLabelData: { type:'FeatureCollection', features:[] },
    entranceData: { type:'FeatureCollection', features:[] },
    entranceItems: [],
    communityItems: [],
    placeItems: [],
    placeData: { type:'FeatureCollection', features:[] },
    placeLabelData: { type:'FeatureCollection', features:[] },
    destinationInfo: { houseNumber:'', houseLabel:'', placeName:'', parentName:'', category:'', approximate:false },
    destinationInfoSeq: 0,
    theme: localStorage.getItem('581-door-theme') === 'light' ? 'light' : 'dark',
    routeEnabled: localStorage.getItem('581-door-route-enabled-v2') !== '0',
    routeGeoJson: { type:'FeatureCollection', features:[] },
    routeDisplayGeoJson: { type:'FeatureCollection', features:[] },
    routeProgressIndex: 0,
    alternateRouteGeoJson: { type:'FeatureCollection', features:[] },
    alternateRoutes: [],
    autoFitRoutePending: false,
    routeDistance: null,
    routeDuration: null,
    routeManeuvers: [],
    routeCandidateCount: 0,
    routeDataStatus: null,
    navigationActive: false,
    navigationAutoEntered: false,
    routeRequestedAt: 0,
    routeRequestSeq: 0,
    routeDeviationCount: 0,
    rerouteHeadingMismatchCount: 0,
    rerouteArmedTurn: null,
    routeLastOrigin: null,
    mainSceneSyncing: false,
    mainSceneLastSync: 0,
    insetSceneReady: false,
    mainSceneSyncTimer: null,
    mainScenePendingReason: '',
    addressSearchSeq: 0,
    avatarMode: ['classic','goku','luffy'].includes(localStorage.getItem('581-door-avatar'))
      ? localStorage.getItem('581-door-avatar')
      : 'classic',
    poiSearchSeq: 0,
    localSearchSeq:0, localSearchTimer:null, centerCoordRaf:0, manual3dAutoPitch:false,
    offlineMeta: null,
    offlineBusy: false
  };


  // v0.3.60: source-instance keyed writes. Geographic state is immutable between
  // updates; a new style creates new source objects and must be submitted again.
  // Skip only identical display data, NEVER GPS ingestion / route decisions.
  const sceneDataWrites=new WeakMap();
  const efficiencyStats={sourceWrites:0,sourceSkips:0,hiddenSkips:0,bySource:{}};
  function submitSceneData(targetMap,id,data,key=data) {
    const src=targetMap.getSource(id);if(!src)return false;
    if(document.hidden){efficiencyStats.hiddenSkips++;return false;}
    const token=(typeof data!=='function'&&data?.features?.length===0)?['empty']:Array.isArray(key)?key:[key];
    const prior=sceneDataWrites.get(src);
    if(prior&&prior.length===token.length&&token.every((v,i)=>Object.is(v,prior[i]))){efficiencyStats.sourceSkips++;globalThis.DoorPowerDiag?.mark?.('sourceSkip');return false;}
    src.setData(typeof data==='function'?data():data);sceneDataWrites.set(src,token.slice());globalThis.DoorPowerDiag?.mark?.('sourceWrite');
    efficiencyStats.sourceWrites++;efficiencyStats.bySource[id]=(efficiencyStats.bySource[id]||0)+1;return true;
  }


  // ============================================================
  // Taichung three-batch offline navigation pack
  // ① roads / intersections / OSM restrictions
  // ② communities / named buildings / places / entrances & gates
  // ③ structured address index (official Taichung GIS when available,
  //    with OSM addr:* inside the OSM tiles as an always-available fallback)
  // ============================================================
  const OFFLINE_PACK_ID='taichung';
  const OFFLINE_PACK_VERSION='tcg-2026-09-v7-prebuilt-resume-safe'; // baseline only; latest manifest may supersede it
  const OFFLINE_DB_NAME='581-door-offline-v1';
  const OFFLINE_DB_VERSION=3;
  const OFFLINE_OSM_Z=12;
  const OFFLINE_ADDRESS_Z=15;
  const OFFLINE_DEST_Z=16;
  const OFFLINE_DEST_PACK_ID='taichung-destination';
  const OFFLINE_DEST_PACK_VERSION='tcg-destination-202609-v2'; // baseline only; latest manifest may supersede it
  const OFFLINE_DEST_MANIFEST_URL='/offline/taichung-destination-v2/manifest.json';
  const OFFLINE_TAICHUNG_BOUNDS={west:120.45,south:23.95,east:121.48,north:24.50};
  const OFFLINE_PREBUILT_MANIFEST_URL='/offline/taichung-prebuilt/manifest.json';
  const OFFLINE_PREBUILT_CONCURRENCY=3;

  function openOfflineDb() {
    return new Promise((resolve,reject)=>{
      if (!('indexedDB' in window)) return reject(new Error('此瀏覽器不支援 IndexedDB'));
      const req=indexedDB.open(OFFLINE_DB_NAME,OFFLINE_DB_VERSION);
      req.onupgradeneeded=()=>{
        const db=req.result;
        if (!db.objectStoreNames.contains('meta')) db.createObjectStore('meta',{keyPath:'id'});
        if (!db.objectStoreNames.contains('osmTiles')) db.createObjectStore('osmTiles',{keyPath:'key'});
        if (!db.objectStoreNames.contains('addressChunks')) {
          const st=db.createObjectStore('addressChunks',{keyPath:'id'});
          st.createIndex('tile','tile',{unique:false});
        }
        if (!db.objectStoreNames.contains('destinationChunks')) {
          const st=db.createObjectStore('destinationChunks',{keyPath:'id'});
          st.createIndex('tile','tile',{unique:false});
        }
        if (!db.objectStoreNames.contains('osmTilesB')) db.createObjectStore('osmTilesB',{keyPath:'key'});
        if (!db.objectStoreNames.contains('addressChunksB')) {
          const st=db.createObjectStore('addressChunksB',{keyPath:'id'});
          st.createIndex('tile','tile',{unique:false});
        }
        if (!db.objectStoreNames.contains('destinationChunksB')) {
          const st=db.createObjectStore('destinationChunksB',{keyPath:'id'});
          st.createIndex('tile','tile',{unique:false});
        }
      };
      req.onsuccess=()=>resolve(req.result);
      req.onerror=()=>reject(req.error || new Error('IndexedDB open failed'));
    });
  }

  async function offlineDbGet(store,key) {
    const db=await openOfflineDb();
    return await new Promise((resolve,reject)=>{
      const tx=db.transaction(store,'readonly');
      const req=tx.objectStore(store).get(key);
      req.onsuccess=()=>resolve(req.result || null);
      req.onerror=()=>reject(req.error);
      tx.oncomplete=()=>db.close();
      tx.onerror=()=>{try{db.close()}catch(_){}};
    });
  }

  async function offlineDbPut(store,value) {
    const db=await openOfflineDb();
    return await new Promise((resolve,reject)=>{
      const tx=db.transaction(store,'readwrite');
      tx.objectStore(store).put(value);
      tx.oncomplete=()=>{db.close();resolve()};
      tx.onerror=()=>{const e=tx.error;db.close();reject(e)};
      tx.onabort=()=>{const e=tx.error;db.close();reject(e)};
    });
  }

  async function offlineDbDelete(store,key) {
    const db=await openOfflineDb();
    return await new Promise((resolve,reject)=>{
      const tx=db.transaction(store,'readwrite');
      tx.objectStore(store).delete(key);
      tx.oncomplete=()=>{db.close();resolve()};
      tx.onerror=tx.onabort=()=>{const e=tx.error;db.close();reject(e)};
    });
  }

  async function offlineDbBulkPut(store,values) {
    if (!values?.length) return;
    const db=await openOfflineDb();
    return await new Promise((resolve,reject)=>{
      const tx=db.transaction(store,'readwrite');
      const st=tx.objectStore(store);
      for (const v of values) st.put(v);
      tx.oncomplete=()=>{db.close();resolve()};
      tx.onerror=()=>{const e=tx.error;db.close();reject(e)};
      tx.onabort=()=>{const e=tx.error;db.close();reject(e)};
    });
  }

  async function offlineDbClear(store) {
    const db=await openOfflineDb();
    return await new Promise((resolve,reject)=>{
      const tx=db.transaction(store,'readwrite');
      tx.objectStore(store).clear();
      tx.oncomplete=()=>{db.close();resolve()};
      tx.onerror=()=>{const e=tx.error;db.close();reject(e)};
    });
  }

  async function offlineDbGetAllByIndex(store,indexName,key) {
    const db=await openOfflineDb();
    return await new Promise((resolve,reject)=>{
      const tx=db.transaction(store,'readonly');
      const req=tx.objectStore(store).index(indexName).getAll(key);
      req.onsuccess=()=>resolve(req.result || []);
      req.onerror=()=>reject(req.error);
      tx.oncomplete=()=>db.close();
    });
  }

  function offlineValidTaiwanPoint(lat,lng) { return Number.isFinite(lat)&&Number.isFinite(lng)&&lat>=20&&lat<=27&&lng>=117&&lng<=123; }
  function lon2tile(lon,z) { return Math.floor((lon+180)/360*(2**z)); }
  function lat2tile(lat,z) {
    const r=lat*Math.PI/180;
    return Math.floor((1-Math.asinh(Math.tan(r))/Math.PI)/2*(2**z));
  }
  function tile2lon(x,z) { return x/(2**z)*360-180; }
  function tile2lat(y,z) {
    const n=Math.PI-2*Math.PI*y/(2**z);
    return 180/Math.PI*Math.atan(.5*(Math.exp(n)-Math.exp(-n)));
  }
  function offlineTileKey(z,x,y) { return `${z}/${x}/${y}`; }
  function offlineTileBounds(z,x,y) {
    return {west:tile2lon(x,z),east:tile2lon(x+1,z),north:tile2lat(y,z),south:tile2lat(y+1,z)};
  }
  function offlineTilesForBbox(bbox,z=OFFLINE_OSM_Z) {
    const x1=lon2tile(bbox.west,z),x2=lon2tile(bbox.east,z);
    const y1=lat2tile(bbox.north,z),y2=lat2tile(bbox.south,z);
    const out=[];
    for (let x=Math.min(x1,x2);x<=Math.max(x1,x2);x++) {
      for (let y=Math.min(y1,y2);y<=Math.max(y1,y2);y++) out.push({z,x,y,key:offlineTileKey(z,x,y)});
    }
    return out;
  }
  function bboxAroundPoint(point,radiusM) {
    const latPad=radiusM/111320;
    const lngPad=radiusM/(111320*Math.max(.2,Math.cos(point.lat*Math.PI/180)));
    return {west:point.lng-lngPad,east:point.lng+lngPad,south:point.lat-latPad,north:point.lat+latPad};
  }
  function routeOfflineBbox(coords,padM=180) {
    let west=Infinity,east=-Infinity,south=Infinity,north=-Infinity;
    for (const p of coords||[]) {
      if (!Number.isFinite(p?.[0])||!Number.isFinite(p?.[1])) continue;
      west=Math.min(west,p[0]);east=Math.max(east,p[0]);south=Math.min(south,p[1]);north=Math.max(north,p[1]);
    }
    if (!Number.isFinite(west)) return null;
    const mid=(south+north)/2;
    const latPad=padM/111320;
    const lngPad=padM/(111320*Math.max(.2,Math.cos(mid*Math.PI/180)));
    return {west:west-lngPad,east:east+lngPad,south:south-latPad,north:north+latPad};
  }

  function taichungOfflineTileList() { return offlineTilesForBbox(OFFLINE_TAICHUNG_BOUNDS,OFFLINE_OSM_Z); }

  function offlineCoreStores(slot='A') {
    return slot==='B'
      ? {osm:'osmTilesB',address:'addressChunksB'}
      : {osm:'osmTiles',address:'addressChunks'};
  }
  function offlineDestinationStore(slot='A') { return slot==='B' ? 'destinationChunksB' : 'destinationChunks'; }
  function inactiveSlot(active='A') { return active==='B' ? 'A' : 'B'; }

  function setOfflineProgress(value,text) {
    const pct=Math.max(0,Math.min(1,Number(value)||0));
    const bar=els.offlineProgressBar?.querySelector('i');
    if (bar) bar.style.width=`${Math.round(pct*100)}%`;
    if (els.offlineProgressText) els.offlineProgressText.textContent=text || '';
  }

  async function estimateOfflineStorageText() {
    try {
      const e=await navigator.storage?.estimate?.();
      if (!e || !Number.isFinite(e.usage)) return '';
      const mb=e.usage/1024/1024;
      return `瀏覽器已用 ${mb.toFixed(1)} MB`;
    } catch (_) { return ''; }
  }

  function formatOfflineBytes(bytes) {
    const n=Number(bytes)||0;
    if (n>=1024*1024*1024) return `${(n/1024/1024/1024).toFixed(2)} GB`;
    if (n>=1024*1024) return `${(n/1024/1024).toFixed(1)} MB`;
    if (n>=1024) return `${(n/1024).toFixed(1)} KB`;
    return `${n} B`;
  }

  function routeDataDateText(raw){
    const sec=Number(raw?.tileset_last_modified);if(!Number.isFinite(sec)||sec<=0)return '無法取得更新時間';
    const d=new Date(sec*1000);return `路由圖最後修改 ${d.toLocaleString('zh-TW',{hour12:false})}`;
  }
  async function refreshRouteDataStatus(){
    try{const res=await fetch('/api/route-status',{cache:'no-store'});if(!res.ok)throw Error(`HTTP ${res.status}`);const data=await res.json();state.routeDataStatus=data;if(els.routeDataStatus)els.routeDataStatus.textContent=`${routeDataDateText(data)} · Valhalla ${data.version||''}`;return data;}
    catch(err){if(els.routeDataStatus)els.routeDataStatus.textContent='線上路由狀態暫時無法取得';return null;}
  }
  const OFFLINE_UPDATE_CHECK_MS=6*60*60*1000;
  async function checkOfflineDataUpdates({notify=true,force=false}={}){
    const now=Date.now(),last=Number(localStorage.getItem('581-offline-last-check')||0);
    if(!force && last>0 && now-last<OFFLINE_UPDATE_CHECK_MS){
      state.offlineUpdateAvailable=localStorage.getItem('581-offline-update-available')==='1';
      if(els.offlineBtn)els.offlineBtn.classList.toggle('update',state.offlineUpdateAvailable);
      return state.offlineUpdateAvailable;
    }
    try{
      const [core,dest]=await Promise.all([fetchPrebuiltManifest(),fetchDestinationManifest()]);
      const [installed,destInstalled]=await Promise.all([offlineDbGet('meta',OFFLINE_PACK_ID).catch(()=>null),offlineDbGet('meta',OFFLINE_DEST_PACK_ID).catch(()=>null)]);
      const available=!installed||installed.version!==core.version||installed.manifestSha256!==core.manifestSha256||!destInstalled||destInstalled.version!==dest.version||destInstalled.manifestSha256!==dest.manifestSha256;
      state.offlineLatest={core,dest};state.offlineUpdateAvailable=available;localStorage.setItem('581-offline-last-check',String(now));localStorage.setItem('581-offline-update-available',available?'1':'0');
      if(els.offlineBtn){els.offlineBtn.classList.toggle('update',available);if(available)els.offlineBtn.title='台中離線資料有新版可更新';}
      if(available&&notify){
        const key=`${core.manifestSha256||core.version}|${dest.manifestSha256||dest.version}`,last=localStorage.getItem('581-offline-update-notified');
        if(last!==key){localStorage.setItem('581-offline-update-notified',key);toast('台中離線資料有新版可更新');try{if(globalThis.Notification?.permission==='granted')new Notification('Door Map 離線資料可更新',{body:'道路、場所或門牌資料已有新版；打開「離線資料」即可一鍵更新。'});}catch(_){}}
      }
      return available;
    }catch(_){localStorage.setItem('581-offline-last-check',String(now));return false;}
  }

  async function refreshOfflinePackUi() {
    let meta=null;
    try { meta=await offlineDbGet('meta',OFFLINE_PACK_ID); } catch (_) {}
    state.offlineMeta=meta;
    const destMeta=await offlineDbGet('meta',OFFLINE_DEST_PACK_ID).catch(()=>null);
    const destReady=!!destMeta?.version && !!destMeta?.complete;
    const expected=taichungOfflineTileList().length;
    const core=Number(meta?.osmTilesDone||0);
    const addressCount=Number(meta?.addressCount ?? meta?.officialAddressCount ?? 0);
    const baseComplete=!!meta?.version && core>=expected && !!meta?.addressIndexReady && addressCount>0;
    const official=await window.DoorOfficial?.status?.().catch(()=>null);
    const complete=baseComplete && destReady && (!window.DoorOfficial || !!official?.complete);
    const degradedCount=Number(meta?.osmTilesFailed||0);
    const partial=!!meta && !complete;
    const storage=await estimateOfflineStorageText();
    const packSize=Number(meta?.packBytes||0);
    if (els.offlineBtn) {
      els.offlineBtn.classList.toggle('ready',complete);
      els.offlineBtn.classList.toggle('partial',partial);
      els.offlineBtn.classList.toggle('update',!!state.offlineUpdateAvailable);
      els.offlineBtn.title=state.offlineUpdateAvailable?'台中離線資料有新版可更新':(complete?'台中預建離線資料已安裝':'台中預建離線資料未完整');
    }
    if (els.offlinePackStatus) {
      els.offlinePackStatus.textContent=meta
        ? `${complete?'台中預建離線包可用':'台中預建離線包未完整'}${degradedCount?` · ${degradedCount} 區塊需要時線上補抓`:''} · ${meta.version||'未知版本'}${packSize?` · 成品 ${formatOfflineBytes(packSize)}`:''}${storage?` · ${storage}`:''}`
        : `尚未下載台中預建離線包${storage?` · ${storage}`:''}`;
    }
    if (els.offlineCoreStatus) els.offlineCoreStatus.textContent=core ? `${core}/${expected} 區塊（預建）${degradedCount?` · ${degradedCount} 線上補抓`:''}` : '未下載';
    if (els.offlinePlacesStatus) els.offlinePlacesStatus.textContent=destReady
      ? `目的地場所擴充 ${Number(destMeta.featureCount||0).toLocaleString()} 筆 · z${OFFLINE_DEST_Z} 分片（150m→必要時200m）`
      : (core ? '舊場所核心可用；按更新補下載目的地場所擴充包' : '未下載');
    if (els.offlineAddressStatus) {
      const count=Number(meta?.addressCount ?? meta?.officialAddressCount ?? 0);
      if (count>0 && meta?.officialAddressReady) els.offlineAddressStatus.textContent=`官方 GIS ${count.toLocaleString()} 筆（預建）`;
      else if (count>0) els.offlineAddressStatus.textContent=`OSM 門牌 fallback ${count.toLocaleString()} 筆（預建）`;
      else els.offlineAddressStatus.textContent=core>0?'門牌索引尚未完成':'未下載';
    }
    if(window.DoorOfficial && els.offlineAddressStatus){
      els.offlineAddressStatus.textContent=official?.complete
        ? `官方 GIS ${official.total.toLocaleString()} 筆 · ${official.dataDate}（已下載）`
        : `官方 GIS 756,225 筆可線上分片讀取；全區離線${official?.installedRows?`已匯入 ${official.installedRows.toLocaleString()} 筆，可續傳`:'尚未下載'}`;
      if(baseComplete && !official?.complete && els.offlinePackStatus)
        els.offlinePackStatus.textContent=`既有導航／場所離線包保留可用${degradedCount?` · ${degradedCount} 區塊需要時線上補抓`:''}；本次只需補下載官方門牌${storage?` · ${storage}`:''}`;
    }
    return meta;
  }

  async function fetchPrebuiltManifest() {
    const res=await fetch(`${OFFLINE_PREBUILT_MANIFEST_URL}?t=${Math.floor(Date.now()/3600000)}`,{headers:{'Accept':'application/json'},cache:'no-store'});
    if (!res.ok) throw new Error(`預建資料包 manifest HTTP ${res.status}`);
    const m=await res.json();
    if (!m?.version || !Array.isArray(m.files)) throw new Error(`預建資料包版本異常：${m?.version||'unknown'}`);
    if (Number(m.osmTileCount||0)!==taichungOfflineTileList().length) throw new Error(`預建資料包區塊數異常：${m.osmTileCount||0}`);
    if (!Number.isFinite(Number(m.addressCount)) || Number(m.addressCount)<=0 || !m.addressIndexReady) throw new Error('預建資料包缺少可用門牌索引');
    return m;
  }

  async function fetchPrebuiltJsonFile(file,version) {
    const url=new URL(file.path,location.origin);url.searchParams.set('pv',version);
    const res=await fetch(url,{headers:{'Accept':'application/json'},cache:'force-cache'});
    if (!res.ok) throw new Error(`${file.id||file.path} HTTP ${res.status}`);
    const text=await res.text();if(Number(file.bytes)>0&&text.length<20)throw new Error(`${file.id||file.path} 內容異常`);
    const obj=JSON.parse(text);if(obj?.version!==version)throw new Error(`${file.id||file.path} 版本不符`);return obj;
  }

  async function importPrebuiltFile(file,obj,{version,stores}) {
    if (file.kind==='osm') {
      if (!Array.isArray(obj.tiles)) throw new Error(`${file.id} OSM 格式錯誤`);
      const records=obj.tiles.map(t=>{const logicalKey=String(t.key),parts=Math.max(1,Number(t.parts||1)),part=Math.max(0,Number(t.part||0));return {key:parts>1?`${logicalKey}#${part}`:logicalKey,logicalKey,part,parts,z:Number(t.z),x:Number(t.x),y:Number(t.y),version,updatedAt:Number(obj.createdAt||Date.now()),elements:Array.isArray(t.elements)?t.elements:[],degraded:!!t.degraded,recovery:t.recovery||null};});
      await offlineDbBulkPut(stores.osm,records);return {osm:obj.tiles.filter(t=>Math.max(0,Number(t.part||0))===0).length,address:0};
    }
    if (file.kind==='addresses') {
      if (!Array.isArray(obj.chunks)) throw new Error(`${file.id} 門牌格式錯誤`);
      const chunks=obj.chunks.map(ch=>({id:String(ch.id),tile:String(ch.tile),version,rows:Array.isArray(ch.rows)?ch.rows:[]}));
      await offlineDbBulkPut(stores.address,chunks);let rows=0;for(const ch of chunks)rows+=ch.rows.length;return {osm:0,address:rows};
    }
    throw new Error(`未知預建檔案類型：${file.kind}`);
  }

  async function fetchDestinationManifest(){
    const res=await fetch(`${OFFLINE_DEST_MANIFEST_URL}?t=${Math.floor(Date.now()/3600000)}`,{headers:{Accept:'application/json'},cache:'no-store'});
    if(!res.ok)throw new Error(`目的地場所 manifest HTTP ${res.status}`);
    const m=await res.json();if(!m?.version||!Array.isArray(m.files)||Number(m.indexZoom)!==OFFLINE_DEST_Z)throw new Error('目的地場所資料包版本異常');return m;
  }

  async function installDestinationAddon(manifest=null){
    const prior=await offlineDbGet('meta',OFFLINE_DEST_PACK_ID).catch(()=>null);manifest=manifest||await fetchDestinationManifest();
    if(prior?.version===manifest.version&&prior?.manifestSha256===manifest.manifestSha256&&prior?.complete)return prior;
    const slot=inactiveSlot(prior?.slot||'A'),store=offlineDestinationStore(slot);await offlineDbClear(store);
    let loaded=0,features=0;
    const meta={id:OFFLINE_DEST_PACK_ID,version:manifest.version,slot,installedAt:Date.now(),complete:false,manifestSha256:String(manifest.manifestSha256||''),featureCount:Number(manifest.featureCount||0),chunkCount:Number(manifest.chunkCount||0),packBytes:Number(manifest.totalBytes||0),degradedSourceTiles:Array.isArray(manifest.degradedSourceTiles)?manifest.degradedSourceTiles.slice():[]};
    for(let i=0;i<manifest.files.length;i++){
      const file=manifest.files[i],url=new URL(file.path,location.origin);url.searchParams.set('dv',manifest.version);
      const res=await fetch(url.href,{headers:{Accept:'application/json'},cache:'force-cache'});if(!res.ok)throw new Error(`${file.id||file.path} HTTP ${res.status}`);
      const obj=await res.json();if(obj?.version!==manifest.version||!Array.isArray(obj.chunks))throw new Error(`${file.id||file.path} 格式錯誤`);
      const rows=obj.chunks.map(ch=>({id:String(ch.id||ch.tile),tile:String(ch.tile||ch.id),version:manifest.version,elements:Array.isArray(ch.elements)?ch.elements:[]}));
      await offlineDbBulkPut(store,rows);loaded+=rows.length;for(const r of rows)features+=r.elements.length;
      setOfflineProgress(.03+.40*((i+1)/Math.max(1,manifest.files.length)),`補目的地場所 ${i+1}/${manifest.files.length} 檔 · ${loaded.toLocaleString()} 分片`);
    }
    if(loaded!==Number(manifest.chunkCount||0))throw new Error(`目的地場所匯入不完整：${loaded}/${manifest.chunkCount}`);
    meta.complete=true;meta.completedAt=Date.now();meta.importedEntries=features;await offlineDbPut('meta',meta);return meta;
  }

  async function installOfficialAddressAddon(){
    if(!window.DoorOfficial)throw new Error('官方門牌模組未載入，請重新整理新版頁面');
    const prior=await window.DoorOfficial.status?.().catch(()=>null);
    if(prior?.complete){
      // Destination-data updates must not re-walk or re-download the
      // already-complete 756,225-row official address add-on.
      setOfflineProgress(1,`既有官方門牌 ${Number(prior.total||756225).toLocaleString()} 筆保留；目的地場所更新完成`);
      return prior;
    }
    setOfflineProgress(.01,'補下載官方門牌；保留既有導航／場所離線資料…');
    const done=await window.DoorOfficial.install({onProgress:p=>setOfflineProgress(.03+.94*p.bytes/Math.max(1,p.totalBytes),
      `官方門牌 ${p.count.toLocaleString()}/${p.total.toLocaleString()} 筆 · ${p.files}/${p.totalFiles} 檔 · ${formatOfflineBytes(p.bytes)} / ${formatOfflineBytes(p.totalBytes)}`)});
    setOfflineProgress(1,`官方門牌 ${done.count.toLocaleString()} 筆完成；既有導航／場所離線包保留`);
    if(mapExtras){mapExtras.houseReadKey='';mapExtras.scheduleHouses();}
    toast('官方門牌離線資料已完成');
    return done;
  }

  async function installTaichungOfflinePack() {
    if (state.offlineBusy) return;
    state.offlineBusy=true;if(els.offlineDownloadBtn)els.offlineDownloadBtn.disabled=true;if(els.offlineDeleteBtn)els.offlineDeleteBtn.disabled=true;
    try {
      setOfflineProgress(.01,'檢查最新版離線資料…');
      const [manifest,destManifest]=await Promise.all([fetchPrebuiltManifest(),fetchDestinationManifest()]);
      const prior=await offlineDbGet('meta',OFFLINE_PACK_ID).catch(()=>null);
      const sameCore=prior?.version===manifest.version&&prior?.manifestSha256===manifest.manifestSha256&&prior?.osmTilesDone>=manifest.osmTileCount&&prior?.addressIndexReady&&Number(prior?.addressCount||0)>=Number(manifest.addressCount||0);
      if(!sameCore){
        const slot=inactiveSlot(prior?.slot||'A'),stores=offlineCoreStores(slot);
        // A/B staging: the active pack stays untouched until every file has imported successfully.
        await Promise.all([offlineDbClear(stores.osm),offlineDbClear(stores.address)]);try{await navigator.storage?.persist?.();}catch(_){ }
        const meta={id:OFFLINE_PACK_ID,version:manifest.version,slot,installedAt:Date.now(),osmTilesDone:0,osmTilesFailed:Number(manifest.degradedTileCount||0),degradedTiles:Array.isArray(manifest.degradedTiles)?manifest.degradedTiles.slice():[],addressCount:0,addressIndexReady:false,officialAddressCount:0,officialAddressReady:false,packBytes:Number(manifest.totalBytes||0),manifestSha256:String(manifest.manifestSha256||''),osmTileParts:manifest.osmTileParts&&typeof manifest.osmTileParts==='object'?manifest.osmTileParts:{},prebuilt:true,sources:manifest.sources||{}};
        let osm=0,address=0;
        for(let i=0;i<manifest.files.length;i++){
          const file=manifest.files[i],obj=await fetchPrebuiltJsonFile(file,manifest.version),n=await importPrebuiltFile(file,obj,{version:manifest.version,stores});osm+=n.osm;address+=n.address;
          setOfflineProgress(.03+.42*((i+1)/Math.max(1,manifest.files.length)),`下載道路/門牌 ${i+1}/${manifest.files.length} 檔`);
        }
        if(osm<Number(manifest.osmTileCount||0)||address<Number(manifest.addressCount||0))throw new Error(`新版資料驗證失敗：道路 ${osm}/${manifest.osmTileCount}、門牌 ${address}/${manifest.addressCount}`);
        meta.osmTilesDone=osm;meta.addressCount=address;meta.addressIndexReady=true;meta.complete=true;meta.completedAt=Date.now();
        // Atomic logical switch: one meta write changes the active A/B slot. Previous slot is retained as rollback.
        await offlineDbPut('meta',meta);state.offlineMeta=meta;
      }
      await installDestinationAddon(destManifest);
      await installOfficialAddressAddon();
      localStorage.setItem('581-offline-last-check',String(Date.now()));localStorage.setItem('581-offline-update-available','0');
      state.offlineUpdateAvailable=false;toast(sameCore?'離線資料已是最新版':'離線資料已更新；舊版仍保留作回復');
    } catch(err) {
      setOfflineProgress(0,`更新失敗：${String(err?.message||err).slice(0,150)}；仍使用原本資料`);toast('離線資料更新失敗；原本版本未切換');
    } finally {
      state.offlineBusy=false;if(els.offlineDownloadBtn)els.offlineDownloadBtn.disabled=false;if(els.offlineDeleteBtn)els.offlineDeleteBtn.disabled=false;await refreshOfflinePackUi();
    }
  }

  async function deleteTaichungOfflinePack() {
    if (state.offlineBusy) return;
    state.offlineBusy=true;
    try {
      await Promise.all([offlineDbClear('osmTiles'),offlineDbClear('addressChunks'),offlineDbClear('destinationChunks'),offlineDbClear('osmTilesB'),offlineDbClear('addressChunksB'),offlineDbClear('destinationChunksB'),offlineDbClear('meta')]);
      await window.DoorOfficial?.clear?.();
      if(mapExtras){mapExtras.houseCache.clear();mapExtras.offlineRows=[];mapExtras.houseReadKey='';mapExtras.houseKey='';mapExtras.scheduleHouses();}
      state.offlineMeta=null;setOfflineProgress(0,'資料包已刪除');toast('台中離線導航資料已刪除');
    } finally {state.offlineBusy=false;await refreshOfflinePackUi();}
  }

  async function offlineLoadOsmTiles(tiles) {
    if (!tiles?.length) return {available:false,complete:false,elements:[],loaded:0,total:0};
    const meta=state.offlineMeta || await offlineDbGet('meta',OFFLINE_PACK_ID).catch(()=>null);
    if (!meta?.version) return {available:false,complete:false,elements:[],loaded:0,total:tiles.length};
    const partMap=meta.osmTileParts&&typeof meta.osmTileParts==='object'?meta.osmTileParts:{};
    const stores=offlineCoreStores(meta.slot||'A');
    const groups=await Promise.all(tiles.map(async t=>{
      const parts=Math.max(1,Number(partMap[t.key]||1));
      if(parts===1)return [await offlineDbGet(stores.osm,t.key).catch(()=>null)];
      return await Promise.all(Array.from({length:parts},(_,part)=>offlineDbGet(stores.osm,`${t.key}#${part}`).catch(()=>null)));
    }));
    const elements=[],seen=new Set();let loaded=0;
    for (let i=0;i<groups.length;i++) {
      const expected=Math.max(1,Number(partMap[tiles[i].key]||1));
      const records=(groups[i]||[]).filter(rec=>rec&&rec.version===meta.version&&Array.isArray(rec.elements));
      if(records.length!==expected)continue;
      if(!records.some(rec=>rec.degraded))loaded++;
      for(const rec of records)for (const el of rec.elements) {
        const k=`${el.type||'node'}:${el.id??`${el.lat},${el.lon}`}`;
        if (seen.has(k)) continue;seen.add(k);elements.push(el);
      }
    }
    return {available:loaded>0,complete:loaded===tiles.length,elements,loaded,total:tiles.length};
  }

  async function offlineElementsForRoute(coords,padM=180) {
    const bbox=routeOfflineBbox(coords,padM); if(!bbox) return {available:false,complete:false,elements:[],loaded:0,total:0};
    return await offlineLoadOsmTiles(offlineTilesForBbox(bbox,OFFLINE_OSM_Z));
  }

  async function offlineOfficialAddressesNear(dest,radiusM=140,includeOfficial=true) {
    const officialRaw=includeOfficial ? await window.DoorNativeBundle.officialNear(dest,radiusM).catch(()=>[]) : [];
    // Legacy destination matching/formatting expects a bare number and appends 號 itself.
    // Keep the recovered raw rows and map-layer labels unchanged; adapt only this boundary.
    const official=officialRaw.map(row=>({...row,houseNumber:String(row.houseNumber||'').replace(/號$/,'')}));
    const meta=state.offlineMeta || await offlineDbGet('meta',OFFLINE_PACK_ID).catch(()=>null);
    if (!meta?.addressIndexReady) return official;
    const tiles=offlineTilesForBbox(bboxAroundPoint(dest,radiusM),OFFLINE_ADDRESS_Z);
    const chunks=[];const stores=offlineCoreStores(meta.slot||'A');
    for (const t of tiles) chunks.push(...await offlineDbGetAllByIndex(stores.address,'tile',t.key).catch(()=>[]));
    const out=[];
    for (const ch of chunks) for (const row of ch.rows||[]) {
      const [lat,lng,houseNumber,road,lane,alley,area,district]=row;
      const point={lat:Number(lat),lng:Number(lng)};
      if (!offlineValidTaiwanPoint(point.lat,point.lng)) continue;
      const distance=haversineMeters(dest,point); if(distance>radiusM) continue;
      out.push({lat:point.lat,lng:point.lng,houseNumber:String(houseNumber||''),road:String(road||''),lane:String(lane||''),alley:String(alley||''),area:String(area||''),district:String(district||''),distance,containsDestination:distance<=6,source:meta?.officialAddressReady?'taichung-official-address':'osm-offline-address'});
    }
    const merged=[],seen=new Set();
    for(const row of [...official,...out]){
      const k=`${row.houseNumber}:${row.lat.toFixed(5)}:${row.lng.toFixed(5)}`;
      if(!seen.has(k)){seen.add(k);merged.push(row);}
    }
    return merged.sort((a,b)=>a.distance-b.distance);
  }

  async function offlineDestinationElementsNear(dest,radiusM) {
    const meta=await offlineDbGet('meta',OFFLINE_DEST_PACK_ID).catch(()=>null);
    if (!meta?.version || !meta.complete) return {available:false,complete:false,elements:[],loaded:0,total:0};
    const tiles=offlineTilesForBbox(bboxAroundPoint(dest,radiusM),OFFLINE_DEST_Z);
    const store=offlineDestinationStore(meta.slot||'A');
    const records=await Promise.all(tiles.map(t=>offlineDbGet(store,t.key).catch(()=>null)));
    const elements=[],seen=new Set();let loaded=0;
    for(const rec of records){if(!rec||rec.version!==meta.version||!Array.isArray(rec.elements))continue;loaded++;for(const el of rec.elements){const k=`${el.type||'node'}:${el.id??`${el.lat},${el.lon}`}`;if(seen.has(k))continue;seen.add(k);elements.push(el);}}
    // Missing z16 records are valid empty cells. Completeness is determined by
    // the z12 source tiles that failed while the add-on was built, not by whether
    // a quiet cell happened to contain a POI record.
    const degraded=new Set(Array.isArray(meta.degradedSourceTiles)?meta.degradedSourceTiles:[]);
    const sourceScale=2**(OFFLINE_DEST_Z-OFFLINE_OSM_Z);
    const complete=tiles.every(t=>!degraded.has(`${OFFLINE_OSM_Z}/${Math.floor(t.x/sourceScale)}/${Math.floor(t.y/sourceScale)}`));
    return {available:true,complete,elements,loaded,total:tiles.length};
  }

  async function offlineNearbyDataAtRadius(dest,radiusM) {
    const add=await offlineDestinationElementsNear(dest,radiusM);
    if (add.available) {
      const data=trimNearbyData(normalizeNearbyPoiElements(add.elements,dest),radiusM);
      const official=await offlineOfficialAddressesNear(dest,Math.min(180,radiusM)).catch(()=>[]);
      if (official.length) data.addresses=official.slice(0,80);
      return {available:true,complete:add.complete,data,loaded:add.loaded,total:add.total,officialAddresses:official.length,source:'destination-addon'};
    }
    // Backward-compatible fallback for riders who have not pressed offline update yet.
    const tiles=offlineTilesForBbox(bboxAroundPoint(dest,radiusM),OFFLINE_OSM_Z);
    const pack=await offlineLoadOsmTiles(tiles);
    if (!pack.available) return {available:false,complete:false,data:null};
    const data=trimNearbyData(normalizeNearbyPoiElements(pack.elements,dest),radiusM);
    const official=await offlineOfficialAddressesNear(dest,Math.min(180,radiusM)).catch(()=>[]);
    if (official.length) data.addresses=official.slice(0,80);
    return {available:true,complete:pack.complete,data,loaded:pack.loaded,total:pack.total,officialAddresses:official.length,source:'legacy-core'};
  }

  async function offlineNearbyData(dest) {
    const primary=await offlineNearbyDataAtRadius(dest,DESTINATION_PRIMARY_RADIUS_M);
    if (primary.available && nearbyDataUseful(primary.data)) return primary;
    const expanded=await offlineNearbyDataAtRadius(dest,DESTINATION_FALLBACK_RADIUS_M);
    return expanded.available ? expanded : primary;
  }

  async function initializeOfflinePack() { await refreshOfflinePackUi().catch(err=>console.warn('offline pack init',err)); }

  if (!window.maplibregl) {
    document.body.innerHTML = '<div style="padding:24px;font-family:sans-serif">MapLibre 載入失敗。請確認網路可連 unpkg.com。</div>';
    return;
  }

  document.body.dataset.theme = state.theme;
  const themeMeta = document.querySelector('meta[name="theme-color"]');
  if (themeMeta) themeMeta.setAttribute('content', state.theme === 'dark' ? '#0e1116' : '#eef1f4');

  const map = new maplibregl.Map({
    container: 'map',
    style: MAIN_STYLE_BASE,
    center: DEFAULT_CENTER,
    zoom: 13.5,
    bearing: 0,
    pitch: 0,
    attributionControl: false,
    locale:{'AttributionControl.ToggleAttribution':'地圖資料來源'},
    maxPitch: 65
  });
  const inset = new maplibregl.Map({
    container: 'insetMap',
    style: NLSC_STYLE,
    center: DEFAULT_CENTER,
    zoom: state.insetZoom,
    bearing: 0,
    pitch: 0,
    interactive: true,
    attributionControl: false,
    maxPitch: 0
  });
  // The inset is intentionally a fixed-scale "doorplate window":
  // single-finger drag is allowed, but zoom/rotate gestures are disabled.
  inset.dragPan.enable();
  inset.scrollZoom.enable();
  inset.boxZoom.disable();
  inset.dragRotate.disable();
  inset.keyboard.disable();
  inset.doubleClickZoom.disable();
  inset.touchZoomRotate.enable();
  inset.touchZoomRotate.disableRotation();
  inset.on('zoomend',()=>{state.insetZoom=inset.getZoom();const badge=document.querySelector('#insetCard .mini-badge');if(badge)badge.textContent=state.insetZoom.toFixed(1)+'×';});

  const userEl = document.createElement('div');
  userEl.className = 'user-marker direction-unavailable';
  userEl.innerHTML = `
    <div class="user-fan"></div>
    <div class="avatar-heading"></div>
    <div class="user-dot-halo"></div>
    <div class="user-dot"></div>
    <div class="nav-avatar-wrap"><img class="nav-avatar" alt="" /></div>
  `;
  const fanEl = userEl.querySelector('.user-fan');
  const avatarHeadingEl = userEl.querySelector('.avatar-heading');
  const avatarWrapEl = userEl.querySelector('.nav-avatar-wrap');
  const avatarImgEl = userEl.querySelector('.nav-avatar');
  const userMarker = new maplibregl.Marker({ element:userEl, anchor:'center', rotationAlignment:'viewport' });
  const visualMotion = window.DoorVisualMotion ? new window.DoorVisualMotion.Controller({map,marker:userMarker,getState:()=>state,documentRef:document}) : null;
  window.addEventListener('pagehide',()=>visualMotion?.suspend());
  window.addEventListener('pageshow',()=>visualMotion?.resume());

  const AVATAR_ASSETS = {
    goku:{front:'./assets/avatar_goku_nimbus.png',back:'./assets/avatar_goku_nimbus_back.png'},
    luffy:{front:'./assets/avatar_luffy.png',back:'./assets/avatar_luffy_back.png'}
  };

  function setAvatarMode(mode, {persist=true}={}) {
    state.avatarMode = ['classic','goku','luffy'].includes(mode) ? mode : 'classic';
    if (persist) localStorage.setItem('581-door-avatar', state.avatarMode);

    const classic = state.avatarMode === 'classic';
    userEl.classList.toggle('avatar-active', !classic);

    if (!classic) {
      avatarImgEl.src = AVATAR_ASSETS[state.avatarMode].front;
      avatarImgEl.alt = state.avatarMode === 'goku' ? 'Q版悟空觔斗雲導航角色' : 'Q版魯夫導航角色';
    } else {
      avatarImgEl.removeAttribute('src');
      avatarImgEl.alt = '';
    }

    if (els.avatarBtn) {
      els.avatarBtn.querySelector('.more-icon').textContent =
        state.avatarMode === 'classic' ? '角' :
        state.avatarMode === 'goku' ? '悟' : '魯';
      els.avatarBtn.classList.toggle('active', !classic);
    }

    document.querySelectorAll('.avatar-choice').forEach(btn => {
      btn.classList.toggle('selected', btn.dataset.avatar === state.avatarMode);
    });

    updateFanRotation();
  }

  function openAvatarDialog() {
    setAvatarMode(state.avatarMode,{persist:false});
    els.avatarDialog.showModal();
  }

  function makeNativePinImage() {
    // 64x80 backing pixels = 32x40 logical px at pixelRatio 2.
    // The visible tip touches the logical bottom edge.
    const canvas = document.createElement('canvas');
    canvas.width = 64;
    canvas.height = 80;
    const ctx = canvas.getContext('2d');
    if (!ctx) throw new Error('2D canvas unavailable');

    ctx.scale(2,2);
    ctx.lineJoin = 'round';

    ctx.beginPath();
    ctx.moveTo(16,39);
    ctx.bezierCurveTo(13,34,3.5,24,3.5,14);
    ctx.bezierCurveTo(3.5,6.5,9,1.5,16,1.5);
    ctx.bezierCurveTo(23,1.5,28.5,6.5,28.5,14);
    ctx.bezierCurveTo(28.5,24,19,34,16,39);
    ctx.closePath();
    ctx.fillStyle = '#ff5a52';
    ctx.fill();
    ctx.lineWidth = 3;
    ctx.strokeStyle = '#ffffff';
    ctx.stroke();

    ctx.beginPath();
    ctx.arc(16,14,4.7,0,Math.PI*2);
    ctx.fillStyle = '#ffffff';
    ctx.fill();

    return ctx.getImageData(0,0,64,80);
  }

  function destinationPinLabel(prefix) {
    const info = state.destinationInfo || {};
    const house = info.houseLabel || '';
    const place = info.parentName || info.placeName || '';
    if (prefix === 'inset') return house;
    if (house && place) return `${house}\n${place}`;
    return house || place;
  }

  function maneuverArrow(modifier,type='') {
    const m=String(modifier||'').toLowerCase(),t=String(type||'').toLowerCase();
    if(t==='roundabout'||t==='rotary')return '↻';
    if(m.includes('uturn'))return '↶';
    if(m.includes('sharp left'))return '↰';
    if(m.includes('slight left'))return '↖';
    if(m.includes('left'))return '↰';
    if(m.includes('sharp right'))return '↱';
    if(m.includes('slight right'))return '↗';
    if(m.includes('right'))return '↱';
    return '↑';
  }

  function nextRouteManeuver(point=null) {
    const rows=Array.isArray(state.routeManeuvers)?state.routeManeuvers:[];
    if(!rows.length||!state.position)return null;
    const progress=Math.max(0,Number(state.routeProgressIndex||0));
    const usable=rows.filter(m=>m&&m.type!=='depart'&&m.type!=='arrive'&&Number(m.routeIndex??0)>=progress-2);
    const next=usable[0];
    if(!next||!Array.isArray(next.location))return null;
    const displayPoint=point||state.displayPosition||state.position;
    const meters=haversineMeters(displayPoint,{lng:Number(next.location[0]),lat:Number(next.location[1])});
    return Number.isFinite(meters)?{...next,meters}:null;
  }

  function destinationSideEstimate(){
    if(!state.position||!state.destination||!(state.navigationRequested||state.navigationActive))return null;
    const remaining=haversineMeters(state.position,state.destination);if(!Number.isFinite(remaining)||remaining>260||remaining<55)return null;
    const anchor=window.DoorTargetSelection?.addressAnchor?.(state)?.point||state.destination;
    const side=window.DoorTargetSelection?.routeSide?.(anchor,state.routeDisplayGeoJson||state.routeGeoJson);
    if(!side||side.side==='unknown'||side.distance>24)return null;
    return {side:side.side,remaining,confidence:window.DoorTargetSelection?.addressAnchor?.(state)?'high':'medium'};
  }
  function updateEarlySideHint(){
    const el=document.getElementById('insetSideHint');if(!el)return;
    const hint=destinationSideEstimate();if(!hint){el.hidden=true;el.textContent='';delete el.dataset.confidence;return;}
    el.hidden=false;el.dataset.confidence=hint.confidence;el.textContent=hint.side==='left'?'左側':'右側';
  }

  function updateInsetTitle() {
    updateEarlySideHint();
    if(!els.insetHouseNumber)return;
    const appleOnly=window.__581AppleDestination===true;
    const info=appleOnly?{}:(state.destinationInfo||{});
    const view=window.DoorDestinationCard.data(info,appleOnly?{}:(state.destinationIntent||{}),!!state.destination);
    const caption=els.insetTitleText.querySelector('.inset-caption');
    if(caption){caption.textContent='';caption.hidden=true;}
    const road=String(info.road||'').trim();
    const house=String(info.houseLabel||'').trim();
    const compact=[road,house].filter(Boolean).join(' ');
    const destinationMeters=state.position&&state.destination?haversineMeters(state.position,state.destination):Infinity;
    const maneuver=destinationMeters>110?nextRouteManeuver():null;
    if(maneuver){
      const d=maneuver.meters<=12?'現在':maneuver.meters>=1000?`${(maneuver.meters/1000).toFixed(1)}km`:`${Math.max(10,Math.round(maneuver.meters/10)*10)}m`;
      const name=String(maneuver.name||'').trim();
      els.insetHouseNumber.textContent=`${maneuverArrow(maneuver.modifier,maneuver.type)} ${d}${name?`  ${name}`:''}`;
    } else {
      els.insetHouseNumber.textContent=appleOnly?'NLSC 門牌核對':(compact||view.detail||view.name||'未設定');
    }
    els.insetTitleText.title=[road,house,view.name,view.notice].filter(Boolean).join(' · ');
    els.insetCollapseBtn.setAttribute('aria-label',`${state.insetCollapsed?'展開':'收合'}終點資訊；${els.insetHouseNumber.textContent}`);
    syncInsetHandleHeight();
  }

  function syncInsetHandleHeight() {
    const card=document.getElementById('insetCard');
    if (!card || !els.insetCollapseBtn) return;
    const height=56;
    const px=`${height}px`;
    if (card.style.getPropertyValue('--inset-handle-height')!==px) {
      card.style.setProperty('--inset-handle-height',px);
      if (!state.insetCollapsed) inset.resize();
    }
  }

  function ensureNativeDestinationPin(targetMap, prefix, iconSize=1) {
    const imageId = `${prefix}-destination-pin-image`;
    const sourceId = `${prefix}-destination-pin-source`;
    const layerId = `${prefix}-destination-pin-symbol`;

    if (!targetMap.hasImage(imageId)) {
      targetMap.addImage(imageId, makeNativePinImage(), { pixelRatio:2 });
    }

    if (!targetMap.getSource(sourceId)) {
      targetMap.addSource(sourceId, {
        type:'geojson',
        data:emptyFeatureCollection()
      });
    }

    if (!targetMap.getLayer(layerId)) {
      targetMap.addLayer({
        id:layerId,
        type:'symbol',
        source:sourceId,
        layout:{
          'symbol-placement':'point',
          'icon-image':imageId,
          'icon-size':iconSize,
          'icon-anchor':'bottom',
          'icon-allow-overlap':true,
          'icon-ignore-placement':true,
          'icon-rotation-alignment':'viewport',
          'icon-pitch-alignment':'viewport',
          'text-field':['get','label'],
          'text-font':['Noto Sans Regular'],
          'text-size':prefix === 'inset' ? 10 : 12,
          'text-anchor':'bottom',
          'text-offset':prefix === 'inset' ? [0,-3.0] : [0,-3.65],
          'text-line-height':1.08,
          'text-max-width':13,
          'text-allow-overlap':true,
          'text-ignore-placement':true,
          'text-rotation-alignment':'viewport',
          'text-pitch-alignment':'viewport'
        },
        paint:{
          'text-color':prefix === 'inset' ? '#222831' : (state.theme === 'dark' ? '#ffffff' : '#26313d'),
          'text-halo-color':prefix === 'inset' ? 'rgba(255,255,255,.96)' : (state.theme === 'dark' ? 'rgba(20,25,32,.94)' : 'rgba(255,255,255,.96)'),
          'text-halo-width':2,
          'text-halo-blur':0.4
        }
      });
    }
  }

  function updateNativeDestinationPin(targetMap, prefix, dest) {
    const source = targetMap.getSource(`${prefix}-destination-pin-source`);
    if (!source) return;
    const label=destinationPinLabel(prefix);
    submitSceneData(targetMap,`${prefix}-destination-pin-source`,()=>dest ? {
      type:'FeatureCollection',
      features:[{
        type:'Feature',
        properties:{label},
        geometry:{type:'Point',coordinates:[dest.lng,dest.lat]}
      }]
    } : emptyFeatureCollection(),[dest?.lng??null,dest?.lat??null,label]);
    updateInsetTitle();
  }

  function bringNativeDestinationPinToFront(targetMap, prefix) {
    const layerId = `${prefix}-destination-pin-symbol`;
    if (targetMap.getLayer(layerId) && targetMap.getStyle()?.layers?.at(-1)?.id!==layerId) {
      targetMap.moveLayer(layerId);
    }
  }

  function isOperationalLayerId(id) {
    return id.startsWith('official-community-') || id === 'official-building-outline' || id.startsWith('extra-') || id.startsWith('delivery-') || id.startsWith('main-oneway-') || id === 'accuracy-fill' ||
           id === 'dest-guide-line' ||
           id === 'reference-route-line' ||
           id === 'reference-route-casing' ||
           id === 'alternate-route-line' ||
           id === 'alternate-route-hit' ||
           id === 'nlsc-doorplate-overlay' ||
           id === 'nlsc-detail-raster' ||
           id.startsWith('main-community-') ||
           id.startsWith('main-place-') ||
           id.startsWith('main-entrance-') ||
           id.startsWith('main-destination-');
  }

  // Independent native house labels use fixed geographic anchors; original raster stays at close zoom.
  // NLSC baked-in roads/places/doorplates appear ONLY at very close zoom.
  // Sparse structured data is never advertised as complete NLSC coverage.
  function ensureMainDoorplateOverlay() {
    const houseSourceId='main-house-numbers';
    if(!map.getSource(houseSourceId)) map.addSource(houseSourceId,{type:'geojson',data:emptyFeatureCollection()});
    if(!map.getLayer('nlsc-doorplate-overlay')) map.addLayer({
      id:'nlsc-doorplate-overlay',type:'symbol',source:houseSourceId,minzoom:19,maxzoom:24,
      layout:{'text-field':['get','label'],'text-font':['Noto Sans Regular'],
        'text-size':['interpolate',['linear'],['zoom'],19,12,21,14],
        'text-allow-overlap':false,'text-ignore-placement':false,
        'text-rotation-alignment':'viewport','text-pitch-alignment':'viewport',
        'text-padding':5,'symbol-sort-key':['get','distance'],'visibility':'none'},
      paint:{'text-color':state.theme==='dark'?'#ecedf0':'#303944',
        'text-halo-color':state.theme==='dark'?'#222a34':'#f6f8fa','text-halo-width':1.4}
    });

    const rasterSourceId='nlsc-detail-raster-source';
    if(!map.getSource(rasterSourceId)) map.addSource(rasterSourceId,{
      type:'raster',
      tiles:['https://wmts.nlsc.gov.tw/wmts/EMAP2/default/GoogleMapsCompatible/{z}/{y}/{x}'],
      tileSize:256,maxzoom:19,
      attribution:'國土測繪中心 NLSC'
    });
    if(!map.getLayer('nlsc-detail-raster')) map.addLayer({
      id:'nlsc-detail-raster',type:'raster',source:rasterSourceId,minzoom:NLSC_DOORPLATE_MIN_ZOOM,maxzoom:24,
      layout:{visibility:'none'},
      paint:nlscDetailPaint(state.theme)
    });

    ensureOneWayArrows();
    scheduleCleanMapDetails();
    updateNlscDetailOverlayVisibility();
  }

  function nlscDetailPaint(theme) {
    const dark=theme==='dark';
    return {'raster-saturation':-1,'raster-brightness-min':0,
      'raster-brightness-max':dark?.76:.88,'raster-contrast':0,
      'raster-opacity':.88,
      'raster-fade-duration':0};
  }

  function applyNlscDetailTheme() {
    if(!map.getLayer('nlsc-detail-raster'))return;
    const paint=nlscDetailPaint(state.theme);
    // A theme change can happen with other sources still busy. Existing layer paint is safe.
    for(const [key,value] of Object.entries(paint)) {
      try {if(JSON.stringify(map.getPaintProperty('nlsc-detail-raster',key))!==JSON.stringify(value))
        map.setPaintProperty('nlsc-detail-raster',key,value);}catch(_){}
    }
  }

  function nlscDetailShouldShow() {
    const zoom=map?.getZoom?.();
    return Number.isFinite(zoom) && zoom>=NLSC_DOORPLATE_MIN_ZOOM;
  }

  function updateNlscDetailOverlayVisibility() {
    if(!map)return;
    // v0.3.66: the custom native house layer owns door numbers while riding.
    // Keep the baked NLSC close-up raster only as a manual-browse fallback;
    // otherwise it duplicates our labels and becomes visually noisy in 3D.
    const riding=!!(state.navigationActive||state.navigationRequested||state.fitLocked);
    const show=nlscDetailShouldShow()&&!riding;
    // Do not wait for every tile/source: clear/reveal existing layers immediately.
    try {
      if(map.getLayer('nlsc-detail-raster') &&
         map.getLayoutProperty('nlsc-detail-raster','visibility')!==(show?'visible':'none'))
        map.setLayoutProperty('nlsc-detail-raster','visibility',show?'visible':'none');
      // Sparse labels are not a substitute for the official raster and would duplicate it.
      if(map.getLayer('nlsc-doorplate-overlay') &&
         map.getLayoutProperty('nlsc-doorplate-overlay','visibility')!=='none')
        map.setLayoutProperty('nlsc-doorplate-overlay','visibility','none');
    } catch(_) { /* The normal main-scene style/load resync will restore current state. */ }
  }

  const baseHouseNumberVisibility=new Map();
  function isBaseHouseNumberLayer(layer) {
    if(!layer||layer.type!=='symbol'||isOperationalLayerId(String(layer.id||'')))return false;
    const id=String(layer.id||'').toLowerCase(),sl=String(layer['source-layer']||'').toLowerCase();
    const key=`${id} ${sl}`;
    return /housenumber|house[_ -]?number|addr[:_ -]?housenumber/.test(key);
  }
  function syncOriginalHouseNumberVisibility() {
    if(!map?.isStyleLoaded?.())return;
    const hide=!!(state.navigationActive||state.navigationRequested||state.fitLocked);
    for(const layer of map.getStyle()?.layers||[]) {
      if(!isBaseHouseNumberLayer(layer))continue;
      const id=layer.id;
      if(!baseHouseNumberVisibility.has(id)) {
        let original='visible';try{original=map.getLayoutProperty(id,'visibility')||'visible';}catch(_){}
        baseHouseNumberVisibility.set(id,original);
      }
      const wanted=hide?'none':baseHouseNumberVisibility.get(id);
      try{if(map.getLayoutProperty(id,'visibility')!==wanted)map.setLayoutProperty(id,'visibility',wanted);}catch(_){}
    }
    updateNlscDetailOverlayVisibility();
  }

  function houseNumberFeatures(addresses,center) {
    const seen=new Set(),features=[];
    for(const a of addresses||[]) {
      const lat=Number(a.lat),lng=Number(a.lng),num=String(a.houseNumber||'').trim();
      if(!offlineValidTaiwanPoint(lat,lng) || !num) continue;
      const key=`${num}:${lat.toFixed(5)},${lng.toFixed(5)}`;
      if(seen.has(key))continue;seen.add(key);
      const d=haversineMeters(center,{lat,lng});
      if(d>500)continue;
      features.push({type:'Feature',geometry:{type:'Point',coordinates:[lng,lat]},
        properties:{label:/號$/.test(num)?num:`${num}號`,distance:Math.round(d),source:a.source||'known-address'}});
    }
    features.sort((a,b)=>a.properties.distance-b.properties.distance);
    return {type:'FeatureCollection',features:features.slice(0,250)};
  }

  function makeOneWayImage() {
    const canvas=document.createElement('canvas');canvas.width=32;canvas.height=24;
    const ctx=canvas.getContext('2d');
    // Draw rightwards; MapLibre line placement rotates it along the encoded road.
    ctx.lineCap='round';ctx.lineJoin='round';
    const draw=()=>{ctx.beginPath();ctx.moveTo(6,12);ctx.lineTo(26,12);ctx.moveTo(19,5);ctx.lineTo(26,12);ctx.lineTo(19,19);ctx.stroke();};
    ctx.strokeStyle='#273442';ctx.lineWidth=6;draw();ctx.strokeStyle='#c1cfde';ctx.lineWidth=3;draw();
    return ctx.getImageData(0,0,32,24);
  }

  function ensureOneWayArrows() {
    if(!map.hasImage('door-oneway-arrow'))map.addImage('door-oneway-arrow',makeOneWayImage(),{pixelRatio:2});
    const layout={'symbol-placement':'line','symbol-spacing':130,'icon-image':'door-oneway-arrow',
      'icon-size':1,'icon-rotation-alignment':'map','icon-pitch-alignment':'map','icon-keep-upright':false,
      'icon-allow-overlap':false,'icon-ignore-placement':false};
    // Only an explicit one-way tag is evidence; never infer from road width/arrows in a raster.
    const transport=(map.getStyle()?.layers||[]).find(l=>l['source-layer']==='transportation' && l.source);
    if(transport && !map.getLayer('main-oneway-vector')) map.addLayer({
      id:'main-oneway-vector',type:'symbol',source:transport.source,'source-layer':'transportation',minzoom:15,
      filter:['in',['to-string',['get','oneway']],['literal',['1','-1','yes','true']]],
      layout:{...layout,'icon-rotate':['case',['==',['to-string',['get','oneway']],'-1'],180,0]},
      paint:{'icon-opacity':.82}
    });
    if(!map.getSource('main-oneway-offline'))map.addSource('main-oneway-offline',{type:'geojson',data:emptyFeatureCollection()});
    if(!map.getLayer('main-oneway-offline'))map.addLayer({id:'main-oneway-offline',type:'symbol',
      source:'main-oneway-offline',minzoom:15,layout,paint:{'icon-opacity':.82}});
    // No duplicate vector/offline arrows: prefer the vector tile source when present.
    if(map.getLayoutProperty('main-oneway-offline','visibility')!==(transport?'none':'visible'))map.setLayoutProperty('main-oneway-offline','visibility',transport?'none':'visible');
  }

  function offlineOneWayFeatures(elements,center) {
    const nodes=new Map((elements||[]).filter(e=>e.type==='node').map(e=>[e.id,[e.lon,e.lat]]));
    const features=[];
    for(const way of elements||[]) {
      if(way.type!=='way' || !way.tags?.highway)continue;
      const tag=String(way.tags.oneway||'').toLowerCase();
      const direction=['yes','1','true'].includes(tag)?1:tag==='-1'?-1:0;
      if(!direction)continue;
      let coords=Array.isArray(way.geometry)?way.geometry.map(p=>[Number(p.lon),Number(p.lat)]):(way.nodes||[]).map(n=>nodes.get(n));
      // Never connect across missing nodes — that would invent an oneway road.
      if(coords.length<2 || coords.some(p=>!p || !offlineValidTaiwanPoint(p[1],p[0])))continue;
      if(!coords.some(p=>haversineMeters(center,{lat:p[1],lng:p[0]})<650))continue;
      if(direction<0)coords=coords.slice().reverse();
      features.push({type:'Feature',geometry:{type:'LineString',coordinates:coords},properties:{source:'OSM explicit oneway',id:way.id}});
      if(features.length>=160)break;
    }
    return {type:'FeatureCollection',features};
  }

  function scheduleCleanMapDetails() {
    // Native vector arrows and native house labels already own these visible layers.
    if(document.hidden||map.getLayer('main-oneway-vector'))return;
    if(state.cleanDetailTimer)clearTimeout(state.cleanDetailTimer);
    state.cleanDetailTimer=setTimeout(()=>{state.cleanDetailTimer=null;refreshCleanMapDetails().catch(e=>console.warn('map detail',e));},240);
  }

  async function refreshCleanMapDetails() {
    if(document.hidden||!map.isStyleLoaded() || map.getZoom()<15||map.getLayer('main-oneway-vector'))return;
    const center=map.getCenter(),now=Date.now();
    if(state.cleanDetailCenter && haversineMeters(center,state.cleanDetailCenter)<65 && now-state.cleanDetailAt<5000)return;
    state.cleanDetailCenter={lat:center.lat,lng:center.lng};state.cleanDetailAt=now;
    const seq=++state.cleanDetailSeq;
    const [rows,roads]=await Promise.all([
      [], // medium-zoom address reads are owned by MapExtras; no duplicate database/network job
      map.getLayer('main-oneway-vector')?Promise.resolve({elements:[]}):offlineElementsForRoute([[center.lng,center.lat]],500).catch(()=>({elements:[]}))
    ]);
    if(seq!==state.cleanDetailSeq)return;
    const data=houseNumberFeatures([...rows,...state.cleanAddressCandidates],center);
    state.cleanAddressCount=data.features.length;
    map.getSource('main-house-numbers')?.setData(data);
    map.getSource('main-oneway-offline')?.setData(offlineOneWayFeatures(roads.elements,center));
  }

  function bringOperationalLayersToFront() {
    const ids = [
      'nlsc-detail-raster',
      'main-community-fill',
      'main-community-outline',
      'main-place-fill',
      'main-place-outline',
      'main-community-label-macro',
      'main-community-label-detail',
      'main-place-label-macro',
      'main-place-label-detail',
      'main-community-label-hit',
      'main-place-label-hit',
      'main-entrance-circles',
      'main-entrance-labels',
      'dest-guide-line',
      'alternate-route-line',
      'alternate-route-hit',
      'reference-route-casing',
      'reference-route-line',
      'main-oneway-vector',
      'main-oneway-offline',
      'main-destination-pin-symbol'
    ];
    for (const id of ids) {
      if (map.getLayer(id)) {
        try { map.moveLayer(id);globalThis.DoorPowerDiag?.mark?.('layerMove'); } catch (_) {}
      }
    }
    buildings3d?.order();
    mapExtras?.order();
    for(const id of ['planner-points-dot','planner-points-label'])if(map.getLayer(id)){try{map.moveLayer(id);}catch(_){}}
  }

  function applyChineseRoadLabels() {
    if (!map?.isStyleLoaded?.()) return;
    const zhName = ['coalesce',
      ['get','name:zh-Hant'],
      ['get','name:zh'],
      ['get','name:nonlatin'],
      ['get','name']
    ];
    for (const layer of map.getStyle()?.layers || []) {
      if (layer.type !== 'symbol') continue;
      const id=String(layer.id || '').toLowerCase();
      const sl=String(layer['source-layer'] || '').toLowerCase();
      const key=`${id} ${sl}`;
      if (!/(transportation_name|road.*name|street.*name|highway.*name|road_label|street_label)/.test(key)) continue;
      if (/(shield|route[_ -]?number|ref)/.test(id)) continue;
      try {
        const field=map.getLayoutProperty(layer.id,'text-field');
        if (field !== undefined) map.setLayoutProperty(layer.id,'text-field',zhName);
      } catch (_) {}
    }
  }

  function applyMainThemePaint(theme) {
    if (!map?.isStyleLoaded?.()) return;
    const dark = theme === 'dark';
    const palette = dark ? {
      bg:'#222a34',
      land:'#252e39',
      landAlt:'#293440',
      building:'#303945',
      water:'#1e2a36',
      road:'#343d49',
      otherLine:'#394550',
      text:'#adb6c2',
      halo:'#202832'
    } : {
      bg:'#edf0f3',
      land:'#f0f1ef',
      landAlt:'#e6ebe4',
      building:'#dfe2e4',
      water:'#d6e9f6',
      road:'#aeb5bd',
      otherLine:'#c1c6cb',
      text:'#343a40',
      halo:'#f8fafc'
    };

    for (const layer of map.getStyle()?.layers || []) {
      if (isOperationalLayerId(layer.id)) continue;
      const id = String(layer.id || '').toLowerCase();
      const sl = String(layer['source-layer'] || '').toLowerCase();
      const key = `${id} ${sl}`;
      try {
        if (layer.type === 'background') {
          map.setPaintProperty(layer.id,'background-color',palette.bg);
        } else if (layer.type === 'fill') {
          let color = palette.land;
          if (/water|river|lake|ocean/.test(key)) color = palette.water;
          else if (/building/.test(key)) color = palette.building;
          else if (/park|landuse|landcover|wood|grass|cemetery|pitch|school|hospital/.test(key)) color = palette.landAlt;
          map.setPaintProperty(layer.id,'fill-color',color);
          map.setPaintProperty(layer.id,'fill-opacity',dark ? 0.98 : 0.98);
          if (map.getPaintProperty(layer.id,'fill-outline-color') !== undefined) {
            map.setPaintProperty(layer.id,'fill-outline-color',dark ? '#35404b' : '#d1d5d9');
          }
        } else if (layer.type === 'fill-extrusion') {
          map.setPaintProperty(layer.id,'fill-extrusion-color',palette.building);
          map.setPaintProperty(layer.id,'fill-extrusion-opacity',dark ? 0.95 : 0.90);
        } else if (layer.type === 'line') {
          const isRoad = sl === 'transportation' ||
            /road|street|highway|motorway|trunk|primary|secondary|tertiary|bridge|tunnel|transport/.test(key);
          const isWater = /water|river|stream/.test(key);
          map.setPaintProperty(layer.id,'line-color',isRoad ? palette.road : (isWater ? palette.water : palette.otherLine));
          if (isRoad) map.setPaintProperty(layer.id,'line-opacity',0.96);
        } else if (layer.type === 'symbol') {
          if ((layer.layout && layer.layout['text-field'] !== undefined) ||
              map.getPaintProperty(layer.id,'text-color') !== undefined) {
            map.setPaintProperty(layer.id,'text-color',palette.text);
            map.setPaintProperty(layer.id,'text-halo-color',palette.halo);
            map.setPaintProperty(layer.id,'text-halo-width',dark ? 1.3 : 1.1);
          }
          if (/(transportation_name|road.*name|street.*name|road_label)/.test(key)) {
            map.setPaintProperty(layer.id,'text-opacity',.8);
          }
          if (/poi|housenumber|shop|amenity/.test(key)) {
            try { map.setPaintProperty(layer.id,'icon-opacity',dark ? 0.42 : 0.55); } catch (_) {}
          }
        }
      } catch (_) {}
    }
    applyChineseRoadLabels();
    updateOverlayTheme();
  }

  function updateOverlayTheme() {
    buildings3d?.setTheme(state.theme);
    mapExtras?.setTheme(state.theme);
    applyNlscDetailTheme();
    const dark = state.theme === 'dark';
    if(map.getLayer('nlsc-doorplate-overlay')) {
      map.setPaintProperty('nlsc-doorplate-overlay','text-color',dark?'#ecedf0':'#303944');
      map.setPaintProperty('nlsc-doorplate-overlay','text-halo-color',dark?'#222a34':'#f6f8fa');
    }
    const labelColor = dark ? '#c5b8ff' : '#5530c9';
    const labelHalo = dark ? '#11151a' : 'rgba(255,255,255,.98)';
    for (const id of ['main-community-label-hit','main-community-label-macro','main-community-label-detail']) {
      if (map.getLayer(id)) {
        try {
          map.setPaintProperty(id,'text-color',labelColor);
          map.setPaintProperty(id,'text-halo-color',labelHalo);
        } catch (_) {}
      }
    }
    if (map.getLayer('reference-route-casing')) {
      try { map.setPaintProperty('reference-route-casing','line-color',dark ? '#156DFF' : '#124DBA'); } catch (_) {}
    }
    if (map.getLayer('reference-route-line')) {
      try { map.setPaintProperty('reference-route-line','line-color',dark ? '#39D2FF' : '#148FFF'); } catch (_) {}
    }
    if (map.getLayer('alternate-route-line')) {
      try { map.setPaintProperty('alternate-route-line','line-color',dark ? '#91B5D9' : '#7499C7'); } catch (_) {}
    }
    for (const id of ['main-place-label-hit','main-place-label-macro','main-place-label-detail']) {
      if (map.getLayer(id)) {
        try { map.setPaintProperty(id,'text-halo-color',dark ? 'rgba(12,16,22,.94)' : 'rgba(255,255,255,.96)'); } catch (_) {}
      }
    }
    if (map.getLayer('main-destination-pin-symbol')) {
      try {
        map.setPaintProperty('main-destination-pin-symbol','text-color',dark ? '#ffffff' : '#26313d');
        map.setPaintProperty('main-destination-pin-symbol','text-halo-color',dark ? 'rgba(20,25,32,.94)' : 'rgba(255,255,255,.96)');
      } catch (_) {}
    }
  }

  function setTheme(theme, {persist=true}={}) {
    state.theme = theme === 'light' ? 'light' : 'dark';
    document.body.dataset.theme = state.theme;
    if (persist){localStorage.setItem('581-door-theme', state.theme);window.webkit.messageHandlers.appleMapEngine.postMessage({type:'themeSelection',payload:{theme:state.theme}});}

    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute(
      'content',
      state.theme === 'dark' ? '#343a43' : '#eef1f4'
    );

    if (els.themeBtn) {
      els.themeBtn.querySelector('.more-icon').textContent = state.theme === 'dark' ? '☾' : '☀';
      els.themeBtn.classList.toggle('active', state.theme === 'dark');
    }

    // Paint-only theme switching. Custom sources/layers stay alive.
    applyMainThemePaint(state.theme);
    updateOverlayTheme();
    scheduleMainSceneSync('theme-paint', 0);
  }

  function entranceDisplayLabel(item) {
    if (item.category === 'residential') return '社區入口';
    if (item.feature === 'marketplace') return '市場入口';
    if (item.category === 'commercial') return item.feature === 'mall' || item.feature === 'department_store' ? '商場入口' : '店家入口';
    if (item.category === 'business') return '營業入口';
    if (item.category === 'public') return '公共入口';
    return item.kind === 'gate' ? '大門' : '入口';
  }

  function entranceGeoJson(items) {
    return {
      type:'FeatureCollection',
      features:(items || []).map(item => ({
        type:'Feature',
        properties:{
          kind:item.kind,
          label:entranceDisplayLabel(item),
          category:item.category || 'unknown',
          feature:item.feature || '',
          placeName:item.placeName || item.communityName || '',
          targetPlace:item.targetPlace || item.targetCommunity ? 1 : 0
        },
        geometry:{ type:'Point', coordinates:[item.lng,item.lat] }
      }))
    };
  }

  function ensureEntranceLayers(targetMap, prefix, isInset=false) {
    const sourceId = `${prefix}-entrances`;
    if (!targetMap.getSource(sourceId)) {
      targetMap.addSource(sourceId,{type:'geojson',data:state.entranceData || emptyFeatureCollection()});
    }
    const colorExpr=['match',['get','category'],
      'residential','#7659dc',
      'commercial','#f0a13a',
      'business','#4d9ada',
      'public','#43ad77',
      '#8e99a8'
    ];
    if (!targetMap.getLayer(`${prefix}-entrance-circles`)) {
      targetMap.addLayer({
        id:`${prefix}-entrance-circles`, type:'circle', source:sourceId,
        paint:{
          'circle-radius':['case',['==',['get','targetPlace'],1],isInset?6:8,isInset?4.5:6],
          'circle-color':colorExpr,
          'circle-stroke-color':'#ffffff',
          'circle-stroke-width':['case',['==',['get','targetPlace'],1],2.5,1.5],
          'circle-opacity':0.96
        }
      });
    }
    if (!targetMap.getLayer(`${prefix}-entrance-labels`)) {
      targetMap.addLayer({
        id:`${prefix}-entrance-labels`, type:'symbol', source:sourceId,
        minzoom:isInset?0:14.5,
        layout:{
          'text-field':['case',['==',['get','targetPlace'],1],['concat','★ ',['get','label']],['get','label']],
          'text-font':['Noto Sans Regular'],
          'text-size':isInset?9:11,
          'text-offset':[0,1.15],
          'text-anchor':'top',
          'text-allow-overlap':true,
          'text-ignore-placement':true,
          'text-rotation-alignment':'viewport'
        },
        paint:{
          'text-color':'#ffffff',
          'text-halo-color':'rgba(10,14,18,.88)',
          'text-halo-width':1.5
        }
      });
    }
  }

  function makeTrafficSignalImage(kind='signal') {
    const c=document.createElement('canvas'); c.width=56; c.height=64;
    const x=c.getContext('2d'); if (!x) throw new Error('2D canvas unavailable');
    x.scale(2,2);

    if (kind === 'blinker') {
      x.fillStyle='rgba(22,25,30,.96)';
      x.beginPath(); x.roundRect(7,4,14,20,5); x.fill();
      x.lineWidth=1.2; x.strokeStyle='rgba(255,255,255,.88)'; x.stroke();
      x.beginPath(); x.arc(14,14,4.2,0,Math.PI*2); x.fillStyle='#ffc247'; x.fill();
      x.beginPath(); x.arc(14,14,6.2,0,Math.PI*2); x.strokeStyle='rgba(255,194,71,.45)'; x.lineWidth=1.4; x.stroke();
      return x.getImageData(0,0,c.width,c.height);
    }

    const heads = kind === 'complex' ? [4.5,15.5] : [9.8];
    for (const cx of heads) {
      x.fillStyle='rgba(22,25,30,.95)';
      x.beginPath(); x.roundRect(cx-5.5,1,11,26,4); x.fill();
      x.lineWidth=1.1; x.strokeStyle='rgba(255,255,255,.86)'; x.stroke();
      for (const [cy,color] of [[6,'#ff5b55'],[14,'#ffc247'],[22,'#48c774']]) {
        x.beginPath(); x.arc(cx,cy,2.75,0,Math.PI*2); x.fillStyle=color; x.fill();
      }
    }
    return x.getImageData(0,0,c.width,c.height);
  }

  function ensureRouteLayer() {
    if (!map.getSource('alternate-routes')) {
      map.addSource('alternate-routes',{type:'geojson',data:state.alternateRouteGeoJson || emptyFeatureCollection()});
    }
    if (!map.getLayer('alternate-route-line')) {
      map.addLayer({
        id:'alternate-route-line',type:'line',source:'alternate-routes',
        layout:{'line-join':'round','line-cap':'round'},
        paint:{
          'line-color':state.theme === 'dark' ? '#91B5D9' : '#7499C7',
          'line-width':['interpolate',['linear'],['zoom'],10,2,14,4,17,6],
          'line-opacity':0.43
        }
      });
    }
    if (!map.getLayer('alternate-route-hit')) {
      map.addLayer({
        id:'alternate-route-hit',type:'line',source:'alternate-routes',
        layout:{'line-join':'round','line-cap':'round'},
        paint:{'line-color':'#ffffff','line-width':18,'line-opacity':0}
      });
    }

    if (!map.getSource('reference-route')) {
      map.addSource('reference-route',{
        type:'geojson',
        data:state.routeDisplayGeoJson || state.routeGeoJson || emptyFeatureCollection()
      });
    }
    if (!map.getLayer('reference-route-casing')) {
      map.addLayer({
        id:'reference-route-casing',
        type:'line',
        source:'reference-route',
        layout:{'line-join':'round','line-cap':'round'},
        paint:{
          'line-color':state.theme === 'dark' ? '#156DFF' : '#124DBA',
          'line-width':['interpolate',['linear'],['zoom'],10,6,14,8,17,10,20,12],
          'line-opacity':0.95
        }
      });
    }
    if (!map.getLayer('reference-route-line')) {
      map.addLayer({
        id:'reference-route-line',
        type:'line',
        source:'reference-route',
        layout:{'line-join':'round','line-cap':'round'},
        paint:{
          'line-color':state.theme === 'dark' ? '#39D2FF' : '#148FFF',
          'line-width':['interpolate',['linear'],['zoom'],10,4,14,5,17,6,20,8],
          'line-opacity':0.98
        }
      });
    }


  }

  let routeInteractionsBound=false;
  function bindRouteInteractions() {
    if (routeInteractionsBound || !map.getLayer('alternate-route-hit')) return;
    routeInteractionsBound=true;
    map.on('click','alternate-route-hit',e=>{
      if((typeof planner==='undefined'?null:planner)?.editing)return;
      if(Date.now()-state.deliveryLongPressAt<1200)return;
      const feature=e.features?.[0];
      const index=Number(feature?.properties?.altIndex);
      if (Number.isInteger(index)) promoteAlternateRoute(index);
    });
    map.on('mouseenter','alternate-route-hit',()=>{ map.getCanvas().style.cursor='pointer'; });
    map.on('mouseleave','alternate-route-hit',()=>{ map.getCanvas().style.cursor=''; });
  }

  function updateEntranceSources() {
    const a = map.getSource('main-entrances');
    const b = inset.getSource('inset-entrances');
    if (a) submitSceneData(map,'main-entrances',state.entranceData || emptyFeatureCollection());
    if (b) submitSceneData(inset,'inset-entrances',state.entranceData || emptyFeatureCollection());
  }

  function setRouteStatus(text, kind='') {
    if (!els.routeStatus) return;
    els.routeStatus.textContent = text;
    els.routeStatus.className = `route-status ${kind}`.trim();
  }

  function emptyCommunityGeo() {
    return { type:'FeatureCollection', features:[] };
  }

  function ensureCommunityLayers(targetMap, prefix, isInset=false) {
    const areaSourceId = `${prefix}-community-areas`;
    const labelSourceId = `${prefix}-community-labels`;

    if (!targetMap.getSource(areaSourceId)) {
      targetMap.addSource(areaSourceId, {
        type:'geojson',
        data: state.communityData || emptyCommunityGeo()
      });
    }

    if (!targetMap.getLayer(`${prefix}-community-fill`)) {
      targetMap.addLayer({
        id:`${prefix}-community-fill`,
        type:'fill',
        source:areaSourceId,
        paint:{
          'fill-color':[
            'case',
            ['==',['get','containsDestination'],1],
            '#7b4dff',
            '#6c55d8'
          ],
          'fill-opacity':[
            'case',
            ['==',['get','containsDestination'],1],
            isInset ? 0.26 : 0.22,
            isInset ? 0.16 : 0.12
          ]
        }
      });
    }

    if (!targetMap.getLayer(`${prefix}-community-outline`)) {
      targetMap.addLayer({
        id:`${prefix}-community-outline`,
        type:'line',
        source:areaSourceId,
        paint:{
          'line-color':[
            'case',
            ['==',['get','containsDestination'],1],
            '#6b36ff',
            '#715fd5'
          ],
          'line-opacity':0.92,
          'line-width':[
            'case',
            ['==',['get','containsDestination'],1],
            isInset ? 3 : 4,
            isInset ? 2 : 2.5
          ]
        }
      });
    }

    if (!targetMap.getSource(labelSourceId)) {
      targetMap.addSource(labelSourceId, {
        type:'geojson',
        data: state.communityLabelData || emptyFeatureCollection()
      });
    }

    // Destination-containing community: always visible and always wins collisions.
    if (!targetMap.getLayer(`${prefix}-community-label-hit`)) {
      targetMap.addLayer({
        id:`${prefix}-community-label-hit`,
        type:'symbol',
        source:labelSourceId,
        filter:['==',['get','containsDestination'],1],
        layout:{
          'text-field':['concat','★ ',['get','name']],
          'text-font':['Noto Sans Regular'],
          'text-size':isInset ? 10 : 13,
          'text-anchor':'center',
          'text-allow-overlap':true,
          'text-ignore-placement':true,
          'text-rotation-alignment':'viewport',
          'symbol-sort-key':0
        },
        paint:{
          'text-color':'#5530c9',
          'text-halo-color':'rgba(255,255,255,.98)',
          'text-halo-width':2,
          'text-halo-blur':0.5
        }
      });
    }

    // Macro overview: only the nearest few names, anchored to their real polygon interior.
    if (!isInset && !targetMap.getLayer(`${prefix}-community-label-macro`)) {
      targetMap.addLayer({
        id:`${prefix}-community-label-macro`,
        type:'symbol',
        source:labelSourceId,
        maxzoom:15.3,
        filter:[
          'all',
          ['==',['get','containsDestination'],0],
          ['==',['get','macroVisible'],1]
        ],
        layout:{
          'text-field':['get','name'],
          'text-font':['Noto Sans Regular'],
          'text-size':12,
          'text-anchor':'center',
          'text-allow-overlap':false,
          'text-ignore-placement':false,
          'text-rotation-alignment':'viewport',
          'symbol-sort-key':['get','rank']
        },
        paint:{
          'text-color':'#593cc1',
          'text-halo-color':'rgba(255,255,255,.96)',
          'text-halo-width':2,
          'text-halo-blur':0.5
        }
      });
    }

    // Street/detail view (and the fixed z18 inset): show all returned names.
    if (!targetMap.getLayer(`${prefix}-community-label-detail`)) {
      targetMap.addLayer({
        id:`${prefix}-community-label-detail`,
        type:'symbol',
        source:labelSourceId,
        minzoom:isInset ? 0 : 15.3,
        filter:['==',['get','containsDestination'],0],
        layout:{
          'text-field':['get','name'],
          'text-font':['Noto Sans Regular'],
          'text-size':isInset ? 9 : 12,
          'text-anchor':'center',
          'text-allow-overlap':false,
          'text-ignore-placement':false,
          'text-rotation-alignment':'viewport',
          'symbol-sort-key':['get','rank']
        },
        paint:{
          'text-color':'#6242c8',
          'text-halo-color':'rgba(255,255,255,.96)',
          'text-halo-width':isInset ? 1.3 : 2,
          'text-halo-blur':0.4
        }
      });
    }
  }

  function placeColorExpression(defaultColor='#4b8fd6') {
    return ['match',['get','category'],
      'commercial','#f0a13a',
      'business','#4d9ada',
      'public','#43ad77',
      'residential','#7659dc',
      defaultColor
    ];
  }

  function placeLabelGeoJson(items) {
    return {
      type:'FeatureCollection',
      features:(items || []).filter(item => item.hasGeometry || item.containsDestination || item.distance <= 35).map((item,index) => ({
        type:'Feature',
        properties:{
          name:item.name,
          category:item.category || 'business',
          feature:item.feature || '',
          containsDestination:item.containsDestination ? 1 : 0,
          rank:index,
          macroVisible:index < 5 ? 1 : 0
        },
        geometry:{
          type:'Point',
          coordinates:[
            Number.isFinite(item.labelLng) ? item.labelLng : item.lng,
            Number.isFinite(item.labelLat) ? item.labelLat : item.lat
          ]
        }
      }))
    };
  }

  function placeGeoJson(items) {
    const features=[];
    for (const item of items || []) {
      for (const shape of item.shapes || []) {
        const properties={
          name:item.name,
          category:item.category || 'business',
          feature:item.feature || '',
          containsDestination:item.containsDestination ? 1 : 0
        };
        if (shape.type === 'Polygon') {
          const ring=[...shape.coords];
          if (!coordsEqual(ring[0],ring[ring.length-1])) ring.push([...ring[0]]);
          features.push({type:'Feature',properties,geometry:{type:'Polygon',coordinates:[ring]}});
        } else if (shape.type === 'LineString') {
          features.push({type:'Feature',properties,geometry:{type:'LineString',coordinates:shape.coords}});
        }
      }
    }
    return {type:'FeatureCollection',features};
  }

  function ensurePlaceLayers(targetMap,prefix,isInset=false) {
    const areaSourceId=`${prefix}-place-areas`;
    const labelSourceId=`${prefix}-place-labels`;
    if (!targetMap.getSource(areaSourceId)) {
      targetMap.addSource(areaSourceId,{type:'geojson',data:state.placeData || emptyFeatureCollection()});
    }
    if (!targetMap.getLayer(`${prefix}-place-fill`)) {
      targetMap.addLayer({
        id:`${prefix}-place-fill`,type:'fill',source:areaSourceId,
        paint:{
          'fill-color':placeColorExpression(),
          'fill-opacity':['case',['==',['get','containsDestination'],1],isInset?0.26:0.22,isInset?0.13:0.10]
        }
      });
    }
    if (!targetMap.getLayer(`${prefix}-place-outline`)) {
      targetMap.addLayer({
        id:`${prefix}-place-outline`,type:'line',source:areaSourceId,
        paint:{
          'line-color':placeColorExpression(),
          'line-opacity':0.94,
          'line-width':['case',['==',['get','containsDestination'],1],isInset?3:4,isInset?1.8:2.3]
        }
      });
    }
    if (!targetMap.getSource(labelSourceId)) {
      targetMap.addSource(labelSourceId,{type:'geojson',data:state.placeLabelData || emptyFeatureCollection()});
    }
    const commonLayout={
      'text-font':['Noto Sans Regular'],
      'text-anchor':'center',
      'text-rotation-alignment':'viewport'
    };
    if (!targetMap.getLayer(`${prefix}-place-label-hit`)) {
      targetMap.addLayer({
        id:`${prefix}-place-label-hit`,type:'symbol',source:labelSourceId,
        filter:['==',['get','containsDestination'],1],
        layout:{...commonLayout,'text-field':['concat','★ ',['get','name']],'text-size':isInset?10:13,'text-allow-overlap':true,'text-ignore-placement':true},
        paint:{'text-color':placeColorExpression('#ffffff'),'text-halo-color':state.theme==='dark'?'rgba(12,16,22,.96)':'rgba(255,255,255,.98)','text-halo-width':2,'text-halo-blur':0.4}
      });
    }
    if (!isInset && !targetMap.getLayer(`${prefix}-place-label-macro`)) {
      targetMap.addLayer({
        id:`${prefix}-place-label-macro`,type:'symbol',source:labelSourceId,maxzoom:15.3,
        filter:['all',['==',['get','containsDestination'],0],['==',['get','macroVisible'],1]],
        layout:{...commonLayout,'text-field':['get','name'],'text-size':11.5,'text-allow-overlap':false,'text-ignore-placement':false,'symbol-sort-key':['get','rank']},
        paint:{'text-color':placeColorExpression('#d8e7ff'),'text-halo-color':state.theme==='dark'?'rgba(12,16,22,.94)':'rgba(255,255,255,.96)','text-halo-width':2}
      });
    }
    if (!targetMap.getLayer(`${prefix}-place-label-detail`)) {
      targetMap.addLayer({
        id:`${prefix}-place-label-detail`,type:'symbol',source:labelSourceId,minzoom:isInset?0:15.3,
        filter:['==',['get','containsDestination'],0],
        layout:{...commonLayout,'text-field':['get','name'],'text-size':isInset?9:11.5,'text-allow-overlap':false,'text-ignore-placement':false,'symbol-sort-key':['get','rank']},
        paint:{'text-color':placeColorExpression('#d8e7ff'),'text-halo-color':state.theme==='dark'?'rgba(12,16,22,.94)':'rgba(255,255,255,.96)','text-halo-width':isInset?1.3:2}
      });
    }
  }

  function updatePlaceSources() {
    const a=map.getSource('main-place-areas');
    const b=inset.getSource('inset-place-areas');
    const c=map.getSource('main-place-labels');
    const d=inset.getSource('inset-place-labels');
    if (a) submitSceneData(map,'main-place-areas',state.placeData || emptyFeatureCollection());
    if (b) submitSceneData(inset,'inset-place-areas',state.placeData || emptyFeatureCollection());
    if (c) submitSceneData(map,'main-place-labels',state.placeLabelData || emptyFeatureCollection());
    if (d) submitSceneData(inset,'inset-place-labels',state.placeLabelData || emptyFeatureCollection());
  }

  function updateCommunitySources() {
    const areaData = state.communityData || emptyCommunityGeo();
    const labelData = state.communityLabelData || emptyFeatureCollection();

    const a = map.getSource('main-community-areas');
    const b = inset.getSource('inset-community-areas');
    const c = map.getSource('main-community-labels');
    const d = inset.getSource('inset-community-labels');

    if (a) submitSceneData(map,'main-community-areas',areaData);
    if (b) submitSceneData(inset,'inset-community-areas',areaData);
    if (c) submitSceneData(map,'main-community-labels',labelData);
    if (d) submitSceneData(inset,'inset-community-labels',labelData);
    updatePlaceSources();
    updateEntranceSources();
  }

  function setMainSceneStatus(text, kind='') {
    if (!els.mainSceneStatus) return;
    els.mainSceneStatus.textContent = text;
    els.mainSceneStatus.className = `scene-status ${kind}`.trim();
  }

  function safeSceneStep(name, fn) {
    try {
      fn();
      return true;
    } catch (err) {
      console.warn(`main scene step failed: ${name}`, err);
      return false;
    }
  }

  function mainSceneHealth() {
    const pin = !!map.getLayer('main-destination-pin-symbol');
    const community = !!map.getSource('main-community-areas');
    const place = !!map.getSource('main-place-areas');
    const entrance = !!map.getSource('main-entrances') && !!map.getLayer('main-entrance-circles');
    const route = !!map.getLayer('reference-route-line');
    const doorplate = !!map.getLayer('nlsc-doorplate-overlay');
    return { pin, community, place, entrance, route, doorplate };
  }

  function scheduleMainSceneSync(reason='sync', delay=0) {
    state.mainScenePendingReason = reason;
    if(document.hidden){clearTimeout(state.mainSceneSyncTimer);state.mainSceneSyncTimer=null;return;}
    if (state.mainSceneSyncTimer) clearTimeout(state.mainSceneSyncTimer);

    state.mainSceneSyncTimer = setTimeout(() => {
      state.mainSceneSyncTimer = null;

      if (!map?.isStyleLoaded?.()) {
        setMainSceneStatus('主圖：等待底圖', 'syncing');
        scheduleMainSceneSync(reason, 120);
        return;
      }

      const pending = state.mainScenePendingReason || reason;
      const ok = syncMainScene({reason:pending});
      if (!ok) {
        scheduleMainSceneSync(`${pending}-retry`, 80);
      }
    }, Math.max(0,delay));
  }

  function syncMainScene({reason='sync'}={}) {
    if(document.hidden)return false;
    buildings3d?.sync();
    if (!map?.isStyleLoaded?.()) return false;
    if (state.mainSceneSyncing) return false;

    state.mainSceneSyncing = true;
    setMainSceneStatus(`主圖：同步 ${reason}`, 'syncing');
    let ok = true;
    try {
      ok = safeSceneStep('doorplate', ensureMainDoorplateOverlay) && ok;
      ok = safeSceneStep('community layers', () => ensureCommunityLayers(map,'main',false)) && ok;
      ok = safeSceneStep('place layers', () => ensurePlaceLayers(map,'main',false)) && ok;
      ok = safeSceneStep('entrance layers', () => ensureEntranceLayers(map,'main',false)) && ok;
      ok = safeSceneStep('route layers', ensureRouteLayer) && ok;
      safeSceneStep('route interactions', bindRouteInteractions);
      ok = safeSceneStep('destination pin layer', () => ensureNativeDestinationPin(map,'main',1)) && ok;

      safeSceneStep('community data', updateCommunitySources);
      safeSceneStep('destination data', () => updateNativeDestinationPin(map,'main',state.destination));
      safeSceneStep('route data', () => {
        submitSceneData(map,'reference-route',state.routeDisplayGeoJson || state.routeGeoJson || emptyFeatureCollection());
        map.getSource('alternate-routes')?.setData(state.alternateRouteGeoJson || emptyFeatureCollection());
          });
      safeSceneStep('accuracy', updateAccuracy);
      safeSceneStep('guide', updateGuideLine);
      safeSceneStep('layer order', bringOperationalLayersToFront);
      safeSceneStep('pin order', () => bringNativeDestinationPinToFront(map,'main'));
      safeSceneStep('theme overlay', updateOverlayTheme);
      safeSceneStep('delivery layers', syncDeliveryMap);
      safeSceneStep('adaptive 3D presentation', () => adaptiveScene?.sync());

      const h = mainSceneHealth();
      const requiredOk = h.pin && h.community && h.place && h.entrance && h.route && h.doorplate;
      setMainSceneStatus(
        `主圖 Pin${h.pin?'✓':'×'} 社區${h.community?'✓':'×'} 場所${h.place?'✓':'×'} 入口${h.entrance?'✓':'×'} 路線${h.route?'✓':'×'} 門牌${h.doorplate?'✓':'×'}`,
        requiredOk ? 'ok' : 'warn'
      );
      state.mainSceneLastSync = Date.now();
      return requiredOk && ok;
    } finally {
      state.mainSceneSyncing = false;
      if (state.mainScenePendingReason && state.mainScenePendingReason !== reason) {
        scheduleMainSceneSync(state.mainScenePendingReason, 0);
      }
    }
  }

  function syncInsetScene({recenter=false}={}) {
    if(document.hidden)return false;
    if (!inset?.isStyleLoaded?.()) return false;
    safeSceneStep('inset community', () => ensureCommunityLayers(inset,'inset',true));
    safeSceneStep('inset place', () => ensurePlaceLayers(inset,'inset',true));
    safeSceneStep('inset entrance', () => ensureEntranceLayers(inset,'inset',true));
    safeSceneStep('inset pin', () => ensureNativeDestinationPin(inset,'inset',0.78));
    safeSceneStep('inset data', updateCommunitySources);
    safeSceneStep('inset dest', () => updateNativeDestinationPin(inset,'inset',state.destination));
    safeSceneStep('inset pin order', () => bringNativeDestinationPinToFront(inset,'inset'));
    state.insetSceneReady = true;

    if (recenter && state.destination) {
      inset.resize();
      inset.jumpTo({
        center:[state.destination.lng,state.destination.lat],
        zoom:state.insetZoom,
        bearing:0,
        pitch:0
      });
    }
    return true;
  }


  // v0.3.34 FIT LOCK is an independent camera owner, not a routing dependency.
  // Coordinates/reroute continue even if camera fitting fails or is paused.
  function fitPipBottom(height,width=0) {
    // Explicit top-PiP preset, NOT detection of another app's OS window.
    // Screen origin includes the status area. Protect the bottom, not just height.
    const h=Math.max(0,Number(height)||0),w=Math.max(0,Number(width)||0);
    if(!state.pipView || !h)return 0;
    const topOffset=Math.min(h*.08,64);
    const portraitVideo=w>0&&w<=h?Math.max(0,w-20)*9/16:0;
    const pipHeight=Math.max(Math.min(h*.26,205),portraitVideo);
    return Math.min(h,topOffset+pipHeight+12);
  }

  function syncFitSafeTop() {
    // HUD stays at its ordinary top-left location, even behind native PiP.
    document.body.style.setProperty('--nav-safe-top','calc(var(--safe-top) + 12px)');
  }

  function fitViewport() {
    const rect=map.getContainer().getBoundingClientRect();
    const width=rect.width || map.getContainer().clientWidth || window.innerWidth;
    const height=rect.height || map.getContainer().clientHeight || window.innerHeight;
    const obstacles=[];
    const add=(element,margin=5)=>{
      if(!element || element.hidden || !element.getClientRects().length)return;
      const r=element.getBoundingClientRect();
      if(!r.width || !r.height)return;
      obstacles.push({left:r.left-rect.left-margin,right:r.right-rect.left+margin,
        top:r.top-rect.top-margin,bottom:r.bottom-rect.top+margin});
    };
    // Actual DOM footprints, NOT their full-width/full-height padding strips.
    if(!state.pipView)add(els.topHud);
    add(document.getElementById('insetCard'));add(document.getElementById('routeEditPanel'));
    add(document.getElementById('gogoroPanel'));
    for(const element of document.querySelectorAll('#controls > button'))add(element,4);
    add(els.creditsBtn,2);
    if(state.pipView)obstacles.push({left:0,right:width,top:0,bottom:fitPipBottom(height,width)});
    return {width,height,edge:12,obstacles};
  }

  function fitRouteInput() {
    // Never fall back to the full historical route after arrival emptied the display.
    return routeDisplayCoordinates().filter(p=>Array.isArray(p)&&p.every(Number.isFinite));
  }

  function syncFitUi() {
    const locked=!!state.fitLocked;
    els.overviewBtn.classList.toggle('fit-locked',locked);
    els.overviewBtn.setAttribute('aria-pressed',String(locked));
    els.overviewBtn.title=locked?'FIT 已鎖定；再按一次回到導航跟隨':'FIT 鎖定：剩餘路線自動放滿畫面';
    els.overviewBtn.setAttribute('aria-label',els.overviewBtn.title);
    const badge=els.overviewBtn.querySelector('.fit-state');
    if(badge)badge.textContent=locked?(state.fitRouteWaiting?'FIT 等路線':'FIT 已鎖'):'FIT';
    document.body.classList.toggle('fit-lock',locked);
    if(locked)els.modeText.textContent='FIT 鎖定 · 剩餘路線總覽';
  }

  function stopFitLock(reason='manual') {
    const was=state.fitLocked;
    state.fitLocked=false;state.fitGestureHold=false;state.fitGestureOrigin=null;
    state.fitNeedsRefresh=false;state.fitRouteWaiting=false;
    if(was) {map.stop();syncFitUi();}
    return was;
  }

  function setFitLock(on) {
    if(!on) {
      stopFitLock('toggle');
      setMode('heading');
      return;
    }
    if(!state.position || !state.destination || !state.routeEnabled || routeCoordinates().length<2) {
      toast('先設定目的地並取得路線，再按 FIT');return;
    }
    if(!window.DoorFitCamera) {toast('FIT 模組未載入；目的地與導航不受影響');return;}
    state.fitLocked=true;state.fitGestureHold=false;state.fitGestureOrigin=null;
    state.following=false;state.cameraUserOverride=false;state.autoFitRoutePending=false;
    state.fitLastEvalAt=-Infinity;state.fitLastPosition=null;state.fitLastPlan=null;
    state.fitNeedsRefresh=true;
    setHudCollapsed(true);setMoreOpen(false);
    syncFitSafeTop();
    syncCameraControls();syncFitUi();
    map.stop();map.resize();updateRouteProgressDisplay();
    updateFitCamera({force:true,full:true});
  }

  function updateFitCamera({force=false,full=false}={}) {
    if(state.cameraGestureHold)return;
    if(!state.fitLocked || document.hidden || !state.position || !state.destination || !state.routeEnabled)return;
    syncFitSafeTop();
    if(state.deliveryAwaitPick || state.fitGestureHold || els.destDialog.open || state.moreOpen || state.fitRouteWaiting ||
       !document.getElementById('routeEditPanel')?.hidden || (document.getElementById('gogoroPanel') && !document.getElementById('gogoroPanel').hidden) || document.getElementById('avoidAreaDialog')?.open || document.getElementById('avoidAreasDialog')?.open || document.getElementById('avoidAreaDetailDialog')?.open) {
      if(force)state.fitNeedsRefresh=true;return;
    }
    if(!window.DoorFitCamera)return;
    const now=performance.now();
    if(!force && now-state.fitLastEvalAt<1000)return;
    const viewport=fitViewport();
    const layoutKey=JSON.stringify(viewport);
    const newRoute=state.fitLastRoute!==state.routeGeoJson;
    const displayPoint=state.displayPosition||state.position;
    const moved=state.fitLastPosition?haversineMeters(state.fitLastPosition,displayPoint):Infinity;
    const changed=layoutKey!==state.fitLastLayout;
    const accuracy=Number(state.position.accuracy)||0;
    // Small stationary GPS jitter does not start a fit/animation. A real route/UI change still does.
    if(!force && !newRoute && !changed && !state.fitNeedsRefresh && moved<Math.max(5,Math.min(12,accuracy*.8)))return;
    if(!force && accuracy>70)return;
    state.fitLastEvalAt=now;
    const coords=fitRouteInput();
    const origin=[displayPoint.lng,displayPoint.lat],dest=[state.destination.lng,state.destination.lat];
    const remaining=currentRemainingMetrics()?.meters;
    const last=state.fitLastPlan;
    const movedFull=state.fitLastFullPosition?haversineMeters(state.fitLastFullPosition,displayPoint):Infinity;
    const searchAll=full||newRoute||changed||!last||(now-state.fitLastFullAt>=15000 && movedFull>=80);
    const started=performance.now();
    let plan;
    try {
      plan=window.DoorFitCamera.solve(coords,origin,dest,viewport,{
        // Keep macro FIT planar; close-up cap remains stable. NLSC display is now zoom-only.
        maxZoom:Number.isFinite(remaining)&&remaining<=150?20:18.85,
        previousBearing:last?.bearing ?? map.getBearing(),full:searchAll,continuous:!!last,riderAnchor:true,targetAbove:true
      });
      if(!plan && !searchAll)plan=window.DoorFitCamera.solve(coords,origin,dest,viewport,{
        maxZoom:Number.isFinite(remaining)&&remaining<=150?20:18.85,previousBearing:last?.bearing,
        full:true,continuous:!!last,riderAnchor:true,targetAbove:true});
      if(!plan)plan=window.DoorFitCamera.solve(coords,origin,dest,viewport,{
        maxZoom:Number.isFinite(remaining)&&remaining<=150?20:18.85,previousBearing:last?.bearing,
        full:true,continuous:!!last,riderAnchor:true,targetAbove:true,anchorBounds:{left:.35,right:.82,top:.58,bottom:.88}});
      // Large expanded panels can physically cover the entire lower band.
      // Visibility wins only when both lower-right and lower-band fits are impossible.
      if(!plan){plan=window.DoorFitCamera.solve(coords,origin,dest,viewport,{
        maxZoom:Number.isFinite(remaining)&&remaining<=150?20:18.85,previousBearing:last?.bearing,
        full:true,continuous:!!last,targetAbove:true});if(plan)plan.anchorFallback='lower-area-obstructed';}
      state.fitStats.evaluations++;
      state.fitStats.lastComputeMs=performance.now()-started;
      if(searchAll)state.fitStats.fullSearches++;
    } catch(err) {console.warn('FIT camera unavailable; navigation kept',err);return;}
    if(!plan) {state.fitNeedsRefresh=true;return;}
    const autoFitZoom=plan.zoom;
    const zoomOffset=Number(state.cameraZoomOffset)||0;
    if(Number.isFinite(autoFitZoom))plan.zoom=Math.max(12,Math.min(20.5,autoFitZoom+zoomOffset));
    state.fitLastPosition={lat:displayPoint.lat,lng:displayPoint.lng};
    state.fitLastRoute=state.routeGeoJson;state.fitLastLayout=layoutKey;state.fitNeedsRefresh=false;
    if(searchAll) {state.fitLastFullAt=now;state.fitLastFullPosition={...state.fitLastPosition};}
    const current={center:[map.getCenter().lng,map.getCenter().lat],zoom:map.getZoom(),bearing:map.getBearing(),pitch:map.getPitch()};
    const fitsNow=current.pitch===0 && window.DoorFitCamera.contains(current,coords,origin,dest,viewport);
    const angleDelta=Math.abs(normalizeSigned(plan.bearing-current.bearing));
    const pointDelta=window.DoorFitCamera.project(origin,plan,viewport.width,viewport.height);
    const pointNow=window.DoorFitCamera.project(origin,current,viewport.width,viewport.height);
    const pixelMove=Math.hypot(pointDelta[0]-pointNow[0],pointDelta[1]-pointNow[1]);
    if(!force && !newRoute && fitsNow && Math.abs(plan.zoom-current.zoom)<.12 && angleDelta<4 && pixelMove<14)return;
    state.fitLastPlan=plan;
    state.fitStats.animations++;
    state.cameraPlan={...plan,mode:'fit',nav:false,locked:true,remainingMeters:remaining,viewport,
      lastComputeMs:state.fitStats.lastComputeMs};
    const reduce=window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    map.easeTo({center:plan.center,zoom:plan.zoom,bearing:plan.bearing,pitch:0,
      padding:{top:0,right:0,bottom:0,left:0},offset:[0,0],
      duration:reduce?0:(force||newRoute?650:500),easing:t=>1-Math.pow(1-t,3)});
    updateNlscDetailOverlayVisibility();syncFitUi();
  }

  function fitRouteAccepted() {
    state.fitRouteWaiting=false;
    if(!state.fitLocked)return;
    state.fitRouteWaiting=false;state.fitNeedsRefresh=true;
    state.autoFitRoutePending=false;state.following=false;state.cameraUserOverride=false;
    updateRouteProgressDisplay();syncCameraControls();syncFitUi();
    updateFitCamera({force:true,full:true});
  }

  function holdFitForTouch(raw) {
    return cameraInteraction?.begin(raw) || false;
  }

  function moveFitTouch(ev) {
    cameraInteraction?.move(ev);
  }

  function endFitTouch(ev) {
    cameraInteraction?.end(ev);
  }

  function beginManualZoomCapture(ev) {
    if(!ev?.originalEvent)return;
    if(!(state.fitLocked || (state.following&&!state.cameraUserOverride)))return;
    if(Number.isFinite(state.cameraGestureStartZoom))return;
    state.cameraGestureStartZoom=map.getZoom();
  }

  function commitManualZoomCapture(ev) {
    if(!Number.isFinite(state.cameraGestureStartZoom))return;
    const start=state.cameraGestureStartZoom;
    state.cameraGestureStartZoom=null;
    if(!ev?.originalEvent)return;
    const end=map.getZoom(),delta=end-start;
    if(!Number.isFinite(delta)||Math.abs(delta)<.03)return;
    state.cameraZoomOffset=Math.max(-3,Math.min(3,(Number(state.cameraZoomOffset)||0)+delta));
    if(state.fitLocked)state.fitNeedsRefresh=true;
  }

  function showRouteOverview({duration=520}={}) {
    if(state.fitLocked) {updateFitCamera({force:true,full:true});return;}
    if(state.cameraRestorePending && state.following && !state.cameraUserOverride){
      state.autoFitRoutePending=false;if(state.position)followCamera({force:true});return;
    }
    if(!state.position || !state.destination)return;
    state.following=false;state.navigationActive=false;
    syncCameraControls();els.modeText.textContent='路線總覽';
    map.stop();map.resize();updateRouteProgressDisplay();
    if(!window.DoorFitCamera)return;
    const coords=fitRouteInput();
    const plan=window.DoorFitCamera.solve(coords,[state.position.lng,state.position.lat],
      [state.destination.lng,state.destination.lat],fitViewport(),{full:true,maxZoom:18.85,riderAnchor:true});
    if(plan)map.easeTo({...plan,duration,padding:{top:0,right:0,bottom:0,left:0},offset:[0,0]});
  }

  function installMainOperationalLayers() {
    if (!map.isStyleLoaded()) return;
    state.mapsReady = true;

    applyMainThemePaint(state.theme);
    if(typeof syncOriginalHouseNumberVisibility==='function')syncOriginalHouseNumberVisibility();

    if (!map.getSource('accuracy')) {
      map.addSource('accuracy', { type:'geojson', data: emptyFeatureCollection() });
    }
    if (!map.getLayer('accuracy-fill')) {
      map.addLayer({
        id:'accuracy-fill', type:'fill', source:'accuracy',
        paint:{ 'fill-color':'#3a82ff', 'fill-opacity':0.12 }
      });
    }

    if (!map.getSource('dest-guide')) {
      map.addSource('dest-guide', { type:'geojson', data: emptyFeatureCollection() });
    }
    if (!map.getLayer('dest-guide-line')) {
      map.addLayer({
        id:'dest-guide-line', type:'line', source:'dest-guide',
        paint:{ 'line-color':'#8090a0', 'line-opacity':0.24, 'line-width':2, 'line-dasharray':[2,3] }
      });
    }

    scheduleMainSceneSync('map-ready', 0);
    renderAll();

    if (state.routeEnabled && state.position && state.destination &&
        !(state.routeGeoJson?.features?.[0]?.geometry?.coordinates?.length)) {
      state.autoFitRoutePending = true;
      requestRoute({force:true});
    }
  }
  // Initial style.load can happen very early on a fast phone. Listen to both
  // load and style.load, and also do an immediate loaded-state check.
  map.on('move', scheduleCenterCoordinatePanel);
  map.on('move',()=>globalThis.DoorPowerDiag?.mark?.('mapMove'));
  map.on('render',()=>globalThis.DoorPowerDiag?.mark?.('mapRender'));
  map.on('moveend', e=>{if(!window.DoorVisualMotion||window.DoorVisualMotion.sceneEvent(e))scheduleCleanMapDetails();});
  map.on('moveend', e=>{if(!window.DoorVisualMotion||window.DoorVisualMotion.sceneEvent(e))updateNlscDetailOverlayVisibility();});
  map.on('zoom', e=>{if(!window.DoorVisualMotion||window.DoorVisualMotion.sceneEvent(e))updateNlscDetailOverlayVisibility();});
  map.on('load', installMainOperationalLayers);
  map.on('style.load', installMainOperationalLayers);

  setTimeout(() => {
    if (map.isStyleLoaded()) installMainOperationalLayers();
  }, 0);
  setTimeout(() => {
    if (map.isStyleLoaded()) installMainOperationalLayers();
  }, 350);

  let motionIdleAt=0;
  map.on('idle', () => {
    if(visualMotion?.animating&&performance.now()-motionIdleAt<600)return;
    motionIdleAt=performance.now();
    if (!map.isStyleLoaded()) return;

    if (!state.mapsReady) {
      installMainOperationalLayers();
      return;
    }

    const h = mainSceneHealth();
    const missingRequired = !h.pin || !h.community || !h.place || !h.entrance || !h.route || !h.doorplate;
    if (missingRequired && Date.now() - state.mainSceneLastSync > 500) {
      scheduleMainSceneSync('idle-repair', 0);
    }
  });

  function syncCenterCoordinatePanel() {
    cancelAnimationFrame(state.centerCoordRaf);state.centerCoordRaf=0;
    const manual=!!state.cameraUserOverride&&!state.fitLocked;
    if(!manual)state.centerPickEnabled=false;
    const enabled=manual&&!!state.centerPickEnabled;
    if(els.centerCoordPanel){els.centerCoordPanel.hidden=!manual;els.centerCoordPanel.classList.toggle('expanded',enabled);}
    if(els.centerCoordToggle)els.centerCoordToggle.setAttribute('aria-expanded',String(enabled));
    if(els.centerCoordBody)els.centerCoordBody.hidden=!enabled;
    if(els.centerCoordModeText)els.centerCoordModeText.textContent=enabled?'啟用':'關閉';
    if(els.centerPickReticle)els.centerPickReticle.hidden=!enabled;
    if(!enabled||!els.centerCoordText)return;
    const c=map.getCenter();els.centerCoordText.textContent=`${Number(c.lat).toFixed(7)}, ${Number(c.lng).toFixed(7)}`;
  }
  function setCenterPickEnabled(on,{announce=true}={}) {
    const next=!!on&&!!state.cameraUserOverride&&!state.fitLocked;
    if(next===state.centerPickEnabled){syncCenterCoordinatePanel();return next;}
    state.centerPickEnabled=next;
    if(next)state.centerNavigateSelectedDestination=null;
    syncCenterCoordinatePanel();
    if(announce)toast(next?'地圖中心選點已啟用':'地圖中心選點已關閉');
    return next;
  }
  function scheduleCenterCoordinatePanel() {
    // Opening/closing is synchronized by controls. No per-frame DOM/RAF work for a disabled picker.
    if(document.hidden||!state.centerPickEnabled||state.centerCoordRaf)return;state.centerCoordRaf=requestAnimationFrame(()=>{state.centerCoordRaf=0;syncCenterCoordinatePanel();});
  }
  async function copyTextSafe(text) {
    try{await navigator.clipboard.writeText(text);return true;}catch(_){}
    try{const ta=document.createElement('textarea');ta.value=text;ta.setAttribute('readonly','');ta.style.position='fixed';ta.style.opacity='0';document.body.append(ta);ta.select();const ok=document.execCommand('copy');ta.remove();return !!ok;}catch(_){return false;}
  }

  function syncCameraControls() {
    const automatic=!state.fitLocked && state.following && !state.cameraUserOverride;
    els.followBtn.classList.toggle('active',automatic);
    els.followBtn.setAttribute('aria-pressed',String(automatic));
    els.headingBtn.textContent='↑';
    els.headingBtn.classList.toggle('active',automatic && state.mode === 'heading');
    els.headingBtn.setAttribute('aria-pressed',String(automatic && state.mode === 'heading'));
    els.headingBtn.title=automatic&&state.mode==='heading'?'鏡頭前行模式':'切換到鏡頭前行模式';
    if(els.northModeBtn){els.northModeBtn.classList.toggle('active',automatic&&state.mode==='north');els.northModeBtn.setAttribute('aria-pressed',String(automatic&&state.mode==='north'));}
    syncNavigationUi();
    syncCenterCoordinatePanel();
    els.modeText.textContent=automatic
      ? (state.navigationActive ? (buildings3d?.enabled?'3D 導航':'2.5D 導航') : (state.mode === 'north' ? '北向跟隨' : '朝向跟隨'))
      : (state.mode === 'north' ? '手動瀏覽 · 北向偏好' : '手動瀏覽 · 朝向偏好');
    if(typeof syncFitUi==='function')syncFitUi();
    if(typeof cameraInteraction!=='undefined')cameraInteraction?.selectionChanged();
  }

  function releaseAutoFollowOnUserGesture(ev) {
    // Also run at the DOM capture phase: repeated compass easeTo animations can
    // otherwise win before MapLibre emits dragstart/zoomstart on iOS.
    const raw=ev?.originalEvent || ev;
    const direct=raw && /^(pointerdown|touchstart|mousedown|wheel|keydown)$/.test(raw.type || '');
    if (!ev?.originalEvent && !direct) return;
    if (raw?.type === 'keydown' && !['ArrowUp','ArrowDown','ArrowLeft','ArrowRight','+','-','=','PageUp','PageDown'].includes(raw.key)) return;
    if(typeof cameraInteraction!=='undefined' && cameraInteraction?.handle(ev))return;
    // A touch landing is not a request for manual browsing. Only a real map
    // transform or wheel/key action may release a non-riding overview.
    if(/^(pointerdown|touchstart|mousedown)$/.test(raw?.type||'') && !ev?.originalEvent)return;
    const wasAutomatic=state.fitLocked || state.following || !state.cameraUserOverride;
    if(state.fitLocked)stopFitLock('manual');
    state.following=false;
    state.cameraUserOverride=true;
    if(ev?.type==='pitchstart')state.manual3dAutoPitch=false;
    state.autoFitRoutePending=false;
    syncCameraControls();
    if (wasAutomatic) map.stop();
    // No preventDefault/stopPropagation: the original gesture continues normally.
  }
  map.on('dragstart', releaseAutoFollowOnUserGesture);
  map.on('zoomstart', beginManualZoomCapture);
  map.on('zoomstart', releaseAutoFollowOnUserGesture);
  map.on('rotatestart', releaseAutoFollowOnUserGesture);
  map.on('pitchstart', releaseAutoFollowOnUserGesture);
  map.on('zoomend', commitManualZoomCapture);
  map.on('zoomend', maybeApplyManual3dPitch);
  function releaseSearchSelectedDestinationOnManualGesture(ev) {
    const raw=ev?.originalEvent || ev;
    if(!raw || !/^(pointerdown|touchstart|mousedown|wheel|keydown)$/.test(raw.type || ''))return;
    if(raw.type==='keydown'&&!['ArrowUp','ArrowDown','ArrowLeft','ArrowRight','+','-','=','PageUp','PageDown'].includes(raw.key))return;
    // Browsing the map does not discard the selected destination while center-pick is collapsed.
    if(state.centerPickEnabled)state.centerNavigateSelectedDestination=null;
  }
  if(window.DoorCameraInteraction){
    cameraInteraction=new window.DoorCameraInteraction.Controller({
      getState:()=>state,storage:localStorage,isHidden:()=>document.hidden,
      isEditing:()=>!!planner?.editing||state.deliveryAwaitPick,
      stop:()=>{map.stop();visualMotion?.stopCamera();},
      resume:()=>{
        if(document.hidden)return;
        map.resize();updateRouteProgressDisplay();
        if(state.fitLocked){state.fitNeedsRefresh=true;updateFitCamera({force:true});}
        else if(state.following&&!state.cameraUserOverride)followCamera({force:true});
        syncCameraControls();
      }
    });
    window.addEventListener('pagehide',()=>cameraInteraction.lifecycle(false));
    window.addEventListener('pageshow',()=>cameraInteraction.lifecycle(true));
    document.addEventListener('visibilitychange',()=>cameraInteraction.lifecycle(!document.hidden));
    window.addEventListener('door581:nativeLifecycle',ev=>{
      const phase=ev?.detail?.state;
      if(['background','inactive','willResignActive','didEnterBackground'].includes(phase))cameraInteraction.lifecycle(false);
      else if(['foreground','willForeground','active','didBecomeActive'].includes(phase))cameraInteraction.lifecycle(true);
    });
  }

  const mainGestureSurface=map.getCanvasContainer();
  for (const type of ['pointerdown','touchstart','mousedown','wheel','keydown']) {
    mainGestureSurface.addEventListener(type,releaseAutoFollowOnUserGesture,{capture:true,passive:true});
    mainGestureSurface.addEventListener(type,releaseSearchSelectedDestinationOnManualGesture,{capture:true,passive:true});
  }

  for(const type of ['pointermove','touchmove','mousemove'])
    mainGestureSurface.addEventListener(type,moveFitTouch,{capture:true,passive:true});
  for(const type of ['pointerup','pointercancel','touchend','touchcancel','mouseup'])
    window.addEventListener(type,endFitTouch,{capture:true,passive:true});

  inset.on('load', () => {
    syncInsetScene({recenter:true});
  });

  function emptyFeatureCollection() { return { type:'FeatureCollection', features:[] }; }

  function dmsToDecimal(deg,min,sec,hem) {
    let value=Number(deg)+Number(min)/60+Number(sec)/3600;
    if (/[SW]/i.test(String(hem||''))) value=-value;
    return value;
  }

  function parseDestination(text) {
    if (!text) return null;
    let decoded=String(text).trim();
    // A Maps URL may contain its CAMERA center before the destination. Resolve it separately.
    if(/https?:\/\//i.test(decoded) || /^(maps\.|(?:www\.)?google\.|goo\.gl\/maps)/i.test(decoded))return null;
    try { decoded=decodeURIComponent(decoded); } catch (_) {}
    decoded=decoded
      .replace(/\+/g,' ')
      .replace(/[′’]/g,"'")
      .replace(/[″”]/g,'"')
      .trim();

    // Google Maps decimal pair, including parentheses:
    //   24.1371000, 120.6684910
    //   (24.1371000, 120.6684910)
    let m=decoded.match(/(-?\d{1,2}(?:\.\d+)?)\s*[,，]\s*(-?\d{2,3}(?:\.\d+)?)/);
    if (m) {
      const lat=Number(m[1]),lng=Number(m[2]);
      if (Number.isFinite(lat)&&Number.isFinite(lng)&&lat>=20&&lat<=27&&lng>=117&&lng<=123) return {lat,lng};
    }

    // Google Maps DMS pair:
    //   24°08'13.6\"N 120°40'06.6\"E
    m=decoded.match(/(\d{1,2})\s*°\s*(\d{1,2})\s*'\s*([\d.]+)\s*\"?\s*([NS])\s*[, ]+\s*(\d{1,3})\s*°\s*(\d{1,2})\s*'\s*([\d.]+)\s*\"?\s*([EW])/i);
    if (m) {
      const lat=dmsToDecimal(m[1],m[2],m[3],m[4]);
      const lng=dmsToDecimal(m[5],m[6],m[7],m[8]);
      if (Number.isFinite(lat)&&Number.isFinite(lng)&&lat>=20&&lat<=27&&lng>=117&&lng<=123) return {lat,lng};
    }
    return null;
  }

  function looksLikeGoogleMapsShare(value) {
    return !!globalThis.DoorMapLinks.extract(value);
  }

  function normalizeGoogleMapsShare(value) {
    return globalThis.DoorMapLinks.extract(value);
  }

  async function resolveGoogleMapsShare(value) {
    const url = normalizeGoogleMapsShare(value);
    if (!url) throw new Error('不是支援的 Google Maps 分享連結');

    const res = await fetch('/api/google-resolve', {
      method:'POST',
      headers:{
        'Accept':'application/json',
        'Content-Type':'text/plain;charset=UTF-8'
      },
      body:url,
      cache:'no-store'
    });

    if (!res.ok) {
      const detail = await res.text().catch(()=>'');
      const err=new Error(detail || `Google Maps 解析失敗 HTTP ${res.status}`);err.status=res.status;throw err;
    }

    const data = await res.json();
    const d = parseDestination(`${data.lat},${data.lng}`);
    if (!d) throw new Error('Google Maps 連結沒有解析出有效台灣座標');
    d.__sourceMeta = {
      kind:'google',
      source:String(data.source || ''),
      finalUrl:String(data.finalUrl || ''),
      targetText:String(data.targetText || '').trim(),
      placeName:String(data.placeName||'').trim(),addressText:String(data.addressText||''),floor:String(data.floor||''),notice:String(data.notice||''),verifiedAddress:!!data.verifiedAddress
    };
    return d;
  }

  function clearAddressResults() {
    if (els.addressResults) els.addressResults.replaceChildren();
  }

  function currentSearchCenter() {
    if (state.position) return {lat:state.position.lat,lng:state.position.lng};
    try {
      const c=map.getCenter();
      if (c && Number.isFinite(c.lat) && Number.isFinite(c.lng)) return {lat:c.lat,lng:c.lng};
    } catch (_) {}
    return null;
  }

  function nativeBridgeActive() {
    return window.Door581Native?.isNative === true;
  }

  async function nativeAppleSearch(query,center=currentSearchCenter(),radiusM=3000) {
    if (!nativeBridgeActive() || typeof window.Door581Native?.searchApple !== 'function') return [];
    if (state.nativeNetworkOnline===false) return [];
    try {
      const timeout=new Promise((_,reject)=>setTimeout(()=>reject(Error('Apple search timeout')),4200));
      const payload=await Promise.race([window.Door581Native.searchApple(String(query||'').trim(),center,radiusM),timeout]);
      return (Array.isArray(payload?.results)?payload.results:[]).map(item=>({
        ...item,
        lat:Number(item.lat),
        lng:Number(item.lng),
        source:'apple-mklocalsearch'
      })).filter(item=>Number.isFinite(item.lat)&&Number.isFinite(item.lng));
    } catch (_) {
      return [];
    }
  }

  function looksLikeStreetAddressQuery(q) {
    return /(?:市|縣|區|鄉|鎮|路|街|大道|段|巷|弄|號)/.test(String(q || ''));
  }

  function resultKey(item) {
    if (item.osmType && item.osmId) return `${item.osmType}:${item.osmId}`;
    return `${Number(item.lat).toFixed(5)},${Number(item.lng).toFixed(5)}:${String(item.displayName || '').slice(0,28)}`;
  }

  async function searchNearbyPoi(query, center, timeoutMs=4200) {
    if (!center || state.nativeNetworkOnline===false) return [];
    const seq=++state.poiSearchSeq;
    const url=new URL('/api/poi-search',location.origin);
    url.searchParams.set('q',String(query || '').trim());url.searchParams.set('v',window.DoorSearchCore.VERSION);
    url.searchParams.set('lat',center.lat.toFixed(6));
    url.searchParams.set('lng',center.lng.toFixed(6));
    const ctl=new AbortController(),timer=setTimeout(()=>ctl.abort(),timeoutMs);
    try {
      const res=await fetch(url,{headers:{'Accept':'application/json'},cache:'no-store',signal:ctl.signal});
      if (!res.ok) return [];
      const data=await res.json();
      if (seq!==state.poiSearchSeq) return [];
      return Array.isArray(data.results) ? data.results : [];
    } finally { clearTimeout(timer); }
  }

  async function localPlaceSearch(query,center=currentSearchCenter(),limit=16) {
    const groups=await Promise.all([
      window.DoorLocalSearch?.search?.(query,center,limit).catch(()=>[]) || [],
      window.DoorSupplementalPoi?.search?.(query,center,limit).catch(()=>[]) || [],
      window.DoorCommunities?.search?.(query,center,limit).catch(()=>[]) || []
    ]);
    const merged=window.DoorSearchCore.rankResults(groups,query,center);if(center)merged.sort((a,b)=>(Number.isFinite(a.distanceM)?a.distanceM:Infinity)-(Number.isFinite(b.distanceM)?b.distanceM:Infinity));return merged.slice(0,limit);
  }

  function legacyFullLocalRows(data,query,center,cap=5000) {
    if(!Array.isArray(data))return [];
    const api=window.DoorLocalSearch,normalize=api?.normalize || (v=>String(v||'').normalize('NFKC').replace(/臺/g,'台').toLowerCase());
    const wanted=(String(query||'').normalize('NFKC').replace(/臺/g,'台').toLowerCase().match(/[0-9a-z\u3400-\u9fff]+/g)||[]).map(normalize).filter(Boolean);
    if(!wanted.length)return [];
    const out=[];
    for(const r of data){
      if(!Array.isArray(r)||r.length<8)continue;
      const lat=Number(r[3]),lng=Number(r[4]);if(!Number.isFinite(lat)||!Number.isFinite(lng))continue;
      const hay=[r[0],r[2],r[5],r[6],r[7]].map(normalize).join('|');
      if(!wanted.every(t=>hay.includes(t)))continue;
      const distanceM=center?haversineMeters(center,{lat,lng}):null;
      out.push({displayName:String(r[1]||''),aliases:String(r[2]||''),lat,lng,address:String(r[5]||''),category:String(r[6]||''),feature:String(r[7]||''),source:'offline-index',osmKey:String(r[8]||''),distanceM:Number.isFinite(distanceM)?distanceM:null});
      if(out.length>=cap)break;
    }
    if(center)out.sort((a,b)=>(a.distanceM??Infinity)-(b.distanceM??Infinity));
    return out;
  }

  async function allLocalPlaceSearch(query,center=currentSearchCenter()) {
    const api=window.DoorLocalSearch;let primary=[];
    try{
      if(api?.searchAll)primary=await api.searchAll(query,center);
      else if(api?.ensure)primary=legacyFullLocalRows(await api.ensure(),query,center,5000);
      else if(api?.search)primary=await api.search(query,center,5000);
    }catch(_){primary=[];}
    const supplemental=await (window.DoorSupplementalPoi?.search?.(query,center,200).catch(()=>[])||[]);
    const communities=await (window.DoorCommunities?.search?.(query,center).catch(()=>[])||[]);
    return window.DoorSearchCore.rankResults([primary||[],supplemental||[],communities||[]],query,center);
  }

  function mergeAddressSearchResults(groups,center) {
    const merged=[],seen=new Set();
    for(const group of groups||[]) for(const item of group||[]) {
      const lat=Number(item.lat),lng=Number(item.lng);
      if(!Number.isFinite(lat)||!Number.isFinite(lng))continue;
      const normalized={...item,lat,lng};
      const key=resultKey(normalized);if(seen.has(key))continue;
      if(normalized.source==='apple-mklocalsearch'&&normalized.appleBrandKey&&
         merged.some(x=>x.source!=='apple-mklocalsearch'&&haversineMeters(x,normalized)<=30))continue;
      seen.add(key);
      if(!Number.isFinite(normalized.distanceM))normalized.distanceM=center?haversineMeters(center,normalized):null;
      merged.push(normalized);
    }
    const sourceRank=x=>x.source==='supplemental-place'?0:(x.source==='offline-index'?1:(x.source==='apple-mklocalsearch'?2:(x.source==='nominatim'?3:(x.source==='overpass'?4:5))));
    merged.sort((a,b)=>sourceRank(a)-sourceRank(b)||
      (Number.isFinite(a.distanceM)?a.distanceM:Infinity)-(Number.isFinite(b.distanceM)?b.distanceM:Infinity));
    return merged.slice(0,20);
  }

  async function geocodeAddress(query,{seed=[],center=currentSearchCenter()}={}) {
    const q=String(query || '').trim();
    if (q.length<2) throw new Error('搜尋文字太短');
    const seq=++state.addressSearchSeq;
    const local=seed.length?seed:await localPlaceSearch(q,center,20);
    const applePromise=nativeAppleSearch(q,center);
    const url=new URL('/api/geocode',location.origin);url.searchParams.set('q',q);
    if(center){url.searchParams.set('lat',center.lat.toFixed(6));url.searchParams.set('lng',center.lng.toFixed(6));}
    const ctl=new AbortController(),timer=setTimeout(()=>ctl.abort(),6500);
    let geoData=null,geoError=null;
    try {
      const res=await fetch(url,{method:'GET',headers:{'Accept':'application/json'},cache:'no-store',signal:ctl.signal});
      if(!res.ok){const detail=await res.text().catch(()=>'');throw new Error(detail||`地址搜尋失敗 HTTP ${res.status}`);}
      geoData=await res.json();
    } catch(err){geoError=err;} finally{clearTimeout(timer);}
    if(seq!==state.addressSearchSeq)return [];
    const geoResults=(Array.isArray(geoData?.results)?geoData.results:[]).map(x=>({...x,source:x.source||'nominatim'}));
    const appleResults=await applePromise;
    let poiResults=[];
    // Existing live Overpass is only a short best-effort fallback now. It can no
    // longer hold the whole search UI for ~20 s; the local index covers Taichung.
    if(!looksLikeStreetAddressQuery(q)&&center&&!local.length&&!geoResults.length){
      poiResults=await searchNearbyPoi(q,center,3200).catch(()=>[]);
    }
    const merged=mergeAddressSearchResults([local,appleResults,geoResults,poiResults],center);
    if(!merged.length&&geoError) {
      if(geoError?.name==='AbortError')throw new Error('網路搜尋逾時；台中本機候選仍可直接使用');
      throw new Error(String(geoError?.message||geoError||'地址搜尋暫時不可用'));
    }
    return merged;
  }


  function rememberSearchSelectedDestination(dest) {
    if (!dest || !Number.isFinite(Number(dest.lat)) || !Number.isFinite(Number(dest.lng))) {
      state.centerNavigateSelectedDestination=null;return;
    }
    state.centerNavigateSelectedDestination={lat:Number(dest.lat),lng:Number(dest.lng)};
  }

  function centerNavigateTarget(center=map.getCenter()) {
    // Hard boundary: when the tool is collapsed, camera center is never a destination.
    if (!state.centerPickEnabled) {
      const picked=state.centerNavigateSelectedDestination;
      if (picked && state.destination && haversineMeters(picked,state.destination)<=1.5) {
        return {point:{lat:Number(state.destination.lat),lng:Number(state.destination.lng)},source:'selected-destination'};
      }
      if (state.destination) return {point:{lat:Number(state.destination.lat),lng:Number(state.destination.lng)},source:'current-destination'};
      return {point:null,source:'disabled'};
    }
    return {point:{lat:Number(center.lat),lng:Number(center.lng)},source:'map-center'};
  }

  function renderAddressResults(results,{showEmptyError=true}={}) {
    clearAddressResults();

    if (!results.length) {
      if(showEmptyError)els.destError.textContent = '找不到這個地址；可改貼座標或 Google Maps 分享連結';
      return;
    }

    for (const result of results) {
      const lat = Number(result.lat);
      const lng = Number(result.lng);
      if (!Number.isFinite(lat) || !Number.isFinite(lng)) continue;

      const button = document.createElement('button');
      button.type = 'button';
      button.className = `address-result${result.source==='offline-index'?' local-result':''}`;

      const title = document.createElement('span');
      title.className = 'address-result-title';
      title.textContent = result.displayName || `${lat.toFixed(6)}, ${lng.toFixed(6)}`;
      if(result.source==='offline-index'){const badge=document.createElement('span');badge.className='address-result-source';badge.textContent='本機';title.append(badge);}
      if(result.source==='apple-mklocalsearch'){const badge=document.createElement('span');badge.className='address-result-source';badge.textContent='Apple';title.append(badge);}

      const sub = document.createElement('span');
      sub.className = 'address-result-sub';

      const distanceText=Number.isFinite(result.distanceM)
        ? (result.distanceM>=1000
            ? `${(result.distanceM/1000).toFixed(1)} km`
            : `${Math.round(result.distanceM)} m`)
        : '';

      const parts=[];
      if(result.address)parts.push(result.address);
      if (distanceText) parts.push(distanceText);
      if (result.approximate) parts.push('⚠ 僅路段約略位置');
      else if (result.source==='offline-index') parts.push('台中離線場所');
      else if (result.source==='overpass') parts.push('附近 OSM 地點');
      parts.push(`${lat.toFixed(6)}, ${lng.toFixed(6)}`);
      sub.textContent=parts.join(' · ');

      button.append(title,sub);
      button.addEventListener('click', () => {
        setDestination({lat,lng,__sourceMeta:{kind:'search',source:result.source||'search',targetText:result.address||result.displayName||'',placeName:result.approximate?'':(result.name||(!looksLikeStreetAddressQuery(result.displayName||'')?result.displayName:'')),addressText:result.address||'',approximate:!!result.approximate}},{fit:true,persist:true});
        rememberSearchSelectedDestination({lat,lng});
        els.destDialog.close();
        clearAddressResults();
        toast(result.approximate ? '已使用路段約略位置' : '地址目的地已設定');
      });

      els.addressResults.append(button);
    }
  }

  function scheduleLocalDestinationSuggestions() {
    clearTimeout(state.localSearchTimer);
    const raw=String(els.destInput?.value||'').trim(),seq=++state.localSearchSeq;
    els.destError.textContent='';
    if(!raw||looksLikeGoogleMapsShare(raw)||parseDestination(raw)){clearAddressResults();return;}
    state.localSearchTimer=setTimeout(async()=>{
      const results=await localPlaceSearch(raw,currentSearchCenter(),14);
      if(seq!==state.localSearchSeq||!els.destDialog.open||String(els.destInput.value||'').trim()!==raw)return;
      renderAddressResults(results,{showEmptyError:false});
      if(els.searchHint)els.searchHint.textContent=results.length
        ? `台中本機立即候選 ${results.length} 筆；按「搜尋 / 套用」可再補 Nominatim 網路結果`
        : '本機暫無候選；按「搜尋 / 套用」會查 Nominatim 網路結果';
    },110);
  }

  function destinationFromQuery() {
    const q = new URLSearchParams(location.search);
    const raw = q.get('dest') || (q.get('lat') && q.get('lng') ? `${q.get('lat')},${q.get('lng')}` : null);
    return parseDestination(raw);
  }

  function googleShareFromQuery() {
    const q = new URLSearchParams(location.search);
    return q.get('gmap') || null;
  }

  function destinationHandoffFromHash() {
    const raw=String(location.hash || '').replace(/^#/, '');
    if (!raw) return null;
    const q=new URLSearchParams(raw);
    const gmap=q.get('gmap');
    const dest=parseDestination(q.get('dest'));
    if (gmap) return {kind:'gmap',value:gmap,source:'hash'};
    if (dest) return {kind:'dest',value:dest,source:'hash'};
    return null;
  }

  function stabilizeBrowserUrl() {
    // Keep the live Door Map document on one stable URL. The iOS Shortcut now
    // changes ONLY the #gmap fragment, so Safari does not reload the document.
    // This preserves GPS + an already-granted compass session between orders.
    try {
      const stable=`${location.pathname || '/'}${location.hash && !/^#(?:gmap|dest)=/i.test(location.hash) ? location.hash : ''}`;
      history.replaceState(null,'',stable || '/');
    } catch (_) {}
  }

  async function resolveGoogleMapsShareRobust(value, attempts=3) {
    let lastErr=null;
    for (let attempt=0; attempt<attempts; attempt++) {
      try {
        return await resolveGoogleMapsShare(value);
      } catch (err) {
        lastErr=err;
        const msg=String(err?.message || err || '');
        // Bad input/unsupported URLs will not improve by retrying.
        if ((err.status>=400&&err.status<500)||/不是支援|只接受|HTTP 4\d\d|422/.test(msg)) break;
        if (attempt<attempts-1) await new Promise(r=>setTimeout(r, 350 + attempt*500));
      }
    }
    throw lastErr || new Error('Google Maps 分享連結解析失敗');
  }

  async function consumeHashDestinationHandoff({fit=true}={}) {
    const handoff=destinationHandoffFromHash();
    if (!handoff) return false;
    const seq=++state.destinationHandoffSeq;
    state.destinationHandoffBusy=true;
    state.destinationHandoffSource='hash';
    try {
      if (handoff.kind==='dest') {
        setDestination(handoff.value,{fit,persist:true,stableUrl:true});
        toast('捷徑目的地已同步');
        return true;
      }
      toast('正在同步 Google Maps Pin…');
      const d=await resolveGoogleMapsShareRobust(handoff.value,3);
      if (seq!==state.destinationHandoffSeq) return true;
      setDestination(d,{fit,persist:true,stableUrl:true});
      toast(d.__sourceMeta?.notice||'Google Maps Pin 已同步');
      return true;
    } catch (err) {
      console.warn('hash destination handoff failed',err);
      if (seq===state.destinationHandoffSeq) {
        toast(`捷徑目的地解析失敗：${String(err?.message || err)}`);
        if (els.insetEmpty && !state.destination) {
          els.insetEmpty.style.display='grid';
          els.insetEmpty.textContent='捷徑目的地解析失敗\n請再分享一次 Google Maps Pin';
        }
      }
      return true;
    } finally {
      if (seq===state.destinationHandoffSeq) {
        state.destinationHandoffBusy=false;
        stabilizeBrowserUrl();
      }
    }
  }

  function normalizeDestinationText(value) {
    return String(value || '')
      .replace(/臺/g,'台')
      .replace(/[（）()【】\[\]\s,，。．·・_\-]/g,'')
      .toLowerCase();
  }

  function extractHouseNumberFromText(value) {
    const m=String(value || '').match(/(\d+(?:之\d+)?)\s*號/);
    return m ? m[1] : '';
  }

  function extractRoadFromText(value) {
    const text=String(value || '').replace(/\s+/g,'');
    const m=text.match(/([^,，]{1,36}?(?:大道|路|街)(?:[一二三四五六七八九十0-9]+段)?)(?:\d+(?:之\d+)?號)/);
    return m ? m[1] : '';
  }

  function destinationIntentInfo(meta) {
    if(meta?.source==='gogoro-official')return {houseNumber:'',houseLabel:'換電站',placeName:String(meta.stationName||''),parentName:'',category:'battery_swap',approximate:false,road:''};
    const targetText=String(meta?.targetText || '').trim();
    const houseNumber=extractHouseNumberFromText(targetText);
    const road=extractRoadFromText(targetText);
    const info={
      houseNumber:'',
      houseLabel:'',
      placeName:'',
      parentName:'',
      category:'',
      approximate:false,
      road:''
    };
    if (houseNumber) {
      info.houseNumber=houseNumber;
      info.houseLabel=`${houseNumber}號`;
      info.road=road;
    } else if (targetText && targetText.length<=100) {
      // Google Maps' human-readable target is more authoritative than a
      // nearest-road reverse-geocode guess such as "≈688號".
      info.placeName=targetText;if(meta?.kind==='google'&&!/^https?:/.test(targetText))info.trustedPlaceName=targetText;
    }
    if(meta?.placeName)info.placeName=String(meta.placeName);
    if(meta?.floor)info.floor=String(meta.floor);
    return info;
  }

  function destinationNameMatchesTarget(name,targetText) {
    const a=normalizeDestinationText(name);
    const b=normalizeDestinationText(targetText);
    if (a.length<2 || b.length<2) return false;
    return a===b || (a.length>=3 && b.includes(a)) || (b.length>=3 && a.includes(b));
  }

  function correctionDistanceOk(raw,candidate) {
    if (!raw || !candidate) return false;
    const d=haversineMeters(raw,candidate);
    return d>=DESTINATION_CORRECTION_MIN_M && d<=DESTINATION_CORRECTION_MAX_M;
  }

  function bestPoiCorrectionCandidate(data) {
    const raw=state.rawDestination;
    const targetText=String(state.destinationIntent?.targetText || '').trim();
    if (!raw || !targetText) return null;

    const house=extractHouseNumberFromText(targetText);
    const targetRoad=normalizeDestinationText(extractRoadFromText(targetText));

    if (house) {
      const addressMatches=(data.addresses || [])
        .filter(a=>String(a.houseNumber || '')===house)
        .filter(a=>{
          if (!targetRoad || !a.road) return true;
          const road=normalizeDestinationText(a.road);
          return !!road && (targetRoad.includes(road) || road.includes(targetRoad));
        })
        .map(a=>({...a,correctionSource:'osm-address'}))
        .filter(a=>correctionDistanceOk(raw,a))
        .sort((a,b)=>a.distance-b.distance);
      if (addressMatches.length) return addressMatches[0];
    }

    const sites=[...(data.communities || []),...(data.places || [])]
      .filter(site=>destinationNameMatchesTarget(site.name,targetText))
      .sort((a,b)=>
        Number(b.containsDestination)-Number(a.containsDestination) ||
        a.distance-b.distance
      );

    for (const site of sites) {
      if (!(site.containsDestination || site.distance<=70)) continue;
      const entrances=(data.entrances || [])
        .filter(e=>e.placeName && normalizeDestinationText(e.placeName)===normalizeDestinationText(site.name))
        .sort((a,b)=>
          Number(b.kind==='main')-Number(a.kind==='main') ||
          a.distance-b.distance
        );
      for (const ent of entrances) {
        if (correctionDistanceOk(raw,ent)) {
          return {...ent,correctionSource:ent.kind==='main' ? 'osm-main-entrance' : 'osm-entrance'};
        }
      }
      if (correctionDistanceOk(raw,site)) {
        return {...site,correctionSource:'osm-place'};
      }
    }
    return null;
  }

  async function geocodeIntentCorrectionCandidate() {
    const raw=state.rawDestination;
    const targetText=String(state.destinationIntent?.targetText || '').trim();
    if (!raw || !targetText) return null;
    try {
      const u=new URL('/api/geocode',location.origin);
      u.searchParams.set('q',targetText);
      u.searchParams.set('lat',raw.lat.toFixed(6));
      u.searchParams.set('lng',raw.lng.toFixed(6));
      const res=await fetch(u,{headers:{'Accept':'application/json'},cache:'no-store'});
      if (!res.ok) return null;
      const data=await res.json();
      const candidates=(data.results || [])
        .filter(x=>!x.approximate && Number.isFinite(Number(x.lat)) && Number.isFinite(Number(x.lng)))
        .map(x=>({...x,lat:Number(x.lat),lng:Number(x.lng),correctionSource:'nominatim-target'}))
        .filter(x=>correctionDistanceOk(raw,x))
        .sort((a,b)=>haversineMeters(raw,a)-haversineMeters(raw,b));
      return candidates[0] || null;
    } catch (err) {
      console.warn('destination intent geocode unavailable',err);
      return null;
    }
  }

  function applyDestinationCorrection(candidate) {
    if(state.destinationIntent?.source==='gogoro-official')return false;
    const raw=state.rawDestination;
    if (!raw || !candidate || state.destinationCorrection.applied) return false;
    if (!correctionDistanceOk(raw,candidate)) return false;
    const corrected={lat:Number(candidate.lat),lng:Number(candidate.lng)};
    if (!Number.isFinite(corrected.lat) || !Number.isFinite(corrected.lng)) return false;

    const moved=haversineMeters(raw,corrected);
    state.destination=corrected;
    state.destinationCorrection={
      applied:true,
      source:String(candidate.correctionSource || 'address-side'),
      distanceM:moved,
      checked:true
    };

    // A Google target with an explicit house number stays authoritative.
    const intentHouse=extractHouseNumberFromText(state.destinationIntent?.targetText || '');
    if (intentHouse) {
      state.destinationInfo.houseNumber=intentHouse;
      state.destinationInfo.houseLabel=`${intentHouse}號`;
      state.destinationInfo.approximate=false;
    }

    localStorage.setItem('581-door-dest',`${corrected.lat},${corrected.lng}`);
    localStorage.setItem('581-door-dest-raw',`${raw.lat},${raw.lng}`);
    try {
      localStorage.setItem('581-door-dest-meta',JSON.stringify(state.destinationIntent || {}));
    } catch (_) {}

    // Same-side correction is internal state, not a new navigation. Keep the
    // live document on the stable base URL so the next #gmap Shortcut handoff
    // remains fragment-only and cannot force a Safari reload.
    stabilizeBrowserUrl();

    updateDestinationInfoUi();
    scheduleMainSceneSync('destination-side-correction',0);
    syncInsetScene({recenter:true});
    updateDistance();
    updateGuideLine();
    refreshDestinationReverse(corrected);

    if (state.routeEnabled && state.position) {
      state.autoFitRoutePending=false;
      requestRoute({force:true});
    }

    toast(`目的地已依地址同側校正 ${Math.round(moved)}m`);
    return true;
  }

  async function maybeApplySameSideDestinationCorrection(data) {
    if(state.destinationIntent?.source==='gogoro-official'||state.destinationIntent?.verifiedAddress){state.destinationCorrection.checked=true;return;}
    if (state.destinationCorrection.applied || state.destinationCorrection.checked) return;
    const raw=state.rawDestination;
    const targetText=String(state.destinationIntent?.targetText || '').trim();
    if (!raw || !targetText) {
      state.destinationCorrection.checked=true;
      return;
    }

    // Only auto-correct when the raw Google pin is actually sitting on/very
    // near a mapped roadway. A deliberate pin at a gate, alley, loading zone,
    // or building is preserved.
    const roadDistance=Number(data?.roadDistanceM);
    if (!Number.isFinite(roadDistance) || roadDistance>DESTINATION_ROAD_CENTER_M) {
      state.destinationCorrection.checked=true;
      return;
    }

    let candidate=bestPoiCorrectionCandidate(data);
    if (!candidate) candidate=await geocodeIntentCorrectionCandidate();

    state.destinationCorrection.checked=true;
    if (!candidate) return;
    applyDestinationCorrection(candidate);
  }

  function updateDestinationInfoUi() {
    updateInsetTitle();
    if (map?.isStyleLoaded?.()) updateNativeDestinationPin(map,'main',state.destination);
    if (inset?.isStyleLoaded?.()) updateNativeDestinationPin(inset,'inset',state.destination);
  }

  async function refreshDestinationReverse(dest) {
    if (!dest || state.destinationIntent?.source==='gogoro-official') return;
    const seq=++state.destinationInfoSeq;
    try {
      const u=new URL('/api/reverse',location.origin);
      u.searchParams.set('lat',dest.lat.toFixed(7));
      u.searchParams.set('lng',dest.lng.toFixed(7));
      const res=await fetch(u,{headers:{'Accept':'application/json'},cache:'no-store'});
      if (!res.ok) return;
      const data=await res.json();
      if (seq!==state.destinationInfoSeq || !state.destination) return;
      const info={...(state.destinationInfo || {})};
      const intentText=String(state.destinationIntent?.targetText || '').trim();
      const intentHouse=state.destinationCorrection?.source==='inset-manual'?'':extractHouseNumberFromText(intentText);

      if (intentHouse && !info.houseNumber) {
        info.houseNumber=intentHouse;
        info.houseLabel=`${intentHouse}號`;
        info.approximate=false;
      } else if (data.houseNumber && !info.houseNumber) {
        const approximate=Number(data.distanceM)>15;
        // If Google supplied a named place (for example 台中市政府), do not
        // replace it with an unrelated nearest-road "≈688號" guess.
        if (!(intentText && !intentHouse && approximate)) {
          info.houseNumber=String(data.houseNumber).replace(/號$/,'');
          info.approximate=approximate;
          info.houseLabel=`${info.approximate?'≈':''}${info.houseNumber}號`;
        }
      }

      if (data.road && !info.road) info.road=String(data.road);
      // Reverse geocoding is only a fallback for place names. A Google target
      // label or containing OSM site has higher priority.
      if (!info.placeName && data.name && !/^(road|residential|house|address)$/i.test(String(data.type || ''))) {
        info.placeName=String(data.name);
      }
      state.destinationInfo=info;
      updateDestinationInfoUi();
    } catch (err) {
      console.warn('destination reverse lookup failed',err);
    }
  }

  function setDestination(dest, {fit=true, persist=true, stableUrl=false, planRoute=true}={}) {
    if((typeof planner==='undefined'?null:planner)?.editing)planner.cancel({restore:false});
    if (!dest) return;

    const cleanDest={lat:Number(dest.lat),lng:Number(dest.lng)};
    const meta=dest.__sourceMeta && typeof dest.__sourceMeta==='object'
      ? {...dest.__sourceMeta}
      : null;

    resetDeliveryForDestination(cleanDest);
    // Any ordinary destination change invalidates a previous search-result lock.
    // renderAddressResults() re-arms it immediately for a freshly picked result.
    state.centerNavigateSelectedDestination = null;
    state.rawDestination = cleanDest;
    state.destination = cleanDest;
    buildings3d?.sync();
    state.destinationIntent = meta;
    window.__581AppleDestination=String(meta?.source||'').startsWith('apple');
    if(window.__581AppleDestination){persist=false;window.webkit.messageHandlers.appleMapEngine.postMessage({type:'appleSelection',payload:{name:meta.placeName||'',address:meta.addressText||''}});}
    const miniTargetKey=cleanDest.lat+','+cleanDest.lng;
    if(state.nativeMiniTargetKey!==miniTargetKey){state.nativeMiniTargetKey=miniTargetKey;state.insetZoom=19.5;inset.jumpTo({center:[cleanDest.lng,cleanDest.lat],zoom:19.5,bearing:0,pitch:0});}
    state.destinationCorrection = {applied:false,source:'',distanceM:null,checked:false};
    state.destinationInfoSeq++;
    state.destinationInfo = destinationIntentInfo(meta);
    state.arrivalCamera={active:false,locked:false,zoom:null,pitch:null};

    updateDestinationInfoUi();
    refreshDestinationReverse(cleanDest);
    if (fit) state.autoFitRoutePending = true;

    if (persist) {
      localStorage.setItem('581-door-dest', `${cleanDest.lat},${cleanDest.lng}`);
      localStorage.setItem('581-door-dest-raw', `${cleanDest.lat},${cleanDest.lng}`);
      try {
        if (meta) localStorage.setItem('581-door-dest-meta',JSON.stringify(meta));
        else localStorage.removeItem('581-door-dest-meta');
      } catch (_) {}
    }
    if (window.__581AppleDestination || stableUrl || state.destinationHandoffSource==='hash') {
      stabilizeBrowserUrl();
    } else {
      const u = new URL(location.href);
      u.searchParams.set('dest', `${cleanDest.lat.toFixed(6)},${cleanDest.lng.toFixed(6)}`);
      u.searchParams.delete('rawDest');
      u.searchParams.delete('gmap');
      u.hash='';
      history.replaceState(null,'',u);
    }

    els.insetEmpty.style.display = 'none';

    // Main and inset are separate renderers. Both consume the same effective
    // destination. The untouched Google/581 raw pin stays in state.rawDestination.
    scheduleMainSceneSync('destination', 0);
    syncInsetScene({recenter:true});

    updateDistance();
    updateGuideLine();
    refreshNearbyEntrances(cleanDest);
    refreshRouteWaitingStatus();

    // Route planning never waits for same-side correction. The raw/effective
    // destination is immediately routable; a later high-confidence correction
    // simply requests one replacement route.
    if (planRoute && state.routeEnabled && state.position) {
      state.autoFitRoutePending = !!fit;
      requestRoute({force:true});
    } else if (planRoute && fit) {
      showRouteOverview();
    }
  }

  function clearNearbyPoiMarkers() {
    state.communityItems = [];
    state.communityData = emptyCommunityGeo();
    state.communityLabelData = emptyFeatureCollection();
    state.entranceData = emptyFeatureCollection();
    state.entranceItems = [];
    state.placeItems = [];
    state.placeData = emptyFeatureCollection();
    state.placeLabelData = emptyFeatureCollection();
    updateCommunitySources();
  }

  function clearEntranceMarkers() {
    // Compatibility alias used by older code paths.
    clearNearbyPoiMarkers();
  }

  function nearbyPoiCacheKey(dest) {
    // ~11 m-ish bins are enough to reuse data for the same delivery pin.
    return `581-door-nearby-poi-v6:${dest.lat.toFixed(4)},${dest.lng.toFixed(4)}`;
  }

  function readNearbyPoiCache(dest, {allowStale=false}={}) {
    try {
      const raw = localStorage.getItem(nearbyPoiCacheKey(dest));
      if (!raw) return null;
      const obj = JSON.parse(raw);
      if (!obj || !Number.isFinite(obj.ts)) return null;
      const ageMs = Date.now() - obj.ts;
      const limit = allowStale ? OSM_STALE_FALLBACK_MS : OSM_CACHE_TTL_MS;
      if (ageMs > limit) return null;
      if (!Array.isArray(obj.entrances) || !Array.isArray(obj.communities) || !Array.isArray(obj.places)) return null;
      if (obj.communities.some(x =>
        typeof x.hasGeometry !== 'boolean' ||
        typeof x.containsDestination !== 'boolean' ||
        (x.hasGeometry && (!Number.isFinite(x.labelLat) || !Number.isFinite(x.labelLng)))
      )) return null;
      return {
        entrances:obj.entrances,
        communities:obj.communities,
        places:obj.places,
        addresses:Array.isArray(obj.addresses) ? obj.addresses : [],
        roadDistanceM:Number.isFinite(Number(obj.roadDistanceM)) ? Number(obj.roadDistanceM) : null,
        ts:obj.ts,
        ageMs
      };
    } catch (_) {
      return null;
    }
  }

  function writeNearbyPoiCache(dest, data) {
    try {
      localStorage.setItem(
        nearbyPoiCacheKey(dest),
        JSON.stringify({
          ts:Date.now(),
          entrances:data.entrances || [],
          communities:data.communities || [],
          places:data.places || [],
          addresses:data.addresses || [],
          roadDistanceM:Number.isFinite(Number(data.roadDistanceM)) ? Number(data.roadDistanceM) : null
        })
      );
    } catch (_) {}
  }

  function communityLabelGeoJson(items) {
    return {
      type:'FeatureCollection',
      features:(items || []).map((item,index) => ({
        type:'Feature',
        properties:{
          name:item.name,
          containsDestination:item.containsDestination ? 1 : 0,
          rank:index,
          macroVisible:index < 4 ? 1 : 0
        },
        geometry:{
          type:'Point',
          coordinates:[
            Number.isFinite(item.labelLng) ? item.labelLng : item.lng,
            Number.isFinite(item.labelLat) ? item.labelLat : item.lat
          ]
        }
      }))
    };
  }

  function updateDestinationInfoFromOsm(data) {
    if(state.destinationIntent?.source==='gogoro-official')return;
    const current=state.destinationInfo || {};
    const intentText=String(state.destinationIntent?.targetText || '').trim();
    const intentHouse=extractHouseNumberFromText(intentText);
    const intentRoad=normalizeDestinationText(extractRoadFromText(intentText));

    const addresses=(data.addresses || []).slice().sort((a,b) =>
      Number(b.containsDestination)-Number(a.containsDestination) || a.distance-b.distance
    );

    let address=null;
    if (intentHouse) {
      address=addresses.find(x=>
        String(x.houseNumber || '')===intentHouse &&
        (!intentRoad || !x.road ||
          intentRoad.includes(normalizeDestinationText(x.road)) ||
          normalizeDestinationText(x.road).includes(intentRoad))
      ) || null;
    }
    if (!address) address=addresses.find(x => x.containsDestination || x.distance <= 45) || null;

    const allSites=[...(data.communities || []),...(data.places || [])];
    const containing=allSites.filter(x => x.containsDestination);
    const parent=containing.slice().sort((a,b) => (b.areaScore||0)-(a.areaScore||0))[0] || null;

    let primary=null;
    if (intentText && !intentHouse) {
      primary=allSites.filter(x=>destinationNameMatchesTarget(x.name,intentText))
        .sort((a,b)=>Number(b.containsDestination)-Number(a.containsDestination)||a.distance-b.distance)[0] || null;
    }
    if (!primary) {
      primary=containing.slice().sort((a,b) => (a.areaScore||Infinity)-(b.areaScore||Infinity))[0] ||
        allSites.filter(x => x.distance <= 35).sort((a,b)=>a.distance-b.distance)[0] || null;
    }

    const info={...current};
    if (intentHouse) {
      info.houseNumber=intentHouse;
      info.approximate=false;
      info.houseLabel=`${intentHouse}號`;
      if (address?.road) info.road=address.road;
    } else if (address?.houseNumber && !intentText) {
      info.houseNumber=String(address.houseNumber);
      info.approximate=!address.containsDestination && address.distance > 15;
      info.houseLabel=`${info.approximate?'≈':''}${info.houseNumber}號`;
      info.road=address.road || info.road || '';
    }

    if (primary?.name) {
      // A Google place label remains authoritative when it names the same site.
      if (!intentText || intentHouse || destinationNameMatchesTarget(primary.name,intentText)) {
        info.placeName=primary.name;
      }
      info.category=primary.category || 'residential';
    }
    if (parent?.name && parent.name !== info.placeName) info.parentName=parent.name;
    else if (!info.parentName && primary?.name) info.parentName='';
    info.trustedPlaceName=primary?.containsDestination?primary.name:'';
    info.trustedParentName=parent?.containsDestination?parent.name:'';
    state.destinationInfo=info;
    updateDestinationInfoUi();
  }

  function renderNearbyPoiMarkers(data) {
    state.cleanAddressCandidates=Array.isArray(data?.addresses)?data.addresses:[];
    state.cleanDetailAt=0;
    scheduleCleanMapDetails();
    state.communityItems = (data.communities || []).slice(0, COMMUNITY_MAX_RESULTS);
    state.communityData = communityGeoJson(state.communityItems);
    state.communityLabelData = communityLabelGeoJson(state.communityItems);
    state.placeItems = (data.places || []).slice(0, PLACE_MAX_RESULTS);
    state.placeData = placeGeoJson(state.placeItems);
    state.placeLabelData = placeLabelGeoJson(state.placeItems);
    state.entranceItems = (data.entrances || []).slice(0, ENTRANCE_MAX_RESULTS);
    state.entranceData = entranceGeoJson(state.entranceItems);
    updateDestinationInfoFromOsm(data);
    scheduleMainSceneSync('osm', 0);
    syncInsetScene({recenter:false});
  }

  function coordsEqual(a,b) {
    return !!a && !!b && Math.abs(a[0]-b[0]) < 1e-9 && Math.abs(a[1]-b[1]) < 1e-9;
  }

  function geometryCoords(geometry) {
    if (!Array.isArray(geometry)) return [];
    return geometry
      .filter(p => Number.isFinite(p?.lat) && Number.isFinite(p?.lon))
      .map(p => [p.lon,p.lat]);
  }

  function relationMemberCoords(el) {
    const rings = [];
    for (const member of el.members || []) {
      if (member.type !== 'way' || member.role === 'inner') continue;
      const coords = geometryCoords(member.geometry);
      if (coords.length >= 2) rings.push(coords);
    }
    return rings;
  }

  function communityShapes(el) {
    const shapes = [];

    if (el.type === 'way') {
      const coords = geometryCoords(el.geometry);
      if (coords.length >= 3) {
        const closed = coords.length >= 4 && coordsEqual(coords[0],coords[coords.length-1]);
        shapes.push({ type:closed ? 'Polygon' : 'LineString', coords });
      }
    } else if (el.type === 'relation') {
      for (const coords of relationMemberCoords(el)) {
        const closed = coords.length >= 4 && coordsEqual(coords[0],coords[coords.length-1]);
        shapes.push({ type:closed ? 'Polygon' : 'LineString', coords });
      }
    }
    return shapes;
  }

  function shapeBounds(shapes) {
    const pts = [];
    for (const s of shapes || []) pts.push(...(s.coords || []));
    if (!pts.length) return null;
    let minLng=Infinity, maxLng=-Infinity, minLat=Infinity, maxLat=-Infinity;
    for (const [lng,lat] of pts) {
      minLng=Math.min(minLng,lng); maxLng=Math.max(maxLng,lng);
      minLat=Math.min(minLat,lat); maxLat=Math.max(maxLat,lat);
    }
    return { minLng,maxLng,minLat,maxLat };
  }

  function elementPoint(el, shapes=[]) {
    if (Number.isFinite(el.lat) && Number.isFinite(el.lon)) {
      return {lat:el.lat, lng:el.lon};
    }
    const b = shapeBounds(shapes);
    if (b) return {lat:(b.minLat+b.maxLat)/2, lng:(b.minLng+b.maxLng)/2};
    if (el.center && Number.isFinite(el.center.lat) && Number.isFinite(el.center.lon)) {
      return {lat:el.center.lat, lng:el.center.lon};
    }
    return null;
  }

  function pointInRing(point, ring) {
    if (!point || !Array.isArray(ring) || ring.length < 4) return false;
    const x = point.lng, y = point.lat;
    let inside = false;
    for (let i=0, j=ring.length-1; i<ring.length; j=i++) {
      const xi=ring[i][0], yi=ring[i][1];
      const xj=ring[j][0], yj=ring[j][1];
      const hit = ((yi>y)!==(yj>y)) &&
        (x < (xj-xi)*(y-yi)/((yj-yi)||1e-12)+xi);
      if (hit) inside=!inside;
    }
    return inside;
  }

  function communityGeoJson(items) {
    const features = [];
    for (const item of items || []) {
      for (const shape of item.shapes || []) {
        if (shape.type === 'Polygon') {
          const ring = [...shape.coords];
          if (!coordsEqual(ring[0],ring[ring.length-1])) ring.push([...ring[0]]);
          features.push({
            type:'Feature',
            properties:{
              name:item.name,
              containsDestination:item.containsDestination ? 1 : 0
            },
            geometry:{ type:'Polygon', coordinates:[ring] }
          });
        } else if (shape.type === 'LineString') {
          features.push({
            type:'Feature',
            properties:{
              name:item.name,
              containsDestination:item.containsDestination ? 1 : 0
            },
            geometry:{ type:'LineString', coordinates:shape.coords }
          });
        }
      }
    }
    return { type:'FeatureCollection', features };
  }

  function polygonSignedArea(ring) {
    if (!Array.isArray(ring) || ring.length < 3) return 0;
    let sum = 0;
    for (let i=0, j=ring.length-1; i<ring.length; j=i++) {
      sum += ring[j][0]*ring[i][1] - ring[i][0]*ring[j][1];
    }
    return sum / 2;
  }

  function polygonCentroid(ring) {
    if (!Array.isArray(ring) || ring.length < 3) return null;
    let a = 0, cx = 0, cy = 0;
    for (let i=0, j=ring.length-1; i<ring.length; j=i++) {
      const p0 = ring[j], p1 = ring[i];
      const cross = p0[0]*p1[1] - p1[0]*p0[1];
      a += cross;
      cx += (p0[0] + p1[0]) * cross;
      cy += (p0[1] + p1[1]) * cross;
    }
    if (Math.abs(a) < 1e-14) return null;
    return { lng:cx/(3*a), lat:cy/(3*a) };
  }

  function pointSegmentDistanceSq(p, a, b) {
    const vx = b[0]-a[0], vy = b[1]-a[1];
    const wx = p.lng-a[0], wy = p.lat-a[1];
    const vv = vx*vx + vy*vy;
    let t = vv > 0 ? (wx*vx + wy*vy)/vv : 0;
    t = Math.max(0, Math.min(1, t));
    const dx = p.lng - (a[0] + t*vx);
    const dy = p.lat - (a[1] + t*vy);
    return dx*dx + dy*dy;
  }

  function minEdgeDistanceSq(p, ring) {
    let best = Infinity;
    for (let i=0, j=ring.length-1; i<ring.length; j=i++) {
      best = Math.min(best, pointSegmentDistanceSq(p, ring[j], ring[i]));
    }
    return best;
  }

  function bestInteriorPointForRing(ring) {
    if (!Array.isArray(ring) || ring.length < 4) return null;

    let minLng=Infinity, maxLng=-Infinity, minLat=Infinity, maxLat=-Infinity;
    for (const [lng,lat] of ring) {
      minLng=Math.min(minLng,lng); maxLng=Math.max(maxLng,lng);
      minLat=Math.min(minLat,lat); maxLat=Math.max(maxLat,lat);
    }

    const candidates = [];
    const centroid = polygonCentroid(ring);
    if (centroid && pointInRing(centroid, ring)) candidates.push(centroid);

    const boxCenter = {lng:(minLng+maxLng)/2, lat:(minLat+maxLat)/2};
    if (pointInRing(boxCenter, ring)) candidates.push(boxCenter);

    // Tiny deterministic grid search. At most 8 communities are rendered,
    // so this remains cheap while keeping labels inside concave/L-shaped areas.
    const steps = 10;
    for (let y=1; y<steps; y++) {
      for (let x=1; x<steps; x++) {
        const p = {
          lng:minLng + (maxLng-minLng)*(x/steps),
          lat:minLat + (maxLat-minLat)*(y/steps)
        };
        if (pointInRing(p, ring)) candidates.push(p);
      }
    }

    if (!candidates.length) return null;

    let best = candidates[0], bestScore = -1;
    for (const p of candidates) {
      const score = minEdgeDistanceSq(p, ring);
      if (score > bestScore) {
        best = p;
        bestScore = score;
      }
    }
    return best;
  }

  function communityLabelPoint(shapes, fallback) {
    const polygons = (shapes || []).filter(s => s.type === 'Polygon');
    if (!polygons.length) return fallback;

    polygons.sort((a,b) =>
      Math.abs(polygonSignedArea(b.coords)) - Math.abs(polygonSignedArea(a.coords))
    );

    for (const poly of polygons) {
      const p = bestInteriorPointForRing(poly.coords);
      if (p) return p;
    }
    return fallback;
  }

  function classifyPlaceTags(tags) {
    const amenity=String(tags.amenity || '');
    const shop=String(tags.shop || '');
    const building=String(tags.building || '');
    const landuse=String(tags.landuse || '');
    const office=String(tags.office || '');
    const tourism=String(tags.tourism || '');

    const buildingUse=String(tags['building:use'] || '');
    const leisure=String(tags.leisure || '');
    const healthcare=String(tags.healthcare || '');
    const railway=String(tags.railway || '');
    const publicTransport=String(tags.public_transport || '');
    const highway=String(tags.highway || '');
    const manMade=String(tags.man_made || '');
    const historic=String(tags.historic || '');
    const aeroway=String(tags.aeroway || '');

    if (landuse === 'residential' || /^(apartments|residential|condominium|house|detached|terrace|semidetached_house)$/.test(building) || buildingUse === 'residential' || tags.residential === 'apartments') {
      return {category:'residential',feature:'residential'};
    }
    if (amenity === 'marketplace') return {category:'commercial',feature:'marketplace'};
    if (shop) return {category:'commercial',feature:shop === 'mall' ? 'mall' : (shop === 'department_store' ? 'department_store' : 'shop')};
    if (/^(restaurant|cafe|fast_food|food_court|bar|pub|bank|pharmacy|cinema|theatre|fuel|car_wash|nightclub)$/.test(amenity)) return {category:'commercial',feature:amenity};
    if (/^(hotel|motel|guest_house|hostel)$/.test(tourism)) return {category:'commercial',feature:tourism};
    if (landuse === 'retail' || /^(retail|mall|supermarket)$/.test(building)) return {category:'commercial',feature:'retail'};
    if (landuse === 'commercial' || building === 'commercial') return {category:'business',feature:'commercial'};
    if (office || building === 'office') return {category:'business',feature:'office'};
    if (landuse === 'industrial' || /^(industrial|warehouse)$/.test(building) || manMade === 'works' || tags.industrial) return {category:'business',feature:'industrial'};
    if (amenity === 'place_of_worship') return {category:'public',feature:'place_of_worship'};
    if (/^(parking|parking_entrance|bus_station|ferry_terminal|hospital|clinic|doctors|dentist|veterinary|school|university|college|kindergarten|library|townhall|courthouse|police|fire_station|post_office|community_centre|social_facility|arts_centre|events_venue|conference_centre)$/.test(amenity)) return {category:'public',feature:amenity};
    if (healthcare) return {category:'public',feature:healthcare};
    if (/^(station|halt|tram_stop|subway_entrance)$/.test(railway) || /^(station|platform)$/.test(publicTransport) || highway === 'bus_stop' || aeroway === 'terminal') return {category:'public',feature:'transport'};
    if (/^(park|playground|sports_centre|stadium|fitness_centre|pitch|swimming_pool|recreation_ground)$/.test(leisure)) return {category:'public',feature:leisure};
    if (/^(civic|public|school|hospital|university|college|train_station|transportation)$/.test(building)) return {category:'public',feature:building};
    if (tourism || historic) return {category:'public',feature:String(tourism || historic)};
    return null;
  }

  function shapeAreaScore(shapes) {
    let score=0;
    for (const s of shapes || []) if (s.type === 'Polygon') score += Math.abs(polygonSignedArea(s.coords));
    return score;
  }

  function siteShapeDistanceMeters(point,site) {
    let best=Infinity;
    for (const shape of site.shapes || []) {
      if (shape.type === 'Polygon' && pointInRing(point,shape.coords)) return 0;
      const coords=shape.coords || [];
      for (let i=1;i<coords.length;i++) best=Math.min(best,pointToSegmentMeters(point,coords[i-1],coords[i]));
      if (shape.type === 'Polygon' && coords.length>2) best=Math.min(best,pointToSegmentMeters(point,coords[coords.length-1],coords[0]));
    }
    return best;
  }

  function normalizeNearbyPoiElements(elements, dest) {
    const entrances=[];
    const communities=[];
    const places=[];
    const addresses=[];
    let roadDistanceM=Infinity;

    for (const el of elements || []) {
      const tags=el.tags || {};
      const shapes=communityShapes(el);
      const point=elementPoint(el,shapes);
      if (!point) continue;

      if (tags.highway && el.type==='way') {
        const roadCoords=geometryCoords(el.geometry);
        for (let i=1;i<roadCoords.length;i++) {
          roadDistanceM=Math.min(roadDistanceM,pointToSegmentMeters(dest,roadCoords[i-1],roadCoords[i]));
        }
      }
      const name=(tags['name:zh-Hant'] || tags['name:zh'] || tags.name || tags.official_name || tags['addr:housename'] || tags.alt_name || tags.short_name || tags.brand || tags.operator || '').trim();
      const polygons=shapes.filter(s=>s.type==='Polygon');
      const containsDestination=polygons.some(s=>pointInRing(dest,s.coords));
      const labelPoint=communityLabelPoint(shapes,point) || point;

      const entranceKind = tags.entrance === 'main' ? 'main' :
        (tags.barrier === 'gate' ? 'gate' : (tags.entrance ? 'entrance' : null));
      if (entranceKind) {
        entrances.push({
          lat:point.lat,lng:point.lng,kind:entranceKind,
          name:(tags.name || tags['name:zh'] || '').trim(),
          distance:haversineMeters(dest,point)
        });
      }

      if (tags['addr:housenumber']) {
        addresses.push({
          lat:point.lat,lng:point.lng,
          houseNumber:String(tags['addr:housenumber']).replace(/號$/,''),
          road:String(tags['addr:street'] || tags['addr:place'] || ''),
          containsDestination,
          distance:haversineMeters(dest,point)
        });
      }

      const cls=classifyPlaceTags(tags);
      if (!name || !cls) continue;
      const item={
        lat:point.lat,lng:point.lng,
        labelLat:labelPoint.lat,labelLng:labelPoint.lng,
        name,shapes,hasGeometry:shapes.length>0,containsDestination,
        category:cls.category,feature:cls.feature,
        areaScore:shapeAreaScore(shapes),
        distance:haversineMeters(dest,point)
      };
      if (cls.category === 'residential') communities.push(item);
      else places.push(item);
    }

    const dedupe=(items,distanceM,max) => {
      const out=[];
      for (const item of items.sort((a,b)=>Number(b.containsDestination)-Number(a.containsDestination)||a.distance-b.distance)) {
        if (out.some(x => (x.name && item.name && x.name === item.name && haversineMeters(x,item)<80) || haversineMeters(x,item)<distanceM)) continue;
        out.push(item);
        if (out.length>=max) break;
      }
      return out;
    };

    const dedupedCommunities=dedupe(communities,18,COMMUNITY_MAX_RESULTS);
    const dedupedPlaces=dedupe(places,10,PLACE_MAX_RESULTS);
    const allSites=[...dedupedCommunities,...dedupedPlaces];
    let dedupedEntrances=dedupe(entrances,4,ENTRANCE_MAX_RESULTS*3);

    function matchSiteForEntrance(ent) {
      let best=null,bestD=Infinity;
      for (const site of allSites) {
        const d=siteShapeDistanceMeters(ent,site);
        if (d < bestD) { best=site; bestD=d; }
      }
      // Only geometry-linked entrances count as belonging to a site. This
      // deliberately removes the old 90 m nearest-community guess.
      return bestD <= 18 ? best : null;
    }

    dedupedEntrances=dedupedEntrances.map(ent => {
      const site=matchSiteForEntrance(ent);
      return {
        ...ent,
        placeName:site?.name || '',
        communityName:site?.category==='residential' ? site.name : '',
        category:site?.category || 'unknown',
        feature:site?.feature || '',
        targetPlace:!!site?.containsDestination,
        targetCommunity:!!site?.containsDestination && site?.category==='residential'
      };
    }).filter(ent => ent.placeName || ent.targetPlace || ent.distance <= 70)
      .sort((a,b)=>Number(b.targetPlace)-Number(a.targetPlace)||a.distance-b.distance)
      .slice(0,ENTRANCE_MAX_RESULTS);

    const dedupedAddresses=dedupe(addresses,3,10);
    return {
      entrances:dedupedEntrances,
      communities:dedupedCommunities,
      places:dedupedPlaces,
      addresses:dedupedAddresses,
      roadDistanceM:Number.isFinite(roadDistanceM) ? roadDistanceM : null
    };
  }

  function nearbyDataUseful(data) {
    return !!((data?.communities||[]).some(x=>x.containsDestination||x.distance<=80) ||
      (data?.places||[]).some(x=>x.containsDestination||x.distance<=80) ||
      (data?.entrances||[]).some(x=>x.targetPlace||x.distance<=80));
  }

  function trimNearbyData(data,radiusM) {
    const keep=x=>!!x?.containsDestination || Number(x?.distance)<=radiusM;
    return {...data,
      communities:(data?.communities||[]).filter(keep),
      places:(data?.places||[]).filter(keep),
      entrances:(data?.entrances||[]).filter(x=>x?.targetPlace || Number(x?.distance)<=radiusM),
      addresses:(data?.addresses||[]).filter(keep)
    };
  }

  async function queryOverpassNearbyPoiAtRadius(dest,radiusM) {
    const q = `
[out:json][timeout:14];
(
  node["entrance"](around:${radiusM},${dest.lat},${dest.lng});
  node["barrier"="gate"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["addr:housenumber"](around:70,${dest.lat},${dest.lng});
  way["highway"](around:28,${dest.lat},${dest.lng});

  nwr["landuse"="residential"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["landuse"="residential"]["official_name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["landuse"="residential"]["addr:housename"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["residential"="apartments"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["residential"="apartments"]["addr:housename"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["building"~"^(apartments|residential|condominium|house|detached|terrace|semidetached_house)$"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["building"~"^(apartments|residential|condominium|house|detached|terrace|semidetached_house)$"]["addr:housename"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["building:use"="residential"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["building:use"="residential"]["addr:housename"](around:${radiusM},${dest.lat},${dest.lng});

  nwr["landuse"~"^(retail|commercial|industrial)$"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["building"~"^(retail|commercial|office|civic|public|industrial|warehouse|train_station|transportation)$"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["shop"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["shop"]["brand"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["amenity"~"^(restaurant|cafe|fast_food|food_court|bar|pub|bank|pharmacy|cinema|theatre|fuel|car_wash|nightclub|marketplace|parking|parking_entrance|place_of_worship|bus_station|ferry_terminal|hospital|clinic|doctors|dentist|veterinary|school|university|college|kindergarten|library|townhall|courthouse|police|fire_station|post_office|community_centre|social_facility|arts_centre|events_venue|conference_centre)$"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["office"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["tourism"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["healthcare"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["leisure"~"^(park|playground|sports_centre|stadium|fitness_centre|pitch|swimming_pool|recreation_ground)$"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["railway"~"^(station|halt|tram_stop|subway_entrance)$"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["public_transport"~"^(station|platform)$"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  node["highway"="bus_stop"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["aeroway"="terminal"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["man_made"="works"]["name"](around:${radiusM},${dest.lat},${dest.lng});
  nwr["historic"]["name"](around:${radiusM},${dest.lat},${dest.lng});
);
out body geom;
`.trim();

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 24000);
    try {
      const res = await fetch('/api/osm', {method:'POST',headers:{'Accept':'application/json','Content-Type':'text/plain;charset=UTF-8'},body:q,signal:controller.signal,cache:'no-store'});
      if (!res.ok) {const detail=await res.text().catch(()=>'');throw new Error(`OSM proxy HTTP ${res.status}${detail ? `: ${detail.slice(0,120)}` : ''}`);}
      const data=await res.json();
      return trimNearbyData(normalizeNearbyPoiElements(data.elements || [], dest),radiusM);
    } finally { clearTimeout(timer); }
  }

  async function queryOverpassNearbyPoi(dest) {
    const primary=await queryOverpassNearbyPoiAtRadius(dest,DESTINATION_PRIMARY_RADIUS_M);
    if (nearbyDataUseful(primary)) return primary;
    return await queryOverpassNearbyPoiAtRadius(dest,DESTINATION_FALLBACK_RADIUS_M);
  }

  function setOsmStatus(text, kind='') {
    if (!els.osmStatus) return;
    els.osmStatus.textContent = text;
    els.osmStatus.className = `osm-status ${kind}`.trim();
  }

  async function refreshNearbyEntrances(dest, {force=false}={}) {
    if (!dest) {
      clearNearbyPoiMarkers();
      setOsmStatus('OSM 待命');
      return;
    }

    const seq = ++state.entranceRequestSeq;
    const fresh = readNearbyPoiCache(dest);
    const stale = fresh || readNearbyPoiCache(dest, {allowStale:true});
    // Keep the best already-known result for this request. In v0.3.69 the
    // offline result was rendered and written to cache, but this local `stale`
    // snapshot stayed null. If the subsequent live Overpass supplement failed,
    // catch() cleared the just-rendered community polygons. Never let a network
    // refresh delete usable offline/local context.
    let fallbackData = stale;
    let fallbackSource = stale ? 'cache' : '';

    // Critical stability rule:
    // a fresh successful result is authoritative for this delivery pin.
    // Do NOT start a background refresh that can fail a few seconds later
    // and make the UI look as if panning/zooming "broke" the markers.
    if (fresh && !force) {
      renderNearbyPoiMarkers(fresh);
      await maybeApplySameSideDestinationCorrection(fresh);
      setOsmStatus(
        `OSM 社區 ${fresh.communities.length} / 場所 ${(fresh.places||[]).length} / 入口 ${fresh.entrances.length} / 命中 ${[...fresh.communities,...(fresh.places||[])].filter(x=>x.containsDestination).length}（快取）`,
        fresh.communities.length || (fresh.places||[]).length || fresh.entrances.length ? 'ok' : 'warn'
      );
      return;
    }

    // v0.3.26: the local pack contains the same OSM objects plus a structured
    // address index. Use it before any live Overpass request.
    if (!force) {
      try {
        const local=await offlineNearbyData(dest);
        if (seq!==state.entranceRequestSeq) return;
        if (local.available && local.data) {
          writeNearbyPoiCache(dest,local.data);
          fallbackData=local.data;
          fallbackSource='offline';
          renderNearbyPoiMarkers(local.data);
          await maybeApplySameSideDestinationCorrection(local.data);
          setOsmStatus(`離線 社區 ${local.data.communities.length} / 場所 ${(local.data.places||[]).length} / 入口 ${local.data.entrances.length} / 門牌 ${local.officialAddresses||local.data.addresses.length}${local.complete?'':'（部分覆蓋）'}`,local.complete?'ok':'warn');
          if (local.complete) return;
        }
      } catch (offlineErr) { console.warn('offline nearby data unavailable',offlineErr); }
    }

    if (fallbackData) {
      renderNearbyPoiMarkers(fallbackData);
      const prefix=fallbackSource==='offline'?'離線':'OSM 快取';
      setOsmStatus(
        `${prefix} 社區 ${fallbackData.communities.length} / 場所 ${(fallbackData.places||[]).length} / 入口 ${fallbackData.entrances.length} / 命中 ${[...fallbackData.communities,...(fallbackData.places||[])].filter(x=>x.containsDestination).length}｜線上補抓中`,
        'warn'
      );
    } else {
      setOsmStatus('OSM 查詢中…', 'warn');
    }

    try {
      const data = await queryOverpassNearbyPoi(dest);
      if (seq !== state.entranceRequestSeq) return;

      writeNearbyPoiCache(dest, data);
      renderNearbyPoiMarkers(data);
      await maybeApplySameSideDestinationCorrection(data);
      setOsmStatus(
        `OSM 社區 ${data.communities.length} / 場所 ${(data.places||[]).length} / 入口 ${data.entrances.length} / 命中 ${[...data.communities,...(data.places||[])].filter(x=>x.containsDestination).length}`,
        data.communities.length || (data.places||[]).length || data.entrances.length ? 'ok' : 'warn'
      );

      const bits = [];
      if (data.communities.length) bits.push(`${data.communities.length} 個社區/大樓`);
      if ((data.places||[]).length) bits.push(`${data.places.length} 個店家/場所`);
      if (data.entrances.length) bits.push(`${data.entrances.length} 個入口`);
      if (bits.length) toast(`附近找到 ${bits.join('、')}`);
    } catch (err) {
      if (seq !== state.entranceRequestSeq) return;

      if (fallbackData) {
        // Keep the result that was actually rendered during THIS refresh,
        // including a partial offline destination tile. v0.3.69 only checked
        // the cache snapshot taken before offline loading and could therefore
        // erase valid community polygons after a live timeout.
        renderNearbyPoiMarkers(fallbackData);
        const prefix=fallbackSource==='offline'?'離線':'OSM 快取';
        setOsmStatus(
          `${prefix} 社區 ${fallbackData.communities.length} / 場所 ${(fallbackData.places||[]).length} / 入口 ${fallbackData.entrances.length} / 命中 ${[...fallbackData.communities,...(fallbackData.places||[])].filter(x=>x.containsDestination).length}（線上更新失敗，已保留）`,
          'warn'
        );
      } else {
        clearNearbyPoiMarkers();
        setOsmStatus('OSM 查詢失敗（點此重試）', 'bad');
      }
      console.warn('nearby OSM hints unavailable', err);
    }
  }

  function rawDestinationFromQuery() {
    const q=new URLSearchParams(location.search);
    return parseDestination(q.get('rawDest'));
  }

  function storedDestinationMeta() {
    try {
      const value=JSON.parse(localStorage.getItem('581-door-dest-meta') || 'null');
      return value && typeof value==='object' ? value : null;
    } catch (_) {
      return null;
    }
  }

  function restoreDestinationContext(effective,{preferQueryRaw=false}={}) {
    if (!effective) return;
    let raw=preferQueryRaw ? rawDestinationFromQuery() : null;
    let meta=null;

    const storedEffective=parseDestination(localStorage.getItem('581-door-dest'));
    const sameStored=storedEffective && haversineMeters(storedEffective,effective)<=3;
    if (!raw && sameStored) raw=parseDestination(localStorage.getItem('581-door-dest-raw'));
    if (sameStored || raw) meta=storedDestinationMeta();

    if (meta) {
      state.destinationIntent={...meta};
      state.destinationInfo={...destinationIntentInfo(meta),...(state.destinationInfo || {})};
      // Prefer explicit Google target text over a nearest-road reverse guess.
      const intent=destinationIntentInfo(meta);
      if (intent.houseNumber || intent.placeName) {
        state.destinationInfo={...(state.destinationInfo || {}),...intent};
      }
      updateDestinationInfoUi();
    }

    if (raw) {
      state.rawDestination=raw;
      const moved=haversineMeters(raw,effective);
      if (moved>=DESTINATION_CORRECTION_MIN_M) {
        state.destinationCorrection={
          applied:true,
          source:'restored-address-side',
          distanceM:moved,
          checked:true
        };
      }
    }
  }

  async function fetchLatestOcrDestination({apply=true,fit=true,silent=false}={}) {
    try {
      const res=await fetch(`/api/dest-sync/latest?ts=${Date.now()}`,{
        method:'GET',headers:{'Accept':'application/json'},cache:'no-store'
      });
      if (res.status===404) return null;
      if (!res.ok) throw new Error(`dest-sync HTTP ${res.status}`);
      const data=await res.json();
      const lat=Number(data?.lat),lng=Number(data?.lng),updatedAt=Number(data?.updatedAt);
      if (!Number.isFinite(lat)||!Number.isFinite(lng)||lat<20||lat>27||lng<117||lng>123) {
        throw new Error('dest-sync invalid point');
      }
      if (!Number.isFinite(updatedAt) || Date.now()-updatedAt>10*60*1000) return null;
      if (!apply || updatedAt<=Number(state.destSyncLastAppliedAt || 0)) return {lat,lng,updatedAt};

      state.destSyncLastAppliedAt=updatedAt;
      localStorage.setItem('581-door-dest-sync-applied-at',String(updatedAt));
      state.destinationHandoffSource='ocr-sync';
      setDestination({lat,lng},{fit,persist:true,stableUrl:true});
      if (!silent) toast('OCR 目的地已同步');
      return {lat,lng,updatedAt};
    } catch (err) {
      console.warn('OCR dest-sync read failed',err);
      return null;
    }
  }

  function scheduleOcrDestSyncBurst(reason='resume') {
    const seq=++state.destSyncPollSeq;
    if (state.destSyncPollTimer) clearTimeout(state.destSyncPollTimer);
    const delays=[0,450,1200,2600,4800,8000];
    let i=0;
    const run=async()=>{
      if (seq!==state.destSyncPollSeq) return;
      await fetchLatestOcrDestination({apply:true,fit:true,silent:i>0});
      i++;
      if (i<delays.length && seq===state.destSyncPollSeq) {
        state.destSyncPollTimer=setTimeout(run,Math.max(150,delays[i]-delays[i-1]));
      }
    };
    run();
  }

  async function loadInitialDestination() {
    // Hash handoff is intentionally first. It lets the Shortcut update the
    // currently-open Door Map without a document reload, preserving compass/GPS.
    if (await consumeHashDestinationHandoff({fit:true})) return;

    const fromQuery = destinationFromQuery();
    if (fromQuery) {
      setDestination(fromQuery, {fit:false,persist:false});
      restoreDestinationContext(fromQuery,{preferQueryRaw:true});
      // Native deep links start a fresh document with ?dest=. Save the accepted
      // target AFTER restoring its original pin context, BEFORE removing query.
      // Otherwise the next reload remembers FIT but has no destination to fit.
      try {
        localStorage.setItem('581-door-dest', `${state.destination.lat},${state.destination.lng}`);
        const raw=state.rawDestination || state.destination;
        localStorage.setItem('581-door-dest-raw', `${raw.lat},${raw.lng}`);
        if(state.destinationIntent)localStorage.setItem('581-door-dest-meta',JSON.stringify(state.destinationIntent));
        else localStorage.removeItem('581-door-dest-meta');
      } catch (_) {}
      stabilizeBrowserUrl();
      return;
    }

    const gmap = googleShareFromQuery();
    if (gmap) {
      const seq=++state.destinationHandoffSeq;
      state.destinationHandoffBusy=true;
      state.destinationHandoffSource='query';
      try {
        toast('正在同步 Google Maps Pin…');
        const d = await resolveGoogleMapsShareRobust(gmap,3);
        if (seq!==state.destinationHandoffSeq) return;
        setDestination(d, {fit:true,persist:true});
        toast(d.__sourceMeta?.notice||'Google Maps Pin 已同步');
        return;
      } catch (err) {
        console.warn('gmap query import failed', err);
        toast(`Google Maps 分享連結解析失敗：${String(err?.message || err)}`);
      } finally {
        if (seq===state.destinationHandoffSeq) state.destinationHandoffBusy=false;
        // Query-mode is kept for backward compatibility, but normalize the live
        // tab afterwards so the next #gmap handoff can be fragment-only.
        stabilizeBrowserUrl();
      }
    }

    // Current production Shortcut is OCR -> /api/dest-sync/... . Read that
    // mailbox before falling back to an old locally cached destination.
    const synced=await fetchLatestOcrDestination({apply:true,fit:true,silent:true});
    if (synced) {
      stabilizeBrowserUrl();
      return;
    }

    const fromStorage = parseDestination(localStorage.getItem('581-door-dest'));
    if (fromStorage) {
      setDestination(fromStorage, {fit:false,persist:false,stableUrl:true});
      restoreDestinationContext(fromStorage);
    }
    stabilizeBrowserUrl();
  }

  function refreshRouteWaitingStatus() {
    if (!state.routeEnabled) return;
    if (routeCoordinates().length >= 2) return;
    if (!state.position && !state.destination) {
      // IMPORTANT: this must be a status update, never a recursive self-call.
      // v0.3.10-v0.3.14 accidentally recursed here. requestOneShotLocation()
      // calls this BEFORE navigator.geolocation.getCurrentPosition(), so the
      // recursion prevented Safari geolocation from being invoked at all when
      // the page opened without a destination, while leaving the UI stuck on
      // "定位中…" / "正在向 Safari 取得定位…".
      setRouteStatus('導航：等待 GPS / 目的地','warn');
    } else if (!state.position) {
      setRouteStatus('導航：等待 GPS','warn');
    } else if (!state.destination) {
      setRouteStatus('導航：等待目的地','warn');
    } else {
      setRouteStatus('導航：準備規劃路線…','warn');
    }
  }

  function setRouteEnabled(enabled, {persist=true,request=true}={}) {
    state.routeEnabled = !!enabled;
    if (persist) localStorage.setItem('581-door-route-enabled-v2', state.routeEnabled ? '1' : '0');
    if (els.routeVisibilityBtn) {
      els.routeVisibilityBtn.classList.toggle('active', state.routeEnabled);
      els.routeVisibilityBtn.setAttribute('aria-pressed', state.routeEnabled ? 'true' : 'false');
      els.routeVisibilityBtn.title = state.routeEnabled ? '關閉導航路線' : '開啟導航路線';
    }

    if (!state.routeEnabled) {
      if(state.fitLocked)stopFitLock('route-off');
      state.routeRequestSeq++;clearDeliveryPreview(false);
      state.areaRoutePhase='idle';state.areaRouteIds=[];state.areaRouteExempt=[];
      state.routeGeoJson = emptyFeatureCollection();
      state.routeDisplayGeoJson = emptyFeatureCollection();
      state.routeProgressIndex = 0;
      state.alternateRoutes = [];
      state.alternateRouteGeoJson = emptyFeatureCollection();
      state.routeDistance = null;
      state.routeDuration = null;
      state.routeManeuvers=[];state.routeCandidateCount=0;
      state.routeDeviationCount = 0;
      state.rerouteHeadingMismatchCount = 0;
      state.rerouteArmedTurn = null;
      state.navigationActive = false;
      state.navigationRequested = false;
      syncNavigationUi();
      submitSceneData(map,'reference-route',state.routeDisplayGeoJson);
      map.getSource('alternate-routes')?.setData(state.alternateRouteGeoJson);
      setRouteStatus('導航：關閉');
      updateDistance();
      updateGuideLine();
      return;
    }

    setRouteStatus('導航：等待 GPS / 目的地','warn');
    if (request) {
      state.autoFitRoutePending = true;
      requestRoute({force:true});
    }
  }

  function routeResponseRecord(data) {
    const geometry=data?.geometry?.type === 'Feature' ? data.geometry.geometry : data?.geometry;
    if (!geometry || geometry.type !== 'LineString' || !Array.isArray(geometry.coordinates) || geometry.coordinates.length < 2) return null;
    return {geometry,distance:Number(data.distance),duration:Number(data.duration),routingPolicy:data.routingPolicy,avoidApplied:data.avoidApplied,endpointExempt:data.endpointExempt,maneuvers:Array.isArray(data.maneuvers)?data.maneuvers:[],turnCount:Number(data.turnCount)||0,score:Number(data.score)||Number(data.duration)||0,label:String(data.label||'')};
  }

  function routeOverlapRatio(a,b) {
    const ac=a?.geometry?.coordinates || [], bc=b?.geometry?.coordinates || [];
    if (ac.length<2 || bc.length<2) return 1;
    const step=Math.max(1,Math.floor(ac.length/24));
    let total=0,close=0;
    for (let i=0;i<ac.length;i+=step) {
      total++;
      const p={lng:ac[i][0],lat:ac[i][1]};
      let best=Infinity;
      for (let j=1;j<bc.length;j++) {
        best=Math.min(best,pointToSegmentMeters(p,bc[j-1],bc[j]));
        if (best<24) break;
      }
      if (best<34) close++;
    }
    return total ? close/total : 1;
  }

  function rebuildAlternateRouteGeoJson() {
    state.alternateRouteGeoJson={
      type:'FeatureCollection',
      features:(state.alternateRoutes || []).map((r,index)=>({
        type:'Feature',
        properties:{altIndex:index,distance:r.distance,duration:r.duration},
        geometry:r.geometry
      }))
    };
    map.getSource('alternate-routes')?.setData(state.alternateRouteGeoJson);
  }

  function fetchRouteRequest(u,signal){
    if(u.searchParams.has('via')||u.searchParams.has('areas')){
      const body={from:u.searchParams.get('from'),to:u.searchParams.get('to'),variant:u.searchParams.get('variant')||'main',alternatives:Number(u.searchParams.get('alternatives'))||0,via:JSON.parse(u.searchParams.get('via')||'[]'),areas:JSON.parse(u.searchParams.get('areas')||'[]')};
      return fetch(new URL('/api/route',location.origin),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),cache:'no-store',signal});
    }
    return fetch(u,{cache:'no-store',signal});
  }

  async function fetchRouteVariant(from,to,variant,options=deliveryRequestOptions(),signal=null) {
    const u=new URL('/api/route',location.origin);
    u.searchParams.set('from',from); u.searchParams.set('to',to); u.searchParams.set('variant',variant);
    if(options.via?.length)u.searchParams.set('via',JSON.stringify(options.via));
    if(options.areas?.length)u.searchParams.set('areas',JSON.stringify(options.areas));
    const ac=new AbortController(),timeout=setTimeout(()=>ac.abort(),14000),onAbort=()=>ac.abort();
    signal?.addEventListener('abort',onAbort,{once:true});if(signal?.aborted)onAbort();
    try{
      const res=await fetchRouteRequest(u,ac.signal);
      if(!res.ok)throw new Error(`路線 ${res.status}：${(await res.text()).slice(0,160)}`);
      const rec=routeResponseRecord(await res.json());
      if(!rec||!Number.isFinite(rec.distance)||!Number.isFinite(rec.duration))throw new Error('路線資料不完整');
      const check=window.DoorDelivery?.constraintsOK(rec.geometry.coordinates,options.via,options.areas)||{ok:true};
      if(!check.ok)throw new Error(check.reason);
      rec.avoidExemptIds=options.endpointExemptIds||[];
      return rec;
    }finally{clearTimeout(timeout);signal?.removeEventListener('abort',onAbort);}
  }

  async function fetchRouteSet(from,to,options=deliveryRequestOptions(),signal=null) {
    const u=new URL('/api/route',location.origin);
    u.searchParams.set('from',from);u.searchParams.set('to',to);u.searchParams.set('variant','main');u.searchParams.set('alternatives','2');
    if(options.via?.length)u.searchParams.set('via',JSON.stringify(options.via));
    if(options.areas?.length)u.searchParams.set('areas',JSON.stringify(options.areas));
    const ac=new AbortController(),timeout=setTimeout(()=>ac.abort(),14000),onAbort=()=>ac.abort();
    signal?.addEventListener('abort',onAbort,{once:true});if(signal?.aborted)onAbort();
    try{
      const res=await fetchRouteRequest(u,ac.signal);
      if(!res.ok)throw new Error(`路線 ${res.status}：${(await res.text()).slice(0,160)}`);
      const data=await res.json(),raw=Array.isArray(data?.routes)?data.routes:[];
      const routes=[];
      for(const item of raw){
        const rec=routeResponseRecord(item);if(!rec||!Number.isFinite(rec.distance)||!Number.isFinite(rec.duration))continue;
        const check=window.DoorDelivery?.constraintsOK(rec.geometry.coordinates,options.via,options.areas)||{ok:true};if(!check.ok)continue;
        rec.avoidExemptIds=options.endpointExemptIds||[];
        if(routes.some(x=>routeOverlapRatio(rec,x)>0.93&&routeOverlapRatio(x,rec)>0.93))continue;
        routes.push(rec);if(routes.length>=3)break;
      }
      if(!routes.length)throw new Error('路線資料不完整');
      return {routes,routeStatus:data?.routeStatus||null};
    }finally{clearTimeout(timeout);signal?.removeEventListener('abort',onAbort);}
  }

  function acceptDeliveryRoute(main,seq,requestOrigin,alternates=[]) {
    if(seq!==state.routeRequestSeq || !state.routeEnabled)return false;
    clearDeliveryPreview(false,{keepManager:true});
    state.areaRoutePhase='ready';state.areaRouteIds=Array.isArray(main.avoidApplied)?main.avoidApplied.slice():[];
    state.areaRouteExempt=Array.isArray(main.endpointExempt)?main.endpointExempt.slice():[];
    state.areaRouteExemptIds=Array.isArray(main.avoidExemptIds)?main.avoidExemptIds.slice():[];
    state.routeGeoJson={type:'FeatureCollection',features:[{type:'Feature',properties:{},geometry:main.geometry}]};
    state.routeDisplayGeoJson=state.routeGeoJson;
    // A route result updates an existing source immediately; do not wait for unrelated tile/glyph loading.
    submitSceneData(map,'reference-route',state.routeDisplayGeoJson);
    state.routeProgressIndex=0;
    state.routeDistance=main.distance;
    state.routeDuration=main.duration;
    const coords=main.geometry.coordinates||[];
    state.routeManeuvers=(main.maneuvers||[]).map(m=>{
      const p=Array.isArray(m.location)?{lng:Number(m.location[0]),lat:Number(m.location[1])}:null;
      const routeIndex=p&&Number.isFinite(p.lng)&&Number.isFinite(p.lat)?nearestRouteSegment(p,coords).index:0;
      return {...m,routeIndex};
    });
    state.alternateRoutes=(alternates||[]).filter(Boolean).slice(0,ROUTE_ALTERNATE_MAX);
    state.routeCandidateCount=1+state.alternateRoutes.length;
    state.alternateRouteGeoJson=emptyFeatureCollection();
    rebuildAlternateRouteGeoJson();
    state.routeLastOrigin={...requestOrigin};
    state.routeDeviationCount=0;
    state.rerouteHeadingMismatchCount=0;
    state.rerouteArmedTurn=null;
    scheduleMainSceneSync('route-success',0);
    buildings3d?.queue();
    map.triggerRepaint?.();

    setRouteStatus(state.routeCandidateCount>1?`導航：${state.routeCandidateCount} 條機車路線 · 點淡線切換`:'導航：機車路線已更新','ok');
    updateDistance();
    updateGuideLine();
    updateInsetTitle();
    markViaPositions();

    if(!(typeof planner==='undefined'?null:planner)?.editing)fitRouteAccepted();
    state.cameraRestorePending=false;
    (typeof planner==='undefined'?null:planner)?.sync();
    if(!state.fitLocked && state.navigationRequested && !state.cameraUserOverride) {
      state.navigationActive=true;
      state.following=true;
      syncCameraControls();
      followCamera({force:true});
    }

    if(state.autoFitRoutePending) {
      state.autoFitRoutePending=false;
      requestAnimationFrame(()=>requestAnimationFrame(()=>{
        if(!state.cameraUserOverride && !state.navigationRequested) showRouteOverview({duration:600});
      }));
    }
    return true;
  }

  async function requestRoute({force=false}={}) {
    if((typeof planner==='undefined'?null:planner)?.editing)return;
    if (!state.routeEnabled || !state.position || !state.destination) return;
    globalThis.DoorPowerDiag?.mark?.('routeRequest');
    const now=Date.now();
    if(!force && now-state.routeRequestedAt<ROUTE_MIN_REROUTE_INTERVAL_MS) return;
    clearDeliveryPreview(false,{keepManager:true});
    const seq=++state.routeRequestSeq;
    state.routeRequestedAt=now;
    const requestOrigin={lat:state.position.lat,lng:state.position.lng};
    const from=`${state.position.lng.toFixed(6)},${state.position.lat.toFixed(6)}`;
    const to=`${state.destination.lng.toFixed(6)},${state.destination.lat.toFixed(6)}`;
    const options=deliveryRequestOptions(),revision=state.deliveryRevision;
    state.areaRoutePhase='pending';state.areaRouteIds=[];state.areaRouteExempt=options.endpointExempt.slice();
    syncDeliveryMap();
    if(state.fitLocked){state.fitRouteWaiting=true;syncFitUi();}
    deliveryMessage(options.endpointExempt.length?`起終點／途經點在避開區附近，該區本次放行：${options.endpointExempt.join('、')}`:
      options.overflow?`本次套用 ${options.areas.length} 區；另 ${options.overflow} 區未套用`:
      options.areas.length?`本次避開 ${options.areas.length} 個自訂區域`:'');
    setRouteStatus('導航：規劃機車路線中…','warn');
    try{
      // Explicit via/avoid is already a rider decision: keep one deterministic route.
      // Ordinary destination planning asks Valhalla once for up to 3 legal alternatives,
      // then ranks them for fewer unnecessary turns instead of firing 3 independent requests.
      let main,alternates=[];
      if(options.via.length||options.areas.length){
        main=await fetchRouteVariant(from,to,'main',options);
      }else{
        const set=await fetchRouteSet(from,to,options);
        if(seq!==state.routeRequestSeq)return;
        main=set.routes[0];alternates=set.routes.slice(1,3);state.routeDataStatus=set.routeStatus||state.routeDataStatus;
      }
      if(seq!==state.routeRequestSeq)return;
      if(typeof planner!=='undefined'&&planner){const chosen=await planner.preferred(main,alternates,from,to,options,()=>seq===state.routeRequestSeq&&revision===state.deliveryRevision);main=chosen.main;alternates=chosen.alternates;}
      if(seq!==state.routeRequestSeq)return;
      if(revision!==state.deliveryRevision){state.fitRouteWaiting=false;requestRoute({force:true});return;}
      acceptDeliveryRoute(main,seq,requestOrigin,alternates);
    }catch(err){
      if(seq!==state.routeRequestSeq)return;
      state.fitRouteWaiting=false;if(state.fitLocked)syncFitUi();
      state.areaRoutePhase='failed';syncDeliveryMap();
      setRouteStatus('導航：路線暫時失敗；原目的地保留','bad');
      deliveryMessage(`未套用新路線：${String(err?.message||err).slice(0,150)}`);
    }
  }

  function promoteAlternateRoute(index) {
    if((typeof planner==='undefined'?null:planner)?.editing)return;
    const alt=state.alternateRoutes?.[index];
    if (!alt) return;
    state.routeRequestSeq++;clearDeliveryPreview(false);
    const current={
      geometry:state.routeGeoJson?.features?.[0]?.geometry,
      distance:state.routeDistance,
      duration:state.routeDuration,
      maneuvers:state.routeManeuvers
    };
    state.routeGeoJson={type:'FeatureCollection',features:[{type:'Feature',properties:{},geometry:alt.geometry}]};
    state.routeDisplayGeoJson=state.routeGeoJson;
    // A route result updates an existing source immediately; do not wait for unrelated tile/glyph loading.
    submitSceneData(map,'reference-route',state.routeDisplayGeoJson);
    state.routeProgressIndex=0;
    state.routeDistance=alt.distance;
    state.routeDuration=alt.duration;
    const coords=alt.geometry?.coordinates||[];
    state.routeManeuvers=(alt.maneuvers||[]).map(m=>{const p=Array.isArray(m.location)?{lng:Number(m.location[0]),lat:Number(m.location[1])}:null;return {...m,routeIndex:p?nearestRouteSegment(p,coords).index:0};});
    const next=state.alternateRoutes.filter((_,i)=>i!==index);
    if (current.geometry) next.unshift(current);
    state.alternateRoutes=next.slice(0,ROUTE_ALTERNATE_MAX);
    rebuildAlternateRouteGeoJson();
    submitSceneData(map,'reference-route',state.routeDisplayGeoJson);
    map.getSource('alternate-routes')?.setData(state.alternateRouteGeoJson);
    updateDistance();
    updateGuideLine();
    if(state.fitLocked)fitRouteAccepted();
    updateInsetTitle();
    setRouteStatus(`導航：已切換路線 · 尚有 ${state.alternateRoutes.length} 條可選`,'ok');
    (typeof planner==='undefined'?null:planner)?.remember(current,alt,'alternative');
    (typeof planner==='undefined'?null:planner)?.sync();
    toast('已切換備選路線');
  }

  function routeCoordinates() {
    return state.routeGeoJson?.features?.[0]?.geometry?.coordinates || [];
  }

  function pointToSegmentMeters(point, a, b) {
    const lat0 = point.lat * Math.PI/180;
    const sx = 111320 * Math.max(0.15,Math.cos(lat0));
    const sy = 111320;
    const px = point.lng*sx, py = point.lat*sy;
    const ax = a[0]*sx, ay = a[1]*sy;
    const bx = b[0]*sx, by = b[1]*sy;
    const vx=bx-ax, vy=by-ay, wx=px-ax, wy=py-ay;
    const vv=vx*vx+vy*vy;
    const t=vv>0 ? Math.max(0,Math.min(1,(wx*vx+wy*vy)/vv)) : 0;
    const dx=px-(ax+t*vx), dy=py-(ay+t*vy);
    return Math.hypot(dx,dy);
  }

  function distanceToRouteMeters(point) {
    const coords = routeCoordinates();
    if (!point || coords.length < 2) return Infinity;
    let best = Infinity;
    for (let i=1;i<coords.length;i++) {
      best = Math.min(best, pointToSegmentMeters(point,coords[i-1],coords[i]));
      if (best < 8) break;
    }
    return best;
  }

  function nearestRouteSegment(point, coords=routeCoordinates()) {
    if (!point || coords.length<2) return {distance:Infinity,index:0};
    let best=Infinity,bestIndex=0;
    for (let i=1;i<coords.length;i++) {
      const d=pointToSegmentMeters(point,coords[i-1],coords[i]);
      if (d<best) {best=d;bestIndex=i-1;}
    }
    return {distance:best,index:bestIndex};
  }

  function handleMapLongPress(point){
    if((typeof planner==='undefined'?null:planner)?.editing || !window.DoorDelivery.point(point))return;
    state.deliveryLongPressAt=Date.now();
    state.deliveryPicked={lat:point.lat,lng:point.lng};
    openAvoidAreaEditor();
  }

  
  function routeDisplayCoordinates() {
    return state.routeDisplayGeoJson?.features?.[0]?.geometry?.coordinates || [];
  }

  function progressProjection(point, coords) {
    if (!point || !Array.isArray(coords) || coords.length < 2) return null;
    const cursor=Math.max(0,Math.min(coords.length-2,Number(state.routeProgressIndex||0)));
    const localStart=Math.max(0,cursor-3);
    const localEnd=Math.min(coords.length-2,cursor+120);
    let best=null;
    const scan=(a,b)=>{
      for(let i=a;i<=b;i++){
        const p=segmentProjection(point,coords[i],coords[i+1]);
        if(!best || p.distance<best.distance){
          best={...p,index:i,coord:[
            coords[i][0]+p.t*(coords[i+1][0]-coords[i][0]),
            coords[i][1]+p.t*(coords[i+1][1]-coords[i][1])
          ]};
        }
      }
    };
    scan(localStart,localEnd);
    if (best && best.distance<=65) return best;
    if (localEnd<coords.length-2) scan(localEnd+1,coords.length-2);
    return best;
  }

  function advanceRouteProjection(projection,coords,meters) {
    if(!projection||!Array.isArray(coords)||coords.length<2||!Number.isFinite(meters)||meters<=0)return null;
    let idx=Math.max(0,Math.min(coords.length-2,Number(projection.index)||0));
    let current=Array.isArray(projection.coord)?projection.coord.slice():coords[idx].slice();
    let remain=Math.max(0,meters);
    while(remain>0&&idx<coords.length-1){
      const end=coords[idx+1];
      const seg=haversineMeters({lng:current[0],lat:current[1]},{lng:end[0],lat:end[1]});
      if(!Number.isFinite(seg)||seg<.05){current=end.slice();idx++;continue;}
      if(remain<seg){const t=remain/seg;return {lng:current[0]+(end[0]-current[0])*t,lat:current[1]+(end[1]-current[1])*t};}
      remain-=seg;current=end.slice();idx++;
    }
    return {lng:current[0],lat:current[1]};
  }

  function navigationDisplayPosition(raw,speedMps=null) {
    if(!raw)return raw;
    const riding=state.routeEnabled&&(state.navigationRequested||state.navigationActive||state.fitLocked);
    if(!riding){state.displayLeadMeters=0;return {...raw};}
    const coords=routeCoordinates();
    if(coords.length<2){state.displayLeadMeters=0;return {...raw};}
    const projection=progressProjection(raw,coords);
    const accuracy=Math.max(0,Number(raw.accuracy)||0);
    const maxSnap=Math.max(18,Math.min(45,accuracy*1.5||18));
    if(!projection||projection.distance>maxSnap){state.displayLeadMeters=0;return {...raw};}
    const speed=Math.max(0,Number(speedMps)||0);
    let wanted=speed>=1.2?Math.min(10,1.5+speed*.65):0;
    if(accuracy>30)wanted*=.5;
    if(accuracy>50)wanted=0;
    const previous=Math.max(0,Number(state.displayLeadMeters)||0);
    let lead=speed>=1.2?(previous*.30+wanted*.70):(previous*.82);
    if(accuracy>50)lead=0;
    const maneuver=nextRouteManeuver(raw);
    if(maneuver&&Number.isFinite(maneuver.meters)&&maneuver.meters<80)lead=Math.min(lead,Math.max(0,maneuver.meters-1.5));
    if(state.destination){const d=haversineMeters(raw,state.destination);if(Number.isFinite(d))lead=Math.min(lead,Math.max(0,d-1.5));}
    lead=Math.max(0,Math.min(10,lead));state.displayLeadMeters=lead;
    if(lead<.35)return {...raw};
    const advanced=advanceRouteProjection(projection,coords,lead);
    return advanced?{...raw,lng:advanced.lng,lat:advanced.lat,displayLeadMeters:lead}:{...raw};
  }

  function updateRouteProgressDisplay() {
    // A FIT-locked overview is a live riding view even when the ordinary
    // navigation button was never toggled on. Only non-FIT preview/edit modes
    // are allowed to keep the complete historical route.
    if((typeof planner==='undefined'?null:planner)?.editing || (state.navigationRequested===false && !state.fitLocked)){
      state.routeDisplayGeoJson=state.routeGeoJson || emptyFeatureCollection();
      submitSceneData(map,'reference-route',state.routeDisplayGeoJson);
      return;
    }
    const coords=routeCoordinates();
    if (!state.position || coords.length<2) {
      state.routeDisplayGeoJson=state.routeGeoJson || emptyFeatureCollection();
      submitSceneData(map,'reference-route',state.routeDisplayGeoJson);
      return;
    }

    const priorIndex=Math.max(0,Math.min(coords.length-2,Number(state.routeProgressIndex||0)));
    const p=progressProjection(state.position,coords);
    if (!p || p.distance>140) return;

    // GPS can briefly snap to one of the few segments behind the monotonic cursor.
    // Never let that resurrect an already-travelled route tail on screen.
    const displayIndex=Math.max(priorIndex,p.index);
    let displayProjection=p;
    if(displayIndex!==p.index){
      const q=segmentProjection(state.position,coords[displayIndex],coords[displayIndex+1]);
      if(q.distance>140)return; // keep the last trimmed display rather than moving backwards
      displayProjection={...q,index:displayIndex,coord:[
        coords[displayIndex][0]+q.t*(coords[displayIndex+1][0]-coords[displayIndex][0]),
        coords[displayIndex][1]+q.t*(coords[displayIndex+1][1]-coords[displayIndex][1])
      ]};
    }
    state.routeProgressIndex=displayIndex;

    let remaining=[displayProjection.coord,...coords.slice(displayIndex+1)];
    if (state.destination && haversineMeters(state.position,state.destination)<=12) remaining=[];

    state.routeDisplayGeoJson={
      type:'FeatureCollection',
      features:remaining.length>=2 ? [{type:'Feature',properties:{remaining:true},geometry:{type:'LineString',coordinates:remaining}}] : []
    };
    submitSceneData(map,'reference-route',state.routeDisplayGeoJson,[state.routeGeoJson,coords,displayIndex,displayProjection.coord[0],displayProjection.coord[1],remaining.length]);
    updateQuickRouteMetrics();
    updateInsetTitle();
  }

  function nearDestinationZoom(meters) {
    const m=Number(meters);
    if (!Number.isFinite(m)) return null;
    // Automatic arrival retains the surrounding street/buildings. Only a
    // user's pinch may enter the NLSC close-up (19.35+). Not a map zoom limit.
    if (m<=150) return 19.10;
    if (m<=300) return 18.5;
    if (m<=600) return 17.7;
    if (m<=1200) return 16.9;
    return null;
  }

  function turnApproachZoom(turnMeters) {
    const t=Number(turnMeters);
    if(!Number.isFinite(t) || t>250) return null;
    if(t<=30) return 18.85;   // stay below NLSC zoom-19 gate during normal turns
    if(t<=80) return 18.35;
    if(t<=150) return 17.75;
    return 17.15;
  }

  function rerouteHeading() {
    if(Number.isFinite(state.gpsCourse)) return state.gpsCourse;
    if(Number.isFinite(state.position?.heading)) return state.position.heading;
    return Number.isFinite(state.displayHeading) ? state.displayHeading : null;
  }

  function routeSegmentBearingAt(index,coords=routeCoordinates()) {
    if(!Array.isArray(coords) || coords.length<2) return null;
    const i=Math.max(0,Math.min(coords.length-2,Number(index)||0));
    return bearingBetween({lng:coords[i][0],lat:coords[i][1]},{lng:coords[i+1][0],lat:coords[i+1][1]});
  }

  function maybeAutoReroute() {
    if((typeof planner==='undefined'?null:planner)?.editing)return;
    if (!state.routeEnabled || !state.position || !state.destination) return;
    const coords=routeCoordinates();
    if(coords.length<2) {
      if(!state.routeLastOrigin) state.autoFitRoutePending=true;
      requestRoute();
      return;
    }

    const accuracy=Math.max(0,Number(state.position.accuracy)||0);
    const deviation=distanceToRouteMeters(state.position);
    const soft=Math.max(ROUTE_REROUTE_DEVIATION_M,accuracy*1.35);
    const hard=Math.max(ROUTE_HARD_DEVIATION_M,accuracy*2.0);

    // Arm a real upcoming maneuver. Missing it can bypass the normal cooldown.
    const preview=routeCameraPreview();
    if(preview?.turnMeters<=65 && preview.turnCoord && Number.isFinite(preview.turnBearingAfter)) {
      state.rerouteArmedTurn={
        coord:preview.turnCoord.slice(),
        bearingAfter:preview.turnBearingAfter,
        armedAt:Date.now()
      };
    }

    const heading=rerouteHeading();
    let missedTurn=false;
    if(state.rerouteArmedTurn) {
      const a=state.rerouteArmedTurn;
      const away=haversineMeters(state.position,{lng:a.coord[0],lat:a.coord[1]});
      const mismatch=Number.isFinite(heading)
        ? Math.abs(normalizeSigned(heading-a.bearingAfter))
        : 0;
      if(away>=35 && deviation>=15 && mismatch>=45) missedTurn=true;
      if(away>140 || Date.now()-a.armedAt>30000) state.rerouteArmedTurn=null;
    }

    const p=progressProjection(state.position,coords);
    const segBearing=p ? routeSegmentBearingAt(p.index,coords) : null;
    const headingMismatch=Number.isFinite(heading) && Number.isFinite(segBearing)
      ? Math.abs(normalizeSigned(heading-segBearing))
      : 0;

    if(missedTurn) {
      state.routeDeviationCount=0;
      state.rerouteHeadingMismatchCount=0;
      state.rerouteArmedTurn=null;
      requestRoute({force:true});
      return;
    }

    if(deviation>=hard) state.routeDeviationCount=2;
    else if(deviation>=soft) state.routeDeviationCount+=1;
    else state.routeDeviationCount=0;

    if(deviation>=15 && headingMismatch>=50) state.rerouteHeadingMismatchCount+=1;
    else state.rerouteHeadingMismatchCount=0;

    if(state.routeDeviationCount>=2 || state.rerouteHeadingMismatchCount>=2) {
      state.routeDeviationCount=0;
      state.rerouteHeadingMismatchCount=0;
      requestRoute({force:true});
    }
  }

  function formatEta(seconds) {
    if (!Number.isFinite(seconds)) return '';
    const mins = Math.max(1,Math.round(seconds/60));
    if (mins < 60) return `約 ${mins} 分`;
    const h = Math.floor(mins/60), m = mins%60;
    return m ? `約 ${h} 小時 ${m} 分` : `約 ${h} 小時`;
  }

  function clearGeoRecoveryTimer() {
    if (state.geoRecoveryTimer != null) {
      clearTimeout(state.geoRecoveryTimer);
      state.geoRecoveryTimer = null;
    }
  }

  async function refreshGeolocationPermissionHint() {
    if (!navigator.permissions?.query) return 'unknown';
    try {
      const status = await navigator.permissions.query({name:'geolocation'});
      state.geoPermissionState = String(status?.state || 'unknown');
      return state.geoPermissionState;
    } catch (_) {
      state.geoPermissionState = 'unknown';
      return 'unknown';
    }
  }

  function showGpsGestureRecovery(message='點一下啟用 GPS') {
    if (state.position) return;
    state.geoUserActionRequired = true;
    setGpsState(message,'warn');
    refreshRouteWaitingStatus();
    els.permissionCard.hidden=false;
    els.startSensorsBtn.disabled=false;
    els.startSensorsBtn.textContent='啟用 GPS';
    if(nativeBridgeActive())return;
    refreshGeolocationPermissionHint().then(permission => {
      if (state.position || els.permissionCard.hidden) return;
      if (permission === 'denied') {
        setGpsState('Safari 已封鎖定位（點此查看）','bad');
        els.startSensorsBtn.textContent='重新嘗試 GPS';
      }
    });
  }

  function armGpsNoCallbackWatchdog(token, delay=5000) {
    clearGeoRecoveryTimer();
    state.geoRecoveryTimer = setTimeout(() => {
      state.geoRecoveryTimer = null;
      if (token !== state.geoAttemptToken || state.position) return;
      // WebKit can leave a geolocation request pending without resolving or
      // rejecting while site permission is in a prompt/transition state.
      // Do not stack more automatic requests. Ask for one real user gesture.
      showGpsGestureRecovery('點一下啟用 GPS');
    }, delay);
  }

  function clearGeolocationWatch() {
    if (nativeBridgeActive()) {
      try { window.Door581Native?.stopLocation?.(); } catch (_) {}
      state.watchId = null;
      state.geoStarted = false;
      return;
    }
    if (state.watchId != null) {
      try { navigator.geolocation.clearWatch(state.watchId); } catch (_) {}
    }
    state.watchId = null;
    state.geoStarted = false;
  }

  function ensureGeolocationWatch() {
    if (nativeBridgeActive()) {
      if (state.watchId === 'native') return;
      try {
        window.Door581Native?.startLocation?.();
        state.watchId = 'native';
        state.geoStarted = true;
      } catch (err) {
        console.warn('native location stream start failed',err);
        state.watchId = null;
        state.geoStarted = false;
      }
      return;
    }
    if (!navigator.geolocation || state.watchId != null) return;
    try {
      state.watchId = navigator.geolocation.watchPosition(onPosition, onPositionError, {
        enableHighAccuracy:true,
        maximumAge:1000,
        timeout:15000
      });
      state.geoStarted = true;
    } catch (err) {
      console.warn('geolocation watch start failed',err);
      state.watchId = null;
      state.geoStarted = false;
    }
  }

  function requestOneShotLocation({fromGesture=false, force=false}={}) {
    if (!nativeBridgeActive() && !navigator.geolocation) {
      setGpsState('此裝置不支援定位','bad');
      return;
    }
    // Safari pauses Web orientation during GPS recovery. Native iOS keeps its
    // CLLocation heading stream alive so direction remains available instantly.
    pauseOrientationForGpsRecovery();
    if (force) clearGeolocationWatch();

    const token=++state.geoAttemptToken;
    state.geoStarted=true;
    state.geoUserActionRequired=false;
    clearGeoRecoveryTimer();
    setGpsState(nativeBridgeActive() ? '正在取得定位…' : (fromGesture ? '正在向 Safari 取得定位…' : '定位中…'),'warn');
    refreshRouteWaitingStatus();
    if (fromGesture) {
      els.permissionCard.hidden=false;
      els.startSensorsBtn.disabled=true;
      els.startSensorsBtn.textContent=nativeBridgeActive()?'等待 iOS…':'等待 Safari…';
    }

    armGpsNoCallbackWatchdog(token, fromGesture ? 8000 : 4500);

    if (nativeBridgeActive()) {
      try {
        window.Door581Native?.requestLocation?.();
        // Do not wait for requestLocation() to resolve before starting the live
        // stream. Native warm-start may paint immediately while a fresh fix is
        // acquired in parallel.
        ensureGeolocationWatch();
      } catch (err) {
        console.warn('native location one-shot start failed',err);
        state.geoStarted=false;
        showGpsGestureRecovery('GPS 啟動失敗（點此重試）');
      }
      return;
    }

    try {
      navigator.geolocation.getCurrentPosition(
        pos => {
          if (token !== state.geoAttemptToken && !state.position) return;
          onPosition(pos);
          ensureGeolocationWatch();
        },
        err => {
          if (token !== state.geoAttemptToken && state.position) return;
          onPositionError(err);
        },
        {enableHighAccuracy:true,maximumAge:0,timeout:12000}
      );
    } catch (err) {
      console.warn('geolocation one-shot start failed',err);
      state.geoStarted=false;
      showGpsGestureRecovery('GPS 啟動失敗（點此重試）');
    }
  }

  function startGeolocationWatch({force=false,fromGesture=false}={}) {
    if (!nativeBridgeActive() && !navigator.geolocation) {
      setGpsState('此裝置不支援定位','bad');
      return;
    }

    if (fromGesture) {
      requestOneShotLocation({fromGesture:true,force:true});
      return;
    }

    if (force) clearGeolocationWatch();
    if (state.position) {
      ensureGeolocationWatch();
      return;
    }
    if (state.geoStarted && !force) return;

    // Auto-start is best-effort. If iOS Safari does not resolve/reject the
    // request, a JS watchdog exposes a real user-gesture button instead of
    // leaving the UI forever on "定位中…".
    requestOneShotLocation({fromGesture:false,force});
  }

  function attachOrientation() {
    if (nativeBridgeActive() || state.orientationAttached) return;
    state.orientationAttached = true;
    window.addEventListener('deviceorientation', onOrientation, true);
    window.addEventListener('deviceorientationabsolute', onOrientation, true);
  }

  function detachOrientation() {
    if (nativeBridgeActive()) {
      state.orientationAttached = false;
      return;
    }
    if (!state.orientationAttached) return;
    try { window.removeEventListener('deviceorientation', onOrientation, true); } catch (_) {}
    try { window.removeEventListener('deviceorientationabsolute', onOrientation, true); } catch (_) {}
    state.orientationAttached = false;
  }

  function clearOrientationResumeTimer() {
    if (state.orientationResumeTimer != null) {
      clearTimeout(state.orientationResumeTimer);
      state.orientationResumeTimer = null;
    }
  }

  function pauseOrientationForGpsRecovery() {
    clearOrientationResumeTimer();
    if (nativeBridgeActive()) return;
    // iOS Safari can become unreliable when geolocation and motion permission /
    // event startup happen at the same time. GPS owns acquisition/recovery.
    // Compass is resumed only AFTER a location fix has already succeeded.
    detachOrientation();
  }

  function scheduleRememberedOrientationAfterGps(delay=900) {
    if (nativeBridgeActive()) return;
    if (!state.position || state.orientationAttached || state.orientationResumeTimer != null) return;
    if (localStorage.getItem('581-door-orientation-ok') !== '1') return;
    state.orientationResumeTimer=setTimeout(()=>{
      state.orientationResumeTimer=null;
      if (!state.position || state.orientationAttached) return;
      attachOrientation();
    },delay);
  }

  async function requestOrientationPermissionFromGesture() {
    if (nativeBridgeActive()) {
      state.compassGrantedThisDocument=true;
      return true;
    }
    if (state.compassGrantedThisDocument) {
      attachOrientation();
      return true;
    }
    // Never compete with a still-pending GPS acquisition. The rider needs both,
    // but iOS gets them in sequence: location first, compass second.
    if (!state.position) {
      startGeolocationWatch({force:true,fromGesture:true});
      toast('先取得 GPS；定位成功後再按 ↑ 啟用靜止朝向');
      return false;
    }
    try {
      if (window.DeviceOrientationEvent &&
          typeof DeviceOrientationEvent.requestPermission === 'function') {
        const result = await DeviceOrientationEvent.requestPermission();
        if (result === 'granted') {
          localStorage.setItem('581-door-orientation-ok', '1');
          state.compassGrantedThisDocument=true;
          attachOrientation();
          ensureGeolocationWatch();
          return true;
        }
        localStorage.removeItem('581-door-orientation-ok');
        toast('方向權限未允許；移動中仍可用 GPS 行進方向');
        return false;
      }
      state.compassGrantedThisDocument=true;
      attachOrientation();
      ensureGeolocationWatch();
      return true;
    } catch (err) {
      console.warn('orientation permission', err);
      toast('方向感測器需再授權；GPS 定位仍會維持');
      return false;
    }
  }

  async function startSensors() {
    // This click is an explicit user gesture. On iOS Safari it is the most
    // reliable moment to trigger/renew the website Location permission sheet.
    state.sensorStarted=true;
    requestOneShotLocation({fromGesture:true,force:true});
    localStorage.setItem('581-door-sensors-remembered','1');
  }

  function autoStartRememberedSensors() {
    if(nativeBridgeActive()){
      const copy=els.permissionCard?.querySelector?.('.sheet-copy');
      if(copy)copy.textContent='App 會先顯示最近可信位置，同時更新高精度 GPS；若尚未取得位置，可點一次「啟用 GPS」。';
    }
    // Strict sensor sequencing for iOS Safari:
    // 1) acquire GPS first with ZERO orientation listeners attached;
    // 2) after the first successful GPS fix, silently resume a previously-granted
    //    compass listener. A new compass permission prompt still requires a tap.
    pauseOrientationForGpsRecovery();
    startGeolocationWatch();
    state.sensorStarted=true;
    return true;
  }

  function onOrientation(ev) {
    globalThis.DoorPowerDiag?.mark?.('orientation');
    let heading = null;
    if (Number.isFinite(ev.webkitCompassHeading)) heading = ev.webkitCompassHeading;
    else if (ev.absolute && Number.isFinite(ev.alpha)) heading = (360 - ev.alpha) % 360;
    if (heading == null) return;
    state.orientationEventSeen = true;
    state.compassGrantedThisDocument=true;
    state.lastOrientationAt = Date.now();
    state.compassHeading = normalizeAngle(heading);
    const now=performance.now();
    if(now-(state.lastHeadingUiAt||0)<33){globalThis.DoorPowerDiag?.mark?.('orientationSkip');return;}
    state.lastHeadingUiAt=now;updateHeading();
  }

  function onNativeHeading(ev) {
    const sample=ev?.detail||{},heading=Number(sample.heading),timestamp=Number(sample.timestamp),accuracy=Number(sample.accuracy);
    if(sample.heading==null||!Number.isFinite(heading)||heading<0||heading>=360||!Number.isFinite(timestamp)||Date.now()-timestamp>=2500||timestamp>Date.now()+2000||!Number.isFinite(accuracy)||accuracy<0||accuracy>60)return;
    globalThis.DoorPowerDiag?.mark?.('orientation');
    state.orientationEventSeen=true;
    state.compassGrantedThisDocument=true;
    state.lastOrientationAt=timestamp;
    state.compassHeading=normalizeAngle(heading);
    const now=performance.now();
    if(now-(state.lastHeadingUiAt||0)<33){globalThis.DoorPowerDiag?.mark?.('orientationSkip');return;}
    state.lastHeadingUiAt=now;
    updateHeading();
  }

  function onNativeLocation(ev) {
    const d=ev?.detail||{};
    const latitude=Number(d.latitude),longitude=Number(d.longitude);
    if(!Number.isFinite(latitude)||!Number.isFinite(longitude))return;
    const pos={
      coords:{
        latitude,longitude,
        accuracy:Number(d.accuracy)||0,
        speed:d.speed!=null&&Number.isFinite(Number(d.speed))?Number(d.speed):null,
        heading:d.heading!=null&&Number.isFinite(Number(d.heading))?Number(d.heading):null
      },
      timestamp:Number(d.timestamp)||Date.now()
    };
    if(d.warmStart===true){
      if(state.position){ensureGeolocationWatch();return;}
      if(state.warmPosition && Math.abs(Number(state.warmPosition.ts)-Number(pos.timestamp))<1){
        ensureGeolocationWatch();
        return;
      }
      const warm={
        lat:latitude,lng:longitude,
        accuracy:pos.coords.accuracy,
        speed:pos.coords.speed,
        heading:pos.coords.heading,
        ts:pos.timestamp
      };
      state.warmPosition=warm;
      if(visualMotion){if(visualMotion.paused&&!document.hidden)visualMotion.resume();visualMotion.push(warm);}
      else {userMarker.setLngLat([warm.lng,warm.lat]);if(!userMarker._map)userMarker.addTo(map);}
      els.permissionCard.hidden=true;
      els.startSensorsBtn.disabled=false;
      els.startSensorsBtn.textContent='重新啟用 GPS';
      setGpsState(`最近位置 ±${Math.round(warm.accuracy||0)}m · 更新中…`,'warn');
      if(state.firstFix&&!state.cameraUserOverride&&!state.navigationRequested&&!state.destination){
        map.easeTo({center:[warm.lng,warm.lat],zoom:15,duration:180});
      }
      ensureGeolocationWatch();
      return;
    }
    state.warmPosition=null;
    onPosition(pos);
    ensureGeolocationWatch();
  }

  function onNativeNetwork(ev){
    const online=ev?.detail?.online;
    state.nativeNetworkOnline=typeof online==='boolean'?online:null;
  }

  window.addEventListener('door581:nativeHeading',onNativeHeading);
  window.addEventListener('door581:nativeLocation',onNativeLocation);
  window.addEventListener('door581:nativeNetwork',onNativeNetwork);
  window.addEventListener('door581:nativeLocationError',ev=>onPositionError(ev.detail||{code:2,message:'GPS 暫時無法定位'}));
  window.addEventListener('door581:nativeLocationAuthorization',ev=>{if([1,2].includes(Number(ev.detail?.status)))onPositionError({code:1,message:'iOS 定位權限被拒絕'});});
  setInterval(()=>{if(!document.hidden)updateHeading();},500);

  function onPosition(pos) {
    globalThis.DoorPowerDiag?.mark?.('gps');
    const c = pos.coords;
    const current = {
      lat:c.latitude, lng:c.longitude,
      accuracy:Number.isFinite(c.accuracy) ? c.accuracy : 0,
      speed:Number.isFinite(c.speed) ? c.speed : null,
      heading:Number.isFinite(c.heading) ? normalizeAngle(c.heading) : null,
      ts:pos.timestamp || Date.now()
    };
    state.prevPosition = state.position;
    state.position = current;
    state.lastPositionAt = Date.now();
    state.geoRecoveryAttempts = 0;
    state.geoUserActionRequired = false;
    clearGeoRecoveryTimer();
    els.permissionCard.hidden=true;
    els.startSensorsBtn.disabled=false;
    els.startSensorsBtn.textContent='重新啟用 GPS';
    refreshGeolocationPermissionHint();
    scheduleRememberedOrientationAfterGps();

    let derivedCourse = null;
    let derivedSpeed = null;
    if (state.prevPosition) {
      const dist = haversineMeters(state.prevPosition, current);
      const dt = Math.max(0.2, (current.ts - state.prevPosition.ts)/1000);
      if (dist >= 3 && dt <= 12) {
        derivedCourse = bearingBetween(state.prevPosition, current);
        derivedSpeed = dist/dt;
      }
    }
    const displaySpeed=current.speed != null ? current.speed : derivedSpeed || 0;
    const moving = displaySpeed >= 1.2;
    state.gpsCourse = moving ? (current.heading ?? derivedCourse ?? state.gpsCourse) : null;
    const previousDisplay=state.displayPosition;
    const displayCurrent=navigationDisplayPosition(current,displaySpeed);
    state.displayPosition=displayCurrent;
    if(state.fitLocked&&previousDisplay&&haversineMeters(previousDisplay,displayCurrent)>.5)state.fitNeedsRefresh=true;

    if(visualMotion){if(visualMotion.paused&&!document.hidden)visualMotion.resume();visualMotion.push(displayCurrent);}
    else {userMarker.setLngLat([displayCurrent.lng,displayCurrent.lat]);if(!userMarker._map)userMarker.addTo(map);}
    updateAccuracy();
    updateHeading();
    updateRouteProgressDisplay();
    updateDistance();
    updateGuideLine();
    updateDeliveryProgress();
    maybeAutoReroute();
    updateNlscDetailOverlayVisibility();
    scheduleCleanMapDetails();
    setGpsState(`GPS ±${Math.round(current.accuracy || 0)}m`, current.accuracy > 40 ? 'warn' : '');
    refreshRouteWaitingStatus();

    if(state.fitLocked) {state.firstFix=false;updateFitCamera();return;}
    if (state.firstFix) {
      state.firstFix = false;
      if (state.cameraUserOverride) return;
      if (state.navigationRequested) {
        state.following=true;syncCameraControls();followCamera({force:true});
      } else if (state.destination) fitOverview();
      else map.easeTo({center:[current.lng,current.lat],zoom:15,duration:500});
    } else if (state.following) {
      followCamera();
    }
  }

  function onPositionError(err) {
    visualMotion?.suspend();
    console.warn('geolocation',err);
    clearGeoRecoveryTimer();
    state.geoStarted=false;
    const code=Number(err?.code || 0);
    const detail=String(err?.message || '').trim();
    if (code===1) {
      state.geoPermissionState='denied';
      setGpsState(nativeBridgeActive()?'iOS 定位權限被拒絕':'Safari 定位權限被拒絕','bad');
      els.permissionCard.hidden=false;
      els.startSensorsBtn.disabled=false;
      els.startSensorsBtn.textContent='重新嘗試 GPS';
      toast(nativeBridgeActive()?'請到 iOS 設定允許 581 Door Map 使用位置':'Safari 沒有允許這個網站定位；點「重新嘗試 GPS」後允許位置');
    } else {
      setGpsState(code===3 ? 'GPS 逾時（點此重試）' : 'GPS 尚未取得（點此重試）','warn');
      els.permissionCard.hidden=false;
      els.startSensorsBtn.disabled=false;
      els.startSensorsBtn.textContent='啟用 GPS';
      if (detail) console.warn('geolocation detail',detail);
    }
    refreshRouteWaitingStatus();
    refreshGeolocationPermissionHint();
  }

  function updateHeading() {
    const compassFresh=Number.isFinite(state.compassHeading) &&
      (!state.lastOrientationAt || Date.now()-state.lastOrientationAt<2500);
    // Static/slow: compass gives the direction BEFORE movement. While riding it
    // also stays responsive; GPS course is the fallback when orientation is unavailable.
    const gpsFresh=state.position&&Date.now()-state.position.ts<2500&&Number(state.position.speed)>=1.2&&Number(state.position.accuracy)<=65;
    const target = compassFresh ? state.compassHeading : (gpsFresh?state.gpsCourse:null);
    userEl.classList.toggle('direction-unavailable',!Number.isFinite(target));
    if (!Number.isFinite(target)) return;
    const dt=Math.max(10,Math.min(150,performance.now()-(state.lastHeadingSmoothAt||0)));state.lastHeadingSmoothAt=performance.now();
    const diff=Math.abs(normalizeSigned(target-state.displayHeading));if(Number.isFinite(state.displayHeading)&&diff<.2)return;
    state.displayHeading = smoothAngle(state.displayHeading,target,compassFresh?1-Math.exp(-dt/65):.38);
    if(document.hidden)return;
    globalThis.DoorPowerDiag?.mark?.('headingUi');
    updateFanRotation();
    // In stable-forward 3D navigation the compass only drives rider/direction UI.
    // Route/GPS updates own the camera, so 60Hz orientation events must not keep
    // re-running the camera planner while the road direction has not changed.
    const stable3dNav=!!(state.navigationActive&&buildings3d?.enabled);
    if (state.following && state.position && (state.mode === 'heading' || state.navigationActive) && !stable3dNav) followCamera();
  }

  function avatarScreenView(relative) {
    const r=normalizeSigned(relative);
    const ar=Math.abs(r);
    if (ar <= 55) return {view:'back',mirror:r<0,side:Math.min(1,ar/55)};
    if (ar >= 125) return {view:'front',mirror:r>0,side:Math.min(1,(180-ar)/55)};
    return {view:'side',mirror:r<0,side:1};
  }

  function updateAvatarPerspective(relative) {
    if (state.avatarMode === 'classic') return;
    const cfg=AVATAR_ASSETS[state.avatarMode];
    const view=avatarScreenView(relative);
    const src=view.view === 'back' ? cfg.back : cfg.front;
    if (avatarImgEl.getAttribute('src') !== src) avatarImgEl.src=src;
    avatarWrapEl.dataset.view=view.view;
    avatarWrapEl.classList.toggle('mirror',view.mirror);
    const sideScale=view.view==='side' ? 0.68 : (1-0.12*view.side);
    const lean=view.view==='side' ? (view.mirror ? -7 : 7) : (view.mirror ? -3*view.side : 3*view.side);
    avatarImgEl.style.transform=`scaleX(${view.mirror ? -sideScale : sideScale}) rotate(${lean}deg)`;
  }

  function updateFanRotation() {
    const relative = normalizeSigned(state.displayHeading - map.getBearing());
    fanEl.style.transform = `rotate(${relative}deg)`;
    avatarHeadingEl.style.transform = `rotate(${relative}deg)`;
    if (state.avatarMode === 'classic') {
      avatarWrapEl.style.transform = 'rotate(0deg)';
    } else {
      // The character is a pseudo-3D sprite: it stays upright to the camera,
      // while front/back/side artwork follows heading relative to the SCREEN.
      // Heading toward screen-top => rear view; toward screen-bottom => face view.
      avatarWrapEl.style.transform = 'rotate(0deg)';
      updateAvatarPerspective(relative);
    }
  }

  // v0.3.66 stable-forward 3D keeps arrival in the same riding composition; 2D keeps legacy arrival fit.
  function remainingRouteForArrival() {
    const coords=routeCoordinates();
    if(!state.position||coords.length<2)return [];
    const p=progressProjection(state.position,coords);
    if(!p||p.distance>Math.max(55,Math.min(90,Number(state.position.accuracy)||0)))return [];
    const out=[p.coord,...coords.slice(p.index+1)];
    const dest=state.destination?[state.destination.lng,state.destination.lat]:null;
    if(dest&&(!out.length||haversineMeters({lng:out.at(-1)[0],lat:out.at(-1)[1]},state.destination)>3))out.push(dest);
    return out;
  }
  function resetArrivalCamera() { state.arrivalCamera={active:false,locked:false,zoom:null,pitch:null}; }
  function arrivalBounds(points) {
    if(!Array.isArray(points)||points.length<2)return null;
    try{const b=new maplibregl.LngLatBounds(points[0],points[0]);for(const q of points.slice(1))b.extend(q);return b;}catch(_){return null;}
  }

  // v0.3.32 — maneuver-aware camera + fast reroute + gated NLSC detail.
  function navigationViewport() {
    const rect=map.getContainer().getBoundingClientRect();
    const width=rect.width || map.getContainer().clientWidth || window.innerWidth;
    const height=rect.height || map.getContainer().clientHeight || window.innerHeight;
    const hud=els.topHud?.getBoundingClientRect();
    const card=document.getElementById('insetCard')?.getBoundingClientRect();
    // Expanded doorplate map is an editing surface and may cover the rider; it
    // must not push the live camera away. Reserve only the collapsed capsule.
    const insetReserve=state.insetCollapsed?(card?.height||56):56;
    // PiP is a USER PRESET, never a claim to detect another application's window.
    const top=state.pipView ? Math.max(Math.min(height*.34,260),fitPipBottom(height,width)) : Math.min((hud?.height||50)+22,height*.23);
    const bottom=Math.min(insetReserve+32,height*.29);
    const right=Math.min(86,width*.24), left=12;
    const anchorY=Math.max(top+45,Math.min(height*(state.pipView ? .74 : .68),height-bottom-24));
    const centerY=(height+top-bottom)/2;
    return {width,height,top,bottom,right,left,anchorY,
      offset:[0,anchorY-centerY],padding:{top,bottom,left,right}};
  }

  function routeCameraPreview() {
    const coords=routeCoordinates();
    if (!state.position || coords.length<2) return {points:[],turnMeters:Infinity,lookAhead:0,onRoute:false};
    const p=progressProjection(state.position,coords);
    if (!p || p.distance>Math.max(45,Math.min(80,Number(state.position.accuracy)||0)))
      return {points:[],turnMeters:Infinity,lookAhead:0,onRoute:false};
    const speed=Number.isFinite(state.position.speed)?Math.max(0,state.position.speed):0;
    const lookAhead=Math.max(80,Math.min(200,80+speed*9));
    const path=[p.coord,...coords.slice(p.index+1)];
    const points=[path[0]];
    let metres=0,turnMeters=Infinity,turnCoord=null,turnBearingAfter=null;
    // Sample at ~15m rather than raw vertex count: works for sparse and dense lines.
    const samples=[{coord:path[0],metres:0}];
    let nextSample=15;
    for(let i=1;i<path.length && metres<lookAhead+50;i++) {
      const a=path[i-1],b=path[i];
      const length=haversineMeters({lng:a[0],lat:a[1]},{lng:b[0],lat:b[1]});
      if(length<.01) continue;
      while(nextSample<=metres+length && nextSample<=lookAhead+50) {
        const t=(nextSample-metres)/length;
        samples.push({coord:[a[0]+(b[0]-a[0])*t,a[1]+(b[1]-a[1])*t],metres:nextSample});
        nextSample+=15;
      }
      if(metres<lookAhead && metres+length>=lookAhead) {
        const t=Math.max(0,Math.min(1,(lookAhead-metres)/length));
        points.push([a[0]+(b[0]-a[0])*t,a[1]+(b[1]-a[1])*t]);
      } else if(metres+length<lookAhead) points.push(b);
      metres+=length;
    }
    for(let i=1;i<samples.length-1;i++) {
      const a=samples[i-1].coord,b=samples[i].coord,c=samples[i+1].coord;
      const before=bearingBetween({lng:a[0],lat:a[1]},{lng:b[0],lat:b[1]});
      const after=bearingBetween({lng:b[0],lat:b[1]},{lng:c[0],lat:c[1]});
      if(Math.abs(normalizeSigned(after-before))>=30) {turnMeters=samples[i].metres;turnCoord=b.slice();turnBearingAfter=after;break;}
    }
    return {points,turnMeters,turnCoord,turnBearingAfter,lookAhead,onRoute:true};
  }

  // Route-first bearing for the stable-forward 3D camera. Compass remains live
  // for rider/avatar UI, but it no longer rotates the whole city on tiny sensor jitter.
  function routeForwardBearing(preview,fallback) {
    const pts=Array.isArray(preview?.points)?preview.points:[];
    if(pts.length<2)return Number.isFinite(fallback)?normalizeAngle(fallback):0;
    const start=pts[0],targetMetres=36;
    let walked=0,target=pts[1];
    for(let i=1;i<pts.length;i++) {
      const a=pts[i-1],b=pts[i];
      const seg=haversineMeters({lng:a[0],lat:a[1]},{lng:b[0],lat:b[1]});
      if(!Number.isFinite(seg)||seg<=.01)continue;
      if(walked+seg>=targetMetres) {
        const q=Math.max(0,Math.min(1,(targetMetres-walked)/seg));
        target=[a[0]+(b[0]-a[0])*q,a[1]+(b[1]-a[1])*q];break;
      }
      walked+=seg;target=b;
    }
    const b=bearingBetween({lng:start[0],lat:start[1]},{lng:target[0],lat:target[1]});
    return Number.isFinite(b)?normalizeAngle(b):(Number.isFinite(fallback)?normalizeAngle(fallback):0);
  }

  function stable3dBearing(preview,lastBearing,elapsed,fallback) {
    const target=routeForwardBearing(preview,fallback);
    if(!Number.isFinite(lastBearing))return target;
    const d=normalizeSigned(target-lastBearing);
    if(Math.abs(d)<STABLE_3D_BEARING_DEADZONE)return normalizeAngle(lastBearing);
    const step=Math.max(2.5,STABLE_3D_BEARING_RATE_DPS*Math.max(.05,Math.min(1.5,Number(elapsed)||.18)));
    return normalizeAngle(lastBearing+Math.max(-step,Math.min(step,d)));
  }

  function stable3dArrivalZoom(meters) {
    const m=Number.isFinite(meters)?Math.max(0,meters):Infinity;
    const lerp=(a,b,t)=>a+(b-a)*Math.max(0,Math.min(1,t));
    if(m<=200)return STABLE_3D_ARRIVAL_ZOOM;
    if(m<=350)return lerp(STABLE_3D_ARRIVAL_ZOOM,17.75,(m-200)/150);
    if(m<=550)return lerp(17.75,17.20,(m-350)/200);
    if(m<=800)return lerp(17.20,STABLE_3D_ZOOM,(m-550)/250);
    return STABLE_3D_ZOOM;
  }

  function navigationPitch(meters,turnMeters,speed) {
    const m=Number.isFinite(meters)?Math.max(0,meters):1500;
    const lerp=(a,b,t)=>a+(b-a)*Math.max(0,Math.min(1,t));

    // Arrival: progressively flatten, ending almost top-down for doorplate reading.
    let destinationPitch;
    if(m<=30) destinationPitch=lerp(4,8,m/30);
    else if(m<=80) destinationPitch=lerp(8,24,(m-30)/50);
    else if(m<=150) destinationPitch=lerp(24,42,(m-80)/70);
    else if(m<=300) destinationPitch=lerp(42,53,(m-150)/150);
    else if(m<=1000) destinationPitch=lerp(53,62,(m-300)/700);
    else destinationPitch=62;

    // Maneuver: temporary Google-Maps-like junction view, but not flat like arrival.
    const t=Number(turnMeters);
    let turnPitch=65;
    if(Number.isFinite(t)) {
      if(t<=30) turnPitch=38;
      else if(t<=80) turnPitch=45;
      else if(t<=150) turnPitch=52;
      else if(t<=250) turnPitch=58;
    }
    return Math.max(4,Math.min(65,Math.min(destinationPitch,turnPitch)));
  }

  function navigationPitch3d(meters,turnMeters,speed) {
    const m=Number.isFinite(meters)?Math.max(0,meters):1500;
    const lerp=(a,b,t)=>a+(b-a)*Math.max(0,Math.min(1,t));
    let destinationPitch;
    // The rider uses FIT for a flat overview; ordinary 3D navigation retains
    // depth even at arrival/turns. No bearing-to-destination pitch dependency.
    if(m<=150)destinationPitch=54;
    else if(m<=500)destinationPitch=lerp(54,64,(m-150)/350);
    else destinationPitch=64;
    const t=Number(turnMeters);
    const turnPitch=Number.isFinite(t)?lerp(52,64,(t-25)/215):64;
    return Math.max(52,Math.min(64,destinationPitch,turnPitch));
  }

  function manual3dPitchForZoom(z) {
    if(!Number.isFinite(z)||z<16.9||z>=19.45)return 0;
    if(z<17.25)return 38+(z-16.9)/.35*10;
    if(z<18.9)return 48+Math.min(8,(z-17.25)*5);
    return Math.max(28,56-(z-18.9)/.55*28);
  }

  function maybeApplyManual3dPitch() {
    if(!state.cameraUserOverride||state.fitLocked||!buildings3d?.enabled)return;
    const z=Number(map.getZoom()),current=Number(map.getPitch()),target=manual3dPitchForZoom(z);
    if(target>0&&current<6){state.manual3dAutoPitch=true;map.easeTo({pitch:target,duration:320,easing:t=>1-Math.pow(1-t,3)});}
    else if(state.manual3dAutoPitch&&target===0&&current>2){state.manual3dAutoPitch=false;map.easeTo({pitch:0,duration:260});}
  }

  function followCamera({force=false}={}) {
    if(state.cameraGestureHold)return;
    if(state.fitLocked)return; // Compass ticks never run the FIT optimizer.
    if (document.hidden || !state.following || state.cameraUserOverride || !state.position) return;
    const now=performance.now();
    if(!state.arrivalCamera)state.arrivalCamera={active:false,locked:false,zoom:null,pitch:null};
    const elapsed=Math.max(.05,Math.min(1.5,(now-state.cameraLastFollowAt)/1000));
    if (!force && now-state.cameraLastFollowAt<180) return;
    state.cameraLastFollowAt=now;
    const nav=state.navigationActive && state.routeEnabled && routeCoordinates().length>=2;
    const displayPoint=state.displayPosition||state.position;
    const direct=state.destination?haversineMeters(displayPoint,state.destination):NaN;
    const routed=currentRemainingMetrics()?.meters;
    const remaining=Number.isFinite(routed)?Math.max(routed,Number.isFinite(direct)?direct:0):direct;
    const preview=nav?routeCameraPreview():{points:[],turnMeters:Infinity,lookAhead:0};
    const viewport=navigationViewport();
    const arrivalApi=window.DoorArrivalCamera;
    const arrivalActive=!!(nav&&arrivalApi?.active?.(!!state.arrivalCamera?.active,remaining));
    if(!arrivalActive&&state.arrivalCamera?.active)resetArrivalCamera();
    else if(arrivalActive)state.arrivalCamera.active=true;
    const arrivalRoute=arrivalActive?remainingRouteForArrival():[];
    const threeD=!!buildings3d?.enabled;
    const last=state.cameraPlan;
    let bearing=state.mode==='heading'?state.displayHeading:0;
    if(nav&&threeD&&state.mode==='heading')bearing=stable3dBearing(preview,last?.nav?last.bearing:null,elapsed,bearing);
    else if(arrivalActive&&arrivalRoute.length>=2)bearing=arrivalApi.approachBearing(arrivalRoute,bearing);
    // Keep the legacy helper available for 2D/manual compatibility tests, then
    // override automatic 3D navigation with one stable riding pitch.
    let desiredPitch=nav?(threeD?navigationPitch3d(remaining,preview.turnMeters,state.position.speed):0):0;
    if(nav&&threeD)desiredPitch=STABLE_3D_PITCH;
    const approach=(current,target,limit)=>current+Math.max(-limit,Math.min(limit,target-current));
    let pitch=!force && last && last.nav===nav
      ? approach(last.pitch,desiredPitch,12*elapsed):desiredPitch;
    // Stable 3D never evaluates the old destination/turn zoom program. 2D keeps
    // the legacy behavior; 3D stays at one riding scale and only changes bearing.
    let zoom=NAVIGATION_ZOOM;
    if(nav&&threeD) zoom=STABLE_3D_ZOOM;
    else {
      const destinationZoom=nearDestinationZoom(remaining);
      const maneuverZoom=nav&&!arrivalActive?turnApproachZoom(preview.turnMeters):null;
      zoom=Number.isFinite(destinationZoom)?destinationZoom:NAVIGATION_ZOOM;
      if(Number.isFinite(maneuverZoom)) zoom=Math.max(zoom,maneuverZoom);
    }
    let planCenter=[displayPoint.lng,displayPoint.lat],centerMode='gps',planPadding=nav?viewport.padding:{top:0,bottom:0,left:0,right:0},planOffset=nav?viewport.offset:[0,0],arrivalPadding=null;

    if(nav&&threeD) {
      // Keep the same calm forward 3D composition. Only final-approach zoom is
      // allowed to change: start gently near 800m, reach close-up by 200m, then
      // lock through the final approach. Turns still never trigger zoom/pitch.
      desiredPitch=STABLE_3D_PITCH;pitch=STABLE_3D_PITCH;
      const lock3d=Number.isFinite(remaining)&&(remaining<=200||(state.arrivalCamera.locked&&remaining<=250));
      if(lock3d){state.arrivalCamera.locked=true;state.arrivalCamera.zoom=STABLE_3D_ARRIVAL_ZOOM;zoom=STABLE_3D_ARRIVAL_ZOOM;}
      else {state.arrivalCamera.locked=false;state.arrivalCamera.zoom=null;state.arrivalCamera.pitch=null;zoom=stable3dArrivalZoom(remaining);}
    } else if(nav&&arrivalActive&&arrivalRoute.length>=2&&typeof map.cameraForBounds==='function') {
      // The last ~500m is composed as one scene: remaining route + target. The
      // straight start->destination bearing puts the target toward screen-top;
      // PiP padding leaves it just below the reserved PiP edge instead of under it.
      arrivalPadding=arrivalApi.padding(viewport,state.pipView);
      const bounds=arrivalBounds(arrivalRoute);
      if(bounds){
        const arrivalMaxZoom=Number(arrivalApi.MAX_AUTO_ZOOM)||17.0;
        const lockZoom=state.arrivalCamera.locked&&Number.isFinite(state.arrivalCamera.zoom)?Math.min(state.arrivalCamera.zoom,arrivalMaxZoom):arrivalMaxZoom;
        const fit=map.cameraForBounds(bounds,{bearing,padding:arrivalPadding,maxZoom:lockZoom});
        if(Number.isFinite(fit?.zoom)&&fit?.center){
          let fitted=Math.max(15.15,Math.min(arrivalMaxZoom,fit.zoom-.18));
          if(state.arrivalCamera.locked&&Number.isFinite(state.arrivalCamera.zoom))fitted=state.arrivalCamera.zoom;
          zoom=fitted;planCenter=[fit.center.lng,fit.center.lat];centerMode='plan';planPadding={top:0,bottom:0,left:0,right:0};planOffset=[0,0];
        }
      }
      const lockNow=arrivalApi.shouldLock(!!state.arrivalCamera.locked,remaining);
      if(lockNow&&!state.arrivalCamera.locked){state.arrivalCamera.locked=true;state.arrivalCamera.zoom=zoom;state.arrivalCamera.pitch=pitch;}
      else if(!lockNow&&state.arrivalCamera.locked){state.arrivalCamera.locked=false;state.arrivalCamera.zoom=null;state.arrivalCamera.pitch=null;}
      if(state.arrivalCamera.locked){
        if(Number.isFinite(state.arrivalCamera.zoom))zoom=state.arrivalCamera.zoom;
        if(Number.isFinite(state.arrivalCamera.pitch)){desiredPitch=state.arrivalCamera.pitch;pitch=state.arrivalCamera.pitch;}
      }
    } else if(nav&&!threeD) {
      // Normal 2D navigation fits only the upcoming corridor. Arrival mode above is
      // intentionally the only path that fits the complete remaining route.
      if(preview.points.length>=2 && typeof map.cameraForBounds==='function') {
        const bounds=new maplibregl.LngLatBounds(preview.points[0],preview.points[0]);
        preview.points.forEach(p=>bounds.extend(p));
        const fit=map.cameraForBounds(bounds,{bearing,padding:viewport.padding,maxZoom:zoom});
        if(Number.isFinite(fit?.zoom)) zoom=Math.max(15.5,Math.min(zoom,fit.zoom+.2));
      }
      if(!force && last && last.nav===nav && Number.isFinite(last.zoom))
        zoom=approach(last.zoom,zoom,.9*elapsed);
    }
    // Clamp after easing too, so a prior manual close-up or old plan cannot
    // linger at z20 after returning to automatic navigation. FIT exits above.
    if(nav&&threeD){zoom=Math.min(STABLE_3D_ARRIVAL_ZOOM,Math.max(STABLE_3D_ZOOM,zoom));pitch=STABLE_3D_PITCH;}
    else if(nav)zoom=Math.min(19.10,zoom);
    if(Number.isFinite(zoom))zoom=Math.max(12,Math.min(20.5,zoom+(Number(state.cameraZoomOffset)||0)));
    const opts={center:planCenter,centerMode,bearing,pitch,
      duration:force?550:350,easing:t=>1-Math.pow(1-t,3),padding:planPadding,offset:planOffset};
    if(Number.isFinite(zoom)) opts.zoom=zoom;
    state.cameraPlan={nav,pitch,desiredPitch,zoom,bearing,lookAhead:preview.lookAhead,
      turnMeters:preview.turnMeters,anchorY:nav?viewport.anchorY:viewport.height/2,
      viewportHeight:viewport.height,pipPreset:state.pipView,arrival:arrivalActive,arrivalLocked:!!state.arrivalCamera.locked,
      arrivalRemainingMeters:Number.isFinite(remaining)?remaining:null,centerMode,arrivalPadding};
    document.body.style.setProperty('--nav-safe-top',`${Math.round((arrivalPadding?.top??viewport.top)+8)}px`);
    if(visualMotion)visualMotion.setPlan(opts,{force});
    else map.easeTo(opts);
  }

  function syncNavigationUi() {
    (typeof planner==='undefined'?null:planner)?.sync();
    const active=!!(state.navigationActive || state.navigationRequested);
    document.body.classList.toggle('driving',!!(state.navigationActive || state.fitLocked));
    document.body.classList.toggle('pip-view',!!state.pipView);
    els.routeBtn.classList.toggle('active',active);
    els.routeBtn.setAttribute('aria-pressed',String(active));
    els.routeBtn.title=active?'結束導航，保留目的地與路線':'開始導航';
    els.routeBtn.setAttribute('aria-label',els.routeBtn.title);
    els.pipViewBtn.classList.toggle('active',!!state.pipView);
    els.pipViewBtn.setAttribute('aria-pressed',String(!!state.pipView));
    els.pipViewBtn.querySelector('.option-state').textContent=state.pipView?'已開啟':'已關閉';
    if(typeof syncOriginalHouseNumberVisibility==='function')syncOriginalHouseNumberVisibility();
  }

  function toggleNavigation() {
    if((typeof planner==='undefined'?null:planner)?.editing){toast('請先完成或取消路線編輯');return;}
    if(state.fitLocked)stopFitLock('navigation-button');
    if(state.navigationActive || state.navigationRequested) {
      state.navigationRequested=false;state.navigationActive=false;
      state.cameraPlan=null;resetArrivalCamera();
      syncNavigationUi();
      state.cameraUserOverride=true;
      showRouteOverview();
      return;
    }
    if(!state.destination) {openDestDialog();toast('先設定目的地，再開始導航');return;}
    state.navigationRequested=true;
    state.navigationActive=true;
    state.autoFitRoutePending=false;
    if(!state.routeEnabled) setRouteEnabled(true);
    setHudCollapsed(true);setMoreOpen(false);setInsetCollapsed(true);
    setFollowing(true);
    if(!state.position) startGeolocationWatch({force:true,fromGesture:true});
    else if(routeCoordinates().length<2) requestRoute({force:true});
    syncNavigationUi();
  }

  function setPipView(on) {
    state.pipView=!!on;
    localStorage.setItem('581-door-pip-view',state.pipView?'1':'0');
    syncNavigationUi();
    if(state.fitLocked) {state.fitNeedsRefresh=true;updateFitCamera({force:true,full:true});}
    else if(state.following && !state.cameraUserOverride) followCamera({force:true});
  }

  function setMode(mode) {
    if(state.fitLocked)stopFitLock('heading-button');
    const wasActive=state.navigationActive || state.navigationRequested;
    state.mode=mode==='heading'?'heading':'north';
    state.navigationActive=state.routeEnabled && routeCoordinates().length>=2 && (wasActive || state.mode==='heading');
    if(state.navigationActive) {state.navigationRequested=true;setHudCollapsed(true);}
    state.following=true;state.cameraUserOverride=false;state.cameraPlan=null;
    syncCameraControls();syncNavigationUi();
    if(state.position)followCamera({force:true});
  }

  function setFollowing(on) {
    if(state.fitLocked)stopFitLock('follow-button');
    state.following=!!on;state.cameraUserOverride=!state.following;if(!state.following)resetArrivalCamera();
    if(state.following) state.manual3dAutoPitch=false;
    if(state.following) {
      state.navigationActive=state.routeEnabled && routeCoordinates().length>=2 &&
        (state.navigationRequested || state.navigationActive || state.mode==='heading');
      if(state.navigationActive) {state.navigationRequested=true;setHudCollapsed(true);}
    }
    state.cameraPlan=null;
    syncCameraControls();syncNavigationUi();
    if(state.following && state.position)followCamera({force:true});
  }

  function fitOverview() {
    showRouteOverview({duration:650});
  }

  function updateAccuracy() {
    if (!state.mapsReady || !state.position) return;
    const radius = Math.max(4, Math.min(100, state.position.accuracy || 0));
    submitSceneData(map,'accuracy',()=>circleGeoJSON(state.position.lng,state.position.lat,radius,40),[state.position.lng,state.position.lat,radius]);
  }

  function updateGuideLine() {
    if (!state.mapsReady) return;
    const src = map.getSource('dest-guide');
    if (!src) return;
    if (!state.position || !state.destination) { submitSceneData(map,'dest-guide',emptyFeatureCollection()); return; }
    if (state.routeEnabled && routeCoordinates().length >= 2) {
      submitSceneData(map,'dest-guide',emptyFeatureCollection());
      return;
    }
    submitSceneData(map,'dest-guide',()=>({ type:'FeatureCollection', features:[{
      type:'Feature', properties:{}, geometry:{ type:'LineString', coordinates:[
        [state.position.lng,state.position.lat],[state.destination.lng,state.destination.lat]
      ]}
    }]}),[state.position.lng,state.position.lat,state.destination.lng,state.destination.lat]);
  }

  function segmentProjection(point, a, b) {
    const lat0=point.lat*Math.PI/180;
    const sx=111320*Math.max(.15,Math.cos(lat0)), sy=111320;
    const px=point.lng*sx, py=point.lat*sy;
    const ax=a[0]*sx, ay=a[1]*sy, bx=b[0]*sx, by=b[1]*sy;
    const vx=bx-ax, vy=by-ay, wx=px-ax, wy=py-ay;
    const vv=vx*vx+vy*vy;
    const t=vv>0 ? Math.max(0,Math.min(1,(wx*vx+wy*vy)/vv)) : 0;
    const qx=ax+t*vx, qy=ay+t*vy;
    return {t,distance:Math.hypot(px-qx,py-qy)};
  }

  function routeRemainingMeters(point) {
    const coords=routeCoordinates();
    if (!point || coords.length<2) return null;

    const segLens=[];
    for (let i=1;i<coords.length;i++) {
      segLens.push(haversineMeters(
        {lng:coords[i-1][0],lat:coords[i-1][1]},
        {lng:coords[i][0],lat:coords[i][1]}
      ));
    }

    let bestDistance=Infinity,bestIndex=0,bestT=0;
    const startIndex=Math.max(1,Number(state.routeProgressIndex||0)-2);
    for (let i=startIndex;i<coords.length;i++) {
      const proj=segmentProjection(point,coords[i-1],coords[i]);
      if (proj.distance<bestDistance) {
        bestDistance=proj.distance;
        bestIndex=i-1;
        bestT=proj.t;
      }
    }

    let remain=(1-bestT)*segLens[bestIndex];
    for (let i=bestIndex+1;i<segLens.length;i++) remain+=segLens[i];

    if (bestDistance>250 && Number.isFinite(state.routeDistance)) return state.routeDistance;
    return Math.max(0,remain);
  }

  function currentRemainingMetrics() {
    if (!state.destination || !state.position) return null;
    const displayPoint=state.displayPosition||state.position;

    if (state.routeEnabled && routeCoordinates().length>=2) {
      const meters=routeRemainingMeters(displayPoint);
      if (Number.isFinite(meters)) {
        let seconds=null;
        if (Number.isFinite(state.routeDuration) &&
            Number.isFinite(state.routeDistance) &&
            state.routeDistance>0) {
          seconds=Math.max(0,state.routeDuration*Math.min(1.15,meters/state.routeDistance));
        }
        return {meters,seconds,routed:true};
      }
    }

    return {
      meters:haversineMeters(displayPoint,state.destination),
      seconds:null,
      routed:false
    };
  }

  function updateQuickRouteMetrics() {
    if (!els.quickDistance || !els.quickEta) return;
    const m=currentRemainingMetrics();
    if (!m) {
      els.quickDistance.textContent='-- km';
      els.quickEta.textContent='-- 分';
      return;
    }
    els.quickDistance.textContent=m.meters>=1000?`${(m.meters/1000).toFixed(1)} km`:`${Math.round(m.meters)} m`;
    els.quickEta.textContent=Number.isFinite(m.seconds)?formatEta(m.seconds).replace(/^約\s*/,''):(m.routed?'計算中':'直線');
  }

  function updateDistance() {
    // Remaining route metrics and the compact next-turn capsule update with GPS.
    updateQuickRouteMetrics();
    updateInsetTitle();

    if (!state.destination) { els.distanceText.textContent='目的地未設定'; return; }
    if (!state.position) { els.distanceText.textContent='目的地已設定'; return; }

    const m=currentRemainingMetrics();
    if (m?.routed && Number.isFinite(m.meters)) {
      const d=m.meters>=1000 ? `${(m.meters/1000).toFixed(1)} km` : `${Math.round(m.meters)} m`;
      els.distanceText.textContent =
        Number.isFinite(m.seconds) ? `${d} · ${formatEta(m.seconds)}` : d;
      return;
    }

    const direct=haversineMeters(state.position,state.destination);
    els.distanceText.textContent =
      direct>=1000 ? `直線 ${(direct/1000).toFixed(1)} km` : `直線 ${Math.round(direct)} m`;
  }

  function setGpsState(text, kind='') {
    els.gpsState.textContent = text;
    els.gpsState.className = `state-badge ${kind}`.trim();
  }

  function toast(text) {
    els.toast.textContent=text;
    els.toast.classList.add('show');
    clearTimeout(state.toastTimer);
    state.toastTimer=setTimeout(()=>els.toast.classList.remove('show'),2500);
  }

  function openDestDialog() {
    state.destinationDialogEpoch++;
    state.addressSearchSeq++;
    els.destInput.value='';
    els.destInput.classList.remove('resolving');
    els.destError.textContent='';
    els.applyDestBtn.disabled=false;
    els.applyDestBtn.textContent='搜尋 / 套用';
    clearAddressResults();
    if(els.searchHint)els.searchHint.textContent='本機候選：台中已下載 OSM 場所索引；網路補充：© OpenStreetMap contributors · Nominatim（按下搜尋才查）';
    setMoreOpen(false);
    if(!els.destDialog.open)els.destDialog.showModal();
    els.destInput.focus({preventScroll:true});
  }

  els.destDialog.addEventListener('close',()=>{
    state.destinationDialogEpoch++;state.addressSearchSeq++;state.localSearchSeq++;clearTimeout(state.localSearchTimer);
    els.destInput.value='';els.destError.textContent='';clearAddressResults();
  });
  els.creditsBtn.addEventListener('click',()=>{els.creditsIntro.hidden=true;els.creditsDialog.showModal();});
  // OSM permits auto-collapse after five seconds. The info button always restores full credits.
  setTimeout(()=>{els.creditsIntro.hidden=true;},5500);
  els.startSensorsBtn.addEventListener('click',startSensors);
  els.setDestFromSheetBtn.addEventListener('click',openDestDialog);
  els.destBtn.addEventListener('click',openDestDialog);
  els.destInput.addEventListener('input',scheduleLocalDestinationSuggestions);
  els.applyDestBtn.addEventListener('click', async () => {
    const raw = String(els.destInput.value || '').trim();
    if(!raw) {els.destError.textContent='請貼上座標、中文地址或 Google Maps 分享連結';return;}
    if(/https?:\/\//i.test(raw) && !looksLikeGoogleMapsShare(raw)) {
      els.destError.textContent='只支援 Google Maps 分享網址';return;
    }
    // Submitting owns the results now. A pending 110ms autocomplete must not
    // erase already returned network candidates with an empty local result.
    clearTimeout(state.localSearchTimer);state.localSearchSeq++;
    const epoch=state.destinationDialogEpoch;
    let d = looksLikeGoogleMapsShare(raw)?null:parseDestination(raw);

    els.destError.textContent = '';
    clearAddressResults();

    els.applyDestBtn.disabled = true;
    const previousText = els.applyDestBtn.textContent;

    try {
      if (d) {
        setDestination(d,{fit:true,persist:true});
        els.destDialog.close();
        toast('座標目的地已設定');
        return;
      }

      if (looksLikeGoogleMapsShare(raw)) {
        els.applyDestBtn.textContent = '解析 Google Maps…';
        els.destInput.classList.add('resolving');
        d = await resolveGoogleMapsShare(raw);
        if(epoch!==state.destinationDialogEpoch || !els.destDialog.open)return;
        setDestination(d,{fit:true,persist:true});
        els.destDialog.close();
        toast(d.__sourceMeta?.notice||'Google Maps Pin 已同步');
        return;
      }

      // Local Taichung OSM suggestions are allowed while typing because they
      // never hit Nominatim. The public geocoder is still queried only here.
      const local=await localPlaceSearch(raw,currentSearchCenter(),20);
      if(epoch!==state.destinationDialogEpoch || !els.destDialog.open)return;
      if(local.length){renderAddressResults(local,{showEmptyError:false});if(els.searchHint)els.searchHint.textContent=`已先顯示 ${local.length} 筆本機候選；正在補充網路結果…`;}
      if(raw.trim().length<2){
        if(local.length){
          if(els.searchHint)els.searchHint.textContent=`已顯示 ${local.length} 筆本機候選；輸入 2 字以上可再補充全台網路結果`;
          return;
        }
        throw new Error('請至少輸入 2 個字');
      }
      els.applyDestBtn.textContent = local.length?'補充網路結果…':'搜尋地址…';
      els.destInput.classList.add('resolving');
      const results = await geocodeAddress(raw,{seed:local});
      if(epoch!==state.destinationDialogEpoch || !els.destDialog.open)return;
      renderAddressResults(results);
      if(els.searchHint)els.searchHint.textContent=results.length?'搜尋完成；本機候選優先，網路結果已合併':'沒有找到候選';
    } catch (err) {
      if(epoch===state.destinationDialogEpoch && els.destDialog.open)els.destError.textContent = String(err?.message || err || '目的地解析失敗');
    } finally {
      if(epoch===state.destinationDialogEpoch) {
        els.applyDestBtn.disabled = false;
        els.applyDestBtn.textContent = previousText || '搜尋 / 套用';
        els.destInput.classList.remove('resolving');
      }
    }
  });
  els.centerCoordToggle?.addEventListener('click',()=>setCenterPickEnabled(!state.centerPickEnabled));
  els.copyCenterCoordBtn?.addEventListener('click',async()=>{
    if(!state.centerPickEnabled){toast('請先展開地圖中心工具');return;}
    const c=map.getCenter(),text=`${Number(c.lat).toFixed(7)}, ${Number(c.lng).toFixed(7)}`;
    toast(await copyTextSafe(text)?'中心座標已複製':'無法自動複製，請長按座標文字');
  });
  els.navigateCenterBtn?.addEventListener('click',()=>{
    if(!state.centerPickEnabled){toast('地圖中心選點目前關閉');return;}
    const resolved=centerNavigateTarget(),d=resolved.point;
    if(!d||!offlineValidTaiwanPoint(d.lat,d.lng)){toast('中心點不在台灣範圍');return;}
    state.manual3dAutoPitch=false;state.following=true;state.cameraUserOverride=false;state.centerPickEnabled=false;syncCameraControls();
    setDestination(d,{fit:true,persist:true});
    if(!state.routeEnabled)setRouteEnabled(true,{persist:true,request:true});
    toast('已將地圖中心設為新目的地');
  });

  els.followBtn.addEventListener('click',()=>{
    // Locate/recenter is GPS-only. Motion/orientation permission belongs only
    // to the explicit heading (↑) control, never the locate button.
    setFollowing(true);
    if (!state.position) {
      startGeolocationWatch({force:true,fromGesture:true});
      toast('正在取得 GPS…');
      return;
    }
    if (state.fitLocked) state.fitNeedsRefresh=true;
    if (state.following && !state.cameraUserOverride) followCamera({force:true});
  });
  els.overviewBtn.addEventListener('click',()=>setFitLock(!state.fitLocked));
  els.avatarBtn?.addEventListener('click',openAvatarDialog);
  document.querySelectorAll('.avatar-choice').forEach(btn => {
    btn.addEventListener('click', () => {
      setAvatarMode(btn.dataset.avatar);
      els.avatarDialog.close();
      toast(`導航角色：${btn.dataset.avatar === 'goku' ? '悟空・觔斗雲' : btn.dataset.avatar === 'luffy' ? '魯夫' : '經典藍點'}`);
    });
  });
  els.themeBtn?.addEventListener('click',()=>setTheme(state.theme === 'dark' ? 'light' : 'dark'));
  els.gpsState?.addEventListener('click',()=>{
    toast('重新取得 GPS…');
    pauseOrientationForGpsRecovery();
    startGeolocationWatch({force:true,fromGesture:true});
  });

  window.addEventListener('pageshow',()=>{
    scheduleOcrDestSyncBurst('pageshow');
    const stale=!state.lastPositionAt || Date.now()-state.lastPositionAt>15000;
    if (stale && !state.geoUserActionRequired) {
      pauseOrientationForGpsRecovery();
      startGeolocationWatch({force:true});
    }
  });
  document.addEventListener('visibilitychange',()=>{
    if(document.hidden) {if(state.fitLocked)map.stop();clearTimeout(state.cleanDetailTimer);state.cleanDetailTimer=null;cancelAnimationFrame(state.centerCoordRaf);state.centerCoordRaf=0;return;}
    renderAll();scheduleMainSceneSync('foreground',0); // Latest state once; never replay hidden display work.
    if(state.fitLocked) {state.fitNeedsRefresh=true;updateFitCamera({force:true});}
    scheduleOcrDestSyncBurst('visible');
    const stale=!state.lastPositionAt || Date.now()-state.lastPositionAt>15000;
    if (stale && !state.geoUserActionRequired) {
      pauseOrientationForGpsRecovery();
      startGeolocationWatch({force:true});
    }
  });

  window.addEventListener('hashchange',()=>{
    if (destinationHandoffFromHash()) consumeHashDestinationHandoff({fit:true});
  });
  window.addEventListener('pageshow',()=>{
    // Shortcuts/Safari may resume an existing tab without a full reload.
    if (destinationHandoffFromHash()) consumeHashDestinationHandoff({fit:true});
  });

  els.offlineBtn?.addEventListener('click',async()=>{
    await Promise.all([refreshOfflinePackUi(),checkOfflineDataUpdates({notify:false,force:true}),refreshRouteDataStatus()]);
    els.offlineDialog?.showModal();
  });
  els.offlineDownloadBtn?.addEventListener('click',()=>installTaichungOfflinePack());
  els.offlineDeleteBtn?.addEventListener('click',()=>deleteTaichungOfflinePack());
  els.offlineCloseBtn?.addEventListener('click',()=>els.offlineDialog?.close());

  els.routeBtn.addEventListener('click',toggleNavigation);
  els.routeVisibilityBtn.addEventListener('click',()=>setRouteEnabled(!state.routeEnabled));
  els.pipViewBtn.addEventListener('click',()=>setPipView(!state.pipView));
  setTimeout(()=>window.DoorLocalSearch?.ensure?.().catch(()=>{}),1200);
  setTimeout(()=>{checkOfflineDataUpdates({notify:true});refreshRouteDataStatus();},2500);
  window.addEventListener('resize',()=>{if(state.fitLocked)updateFitCamera({force:true,full:true});else if(state.following && !state.cameraUserOverride)followCamera({force:true});},{passive:true});
  if (els.osmStatus) {
    els.osmStatus.addEventListener('click', () => {
      if (!state.destination) return;
      refreshNearbyEntrances(state.destination, {force:true});
    });
  }

  els.headingBtn.addEventListener('click', () => {
    setMode('heading');
    if (!state.position) {
      startGeolocationWatch({force:true,fromGesture:true});
      toast('先取得 GPS；定位成功後會恢復鏡頭前行');
      return;
    }
    if (!Number.isFinite(state.compassHeading)) {
      requestOrientationPermissionFromGesture().then(granted=>{
        if (granted) toast('方向感測器已啟用：鏡頭前行可在靜止時維持方向');
        else if (!Number.isFinite(state.gpsCourse)) toast('方向尚未啟用；GPS 定位不受影響');
      });
    }
  });
  els.northModeBtn?.addEventListener('click',()=>setMode('north'));

  function recenterInset({animate=true}={}) {
    if (!state.destination) {
      toast('先設定目的地');
      return;
    }

    const camera = {
      center:[state.destination.lng,state.destination.lat],
      zoom:state.insetZoom,
      bearing:0,
      pitch:0
    };

    inset.resize();
    if (animate) {
      inset.easeTo({...camera,duration:260});
    } else {
      inset.jumpTo(camera);
    }
  }

  function applyInsetDestinationCorrection() {
    if (!state.destination) {toast('先設定目的地');return;}
    const c=inset.getCenter?.();
    const lat=Number(c?.lat),lng=Number(c?.lng);
    if(!Number.isFinite(lat)||!Number.isFinite(lng)||lat<20||lat>27||lng<117||lng>123){toast('小地圖中心位置無效');return;}
    const previous={...state.destination},raw=state.rawDestination?{...state.rawDestination}:{...previous};
    const corrected={lat,lng};
    state.rawDestination=raw;
    if(window.__581AppleDestination){state.rawDestination={...corrected};state.destinationIntent={source:'inset-manual'};state.destinationInfo={};window.__581AppleDestination=false;}
    state.destination=corrected;
    state.destinationCorrection={applied:true,source:'inset-manual',distanceM:haversineMeters(raw,corrected),checked:true};
    state.destinationInfoSeq++;
    state.destinationInfo={...(state.destinationInfo||{}),houseNumber:'',houseLabel:'',road:'',approximate:false};
    try{
      localStorage.setItem('581-door-dest',`${lat},${lng}`);
      localStorage.setItem('581-door-dest-raw',`${raw.lat},${raw.lng}`);
      if(state.destinationIntent)localStorage.setItem('581-door-dest-meta',JSON.stringify(state.destinationIntent));
    }catch(_){}
    updateDestinationInfoUi();
    scheduleMainSceneSync('inset-manual-correction',0);
    syncInsetScene({recenter:false});
    updateDistance();
    updateGuideLine();
    refreshDestinationReverse(corrected);
    refreshNearbyEntrances(corrected,{force:true});
    if(state.routeEnabled&&state.position){state.autoFitRoutePending=false;requestRoute({force:true});}
    setInsetCollapsed(true);
    toast('終點定位已修正');
  }

  function setHudCollapsed(collapsed) {
    state.hudCollapsed=!!collapsed;
    els.topHud.classList.toggle('collapsed',state.hudCollapsed);
    els.hudDetails.hidden=state.hudCollapsed;
    els.hudCollapseBtn.setAttribute('aria-expanded',String(!state.hudCollapsed));
    els.hudCollapseBtn.setAttribute('aria-label',state.hudCollapsed ? '展開導航資訊' : '收合導航資訊');
    els.hudCollapseBtn.title=state.hudCollapsed ? '展開導航資訊' : '收合導航資訊';
    if(state.fitLocked)state.fitNeedsRefresh=true;
  }

  function setMoreOpen(open,{returnFocus=false}={}) {
    state.moreOpen=!!open;
    if(state.fitLocked) {map.stop();state.fitNeedsRefresh=true;}
    els.morePanel.hidden=!state.moreOpen;
    els.moreBtn.setAttribute('aria-expanded',String(state.moreOpen));
    els.moreBtn.classList.toggle('active',state.moreOpen);
    if (!state.moreOpen && returnFocus) els.moreBtn.focus({preventScroll:true});
  }
  els.hudCollapseBtn.addEventListener('click',()=>setHudCollapsed(!state.hudCollapsed));
  els.moreBtn.addEventListener('click',()=>setMoreOpen(!state.moreOpen));
  els.morePanel.addEventListener('click',e=>{
    if (e.target.closest('button') && !e.target.closest('#gogoroRefreshBtn')) setMoreOpen(false);
  });
  document.addEventListener('pointerdown',e=>{
    if (state.moreOpen && !els.morePanel.contains(e.target) && !els.moreBtn.contains(e.target)) setMoreOpen(false);
  },{capture:true,passive:true});
  document.addEventListener('keydown',e=>{
    if (e.key === 'Escape' && state.moreOpen) setMoreOpen(false,{returnFocus:true});
  });

  function setInsetCollapsed(collapsed) {
    state.insetCollapsed=!!collapsed;
    if(state.fitLocked)state.fitNeedsRefresh=true;
    const card=document.getElementById('insetCard');
    card.classList.toggle('collapsed',state.insetCollapsed);
    els.insetCollapseBtn.setAttribute('aria-expanded',String(!state.insetCollapsed));
    updateInsetTitle();
    els.insetCollapseBtn.title=state.insetCollapsed ? '往上展開' : '向下收合';
    if (!state.insetCollapsed) {
      setTimeout(()=>{
        if (state.insetCollapsed) return;
        inset.resize();
        // Keep manual pan/zoom and unconfirmed correction on close/reopen.
      },210);
    }
  }

  if (typeof ResizeObserver !== 'undefined') {
    new ResizeObserver(syncInsetHandleHeight).observe(els.insetCollapseBtn);
  }
  window.addEventListener('resize',()=>{syncInsetHandleHeight();updateInsetTitle();},{passive:true});

  els.insetRecenterBtn.addEventListener('click', e => {
    e.stopPropagation();
    recenterInset();
  });
  els.insetCorrectBtn?.addEventListener('click', e => {
    e.stopPropagation();
    applyInsetDestinationCorrection();
  });
  els.insetCollapseBtn.addEventListener('click', e => {
    e.stopPropagation();
    setInsetCollapsed(!state.insetCollapsed);
  });

  function renderAll() {
    if(document.hidden)return;
    buildings3d?.sync();
    if (map?.isStyleLoaded?.()) {
      const h = mainSceneHealth();
      if (!h.pin || !h.community || !h.place || !h.entrance || !h.route || !h.doorplate) {
        scheduleMainSceneSync('render-repair', 0);
      }
    }
    syncInsetScene({recenter:false});

    if (state.position) {
      if(visualMotion)visualMotion.render();
      else {userMarker.setLngLat([state.position.lng,state.position.lat]);if(!userMarker._map)userMarker.addTo(map);}
      updateAccuracy();
      updateRouteProgressDisplay();
      updateDistance();
      updateGuideLine();
      maybeAutoReroute();
    }
    updateFanRotation();
  }

  function normalizeAngle(v) { return ((v%360)+360)%360; }
  function normalizeSigned(v) { return ((v+540)%360)-180; }
  function smoothAngle(prev,next,alpha) {
    if (!Number.isFinite(prev)) return normalizeAngle(next);
    const delta=normalizeSigned(next-prev);
    return normalizeAngle(prev+delta*alpha);
  }
  function haversineMeters(a,b) {
    const R=6371000, toRad=x=>x*Math.PI/180;
    const dLat=toRad(b.lat-a.lat), dLng=toRad(b.lng-a.lng);
    const s=Math.sin(dLat/2)**2 + Math.cos(toRad(a.lat))*Math.cos(toRad(b.lat))*Math.sin(dLng/2)**2;
    return 2*R*Math.asin(Math.min(1,Math.sqrt(s)));
  }
  function bearingBetween(a,b) {
    const toRad=x=>x*Math.PI/180, toDeg=x=>x*180/Math.PI;
    const p1=toRad(a.lat),p2=toRad(b.lat),dl=toRad(b.lng-a.lng);
    const y=Math.sin(dl)*Math.cos(p2);
    const x=Math.cos(p1)*Math.sin(p2)-Math.sin(p1)*Math.cos(p2)*Math.cos(dl);
    return normalizeAngle(toDeg(Math.atan2(y,x)));
  }
  function circleGeoJSON(lng,lat,radiusM,steps) {
    const coords=[];
    const latRad=lat*Math.PI/180;
    const dLat=radiusM/111320;
    const dLng=radiusM/(111320*Math.max(.15,Math.cos(latRad)));
    for(let i=0;i<=steps;i++){
      const t=2*Math.PI*i/steps;
      coords.push([lng+dLng*Math.cos(t),lat+dLat*Math.sin(t)]);
    }
    return {type:'FeatureCollection',features:[{type:'Feature',properties:{},geometry:{type:'Polygon',coordinates:[coords]}}]};
  }

  // v0.3.34: route preferences are optional. Coordinate -> Pin is never gated by them.
  function deliveryMessage(text) {
    const el=document.getElementById('deliveryStatus');
    if(el){el.textContent=text || '';el.hidden=!text;}
  }

  function readAvoidAreas() {
    try{return window.DoorDelivery.sanitizeAreas(JSON.parse(localStorage.getItem('581-delivery-areas-v1')||'[]'));}
    catch(_){return [];}
  }

  function deliveryRequestOptions(via=state.deliveryVia) {
    const D=window.DoorDelivery;
    if(!D)return {via:[],areas:[],endpointExempt:[],overflow:0};
    const chosen=D.chooseAreas(readAvoidAreas(),state.position,state.destination,via);
    return {via:via.map(p=>({lat:p.lat,lng:p.lng})),areas:chosen.areas,
      endpointExempt:chosen.endpointExempt.map(z=>z.name),endpointExemptIds:chosen.endpointExempt.map(z=>z.id),overflow:chosen.overflow};
  }

  // v0.3.35: source loading is asynchronous, but clearing an EXISTING source
  // must not wait for isStyleLoaded(). Dirty work retries on style/source events.
  function queueDeliverySync() {
    if(state.deliverySyncTimer || document.hidden)return;
    state.deliverySyncTimer=setTimeout(()=>{
      state.deliverySyncTimer=null;
      if(state.deliveryRenderDirty)syncDeliveryMap();
    },35);
  }

  function deliverySource(id,data) {
    try {
      let source=map.getSource(id);
      if(!source) {
        map.addSource(id,{type:'geojson',data});source=map.getSource(id);
        state.deliveryRenderCache.set(id,{source,json:JSON.stringify(data)});
      } else {
        const json=JSON.stringify(data),last=state.deliveryRenderCache.get(id);
        if(last?.source!==source || last.json!==json) {
          source.setData(data);state.deliveryRenderCache.set(id,{source,json});
        }
      }
      return true;
    } catch(_) {state.deliveryRenderDirty=true;return false;}
  }

  function deliveryLayer(spec,before) {
    try {if(!map.getLayer(spec.id))map.addLayer(spec,before && map.getLayer(before)?before:undefined);return true;}
    catch(_) {state.deliveryRenderDirty=true;return false;}
  }

  function deliveryLayerVisible(id,on) {
    try {if(map.getLayer(id) && map.getLayoutProperty(id,'visibility')!==(on?'visible':'none'))
      map.setLayoutProperty(id,'visibility',on?'visible':'none');}
    catch(_) {state.deliveryRenderDirty=true;}
  }

  function deliveryPreviewCurrent() {
    const p=state.deliveryPreview;
    return !!(p && state.routeEnabled && state.destination &&
      p.seq===state.deliveryPreviewSeq && p.revision===state.deliveryRevision && p.routeSeq===state.routeRequestSeq &&
      window.DoorDelivery?.meters(p.target,state.destination)<=1 &&
      !document.getElementById('routeEditPanel')?.hidden);
  }

  function syncDeliveryMap() {
    if(!map || state.deliveryRendering)return;
    state.deliveryRendering=true;state.deliveryRenderDirty=false;
    try {
      const empty=emptyFeatureCollection();
      const preview=deliveryPreviewCurrent();
      // Visibility first: stale worker/tile responses can never flash an old orange tail.
      if(!preview)deliveryLayerVisible('delivery-preview-line',false);
      if(!state.deliveryPicked)deliveryLayerVisible('delivery-picked-dot',false);
      deliverySource('delivery-preview',preview?{type:'FeatureCollection',features:[{
        type:'Feature',properties:{},geometry:state.deliveryPreview.record.geometry}]}:empty);
      deliveryLayer({id:'delivery-preview-line',type:'line',source:'delivery-preview',
        layout:{visibility:preview?'visible':'none','line-join':'round','line-cap':'round'},
        paint:{'line-color':'#ffa72f','line-width':5,'line-opacity':.94,'line-dasharray':[2,1]}});
      deliveryLayerVisible('delivery-preview-line',preview);
      deliverySource('delivery-picked',state.deliveryPicked?{type:'FeatureCollection',features:[{
        type:'Feature',properties:{},geometry:{type:'Point',coordinates:[state.deliveryPicked.lng,state.deliveryPicked.lat]}}]}:empty);
      deliveryLayer({id:'delivery-picked-dot',type:'circle',source:'delivery-picked',
        paint:{'circle-radius':10,'circle-color':'#ffa72f','circle-stroke-color':'#ffffff','circle-stroke-width':2}});
      deliveryLayerVisible('delivery-picked-dot',!!state.deliveryPicked);
      deliverySource('delivery-vias',{type:'FeatureCollection',features:state.deliveryVia.map((p,i)=>({
        type:'Feature',properties:{label:String(i+1),index:i},geometry:{type:'Point',coordinates:[p.lng,p.lat]}}))});
      deliveryLayer({id:'delivery-vias-circle',type:'circle',source:'delivery-vias',
        paint:{'circle-radius':11,'circle-color':'#168e92','circle-stroke-color':'#ffffff','circle-stroke-width':2}});
      deliveryLayer({id:'delivery-vias-label',type:'symbol',source:'delivery-vias',
        layout:{'text-field':['get','label'],'text-size':13,'text-allow-overlap':true},
        paint:{'text-color':'#ffffff','text-halo-color':'#095b60','text-halo-width':1}});
      syncAvoidAreaOverlay();
      syncDeliveryEditor();
      // Rebuild ordering after style/NLSC changes, keeping blue route and pins legible.
      for(const id of ['delivery-areas-fill','delivery-areas-outline','delivery-areas-label']) {
        try {if(map.getLayer(id))map.moveLayer(id,map.getLayer('reference-route-casing')?'reference-route-casing':undefined);}catch(_){}
      }
      bringNativeDestinationPinToFront(map,'main');
    } catch(err) {
      // Optional route-edit visuals must never block the already-working destination intake.
      state.deliveryRenderDirty=true;state.deliveryRenderError=String(err?.message||err);
    } finally {state.deliveryRendering=false;}
  }

  function clearDeliveryPreview(refresh=true,{keepManager=false}={}) {
    const manager=keepManager && state.deliveryManagerOpen;
    // Invalidate BEFORE another route/preview can commit, even while a source is busy.
    state.deliveryPreviewSeq++;state.deliveryPreview=null;state.deliveryPicked=null;
    state.deliveryPreviewBusy=false;state.deliveryEditIndex=null;state.deliveryAwaitPick=false;
    state.deliveryManagerOpen=manager;state.deliveryEditorKey='';
    const hint=document.getElementById('viaPickHint');if(hint)hint.hidden=true;
    const panel=document.getElementById('routeEditPanel');if(panel)panel.hidden=!manager;
    const button=document.getElementById('viaApplyBtn');if(button)button.disabled=true;
    deliveryLayerVisible('delivery-preview-line',false);
    deliveryLayerVisible('delivery-picked-dot',false);
    for(const id of ['delivery-preview','delivery-picked']) {
      try {const src=map.getSource(id);if(src){src.setData(emptyFeatureCollection());state.deliveryRenderCache.delete(id);}}
      catch(_) {state.deliveryRenderDirty=true;}
    }
    syncDeliveryMap();
    if(state.deliveryRenderDirty)queueDeliverySync();
    if(refresh && state.fitLocked){state.fitNeedsRefresh=true;updateFitCamera({force:true});}
  }

  function syncAvoidAreaOverlay() {
    const D=window.DoorDelivery;if(!D)return;
    const areas=D.areaFeatures(readAvoidAreas(),state.position,state.destination,state.deliveryVia);
    deliverySource('delivery-areas',areas);
    const active=['==',['get','status'],'active'];
    deliveryLayer({id:'delivery-areas-fill',type:'fill',source:'delivery-areas',
      paint:{'fill-color':['case',active,'#e6a23d','#8294a8'],
        'fill-opacity':['case',active,.16,.055]}},'reference-route-casing');
    deliveryLayer({id:'delivery-areas-outline',type:'line',source:'delivery-areas',
      paint:{'line-color':['case',active,'#f4b753','#9bacc0'],'line-width':2,'line-opacity':.9,
        'line-dasharray':[3,2]}},'reference-route-casing');
    deliveryLayer({id:'delivery-areas-label',type:'symbol',source:'delivery-areas',
      layout:{'text-field':['get','label'],'text-size':12,'text-max-width':12,'text-allow-overlap':false},
      paint:{'text-color':'#ffd48c','text-halo-color':'#17202a','text-halo-width':1.5}},'reference-route-casing');
    for(const id of ['delivery-areas-fill','delivery-areas-outline','delivery-areas-label'])deliveryLayerVisible(id,state.areaOverlayVisible);
    const box=document.getElementById('areaOverlayToggle');if(box)box.checked=state.areaOverlayVisible;
    refreshAvoidDetail();
  }

  function setAvoidAreaOverlay(on) {
    state.areaOverlayVisible=!!on;
    try {localStorage.setItem('581-avoid-overlay-visible-v1',on?'1':'0');}catch(_){}
    syncDeliveryMap(); // Display ONLY. No revision change and no route request.
  }

  function areaApplicationText(row) {
    const D=window.DoorDelivery;
    if(!row.enabled)return '已停用，不參與規劃';
    if(!D.activeAt(row,D.taipeiMinute()))return '未到設定時段，不參與規劃';
    if(state.areaRoutePhase==='pending')return '設定已生效，路線重新規劃中';
    if(state.areaRoutePhase==='failed')return '新路線未套用，仍保留上一條路線';
    if(state.areaRouteExemptIds.includes(row.id))return '本次起點／終點／途經點附近，豁免此區';
    if(state.areaRouteIds.includes(row.id))return '本次路線已套用避讓';
    return '已啟用；是否套用依本次路線與區域上限而定';
  }

  function refreshAvoidDetail() {
    const dialog=document.getElementById('avoidAreaDetailDialog');if(!dialog?.open)return;
    const row=readAvoidAreas().find(z=>z.id===state.areaDetailId);
    if(!row){dialog.close();return;}
    document.getElementById('areaDetailTitle').textContent=row.name;
    document.getElementById('areaDetailMeta').textContent=`半徑 ${row.radius}m · ${row.start===row.end?'全天':row.start+'–'+row.end+'（台北時間）'}`;
    document.getElementById('areaDetailNote').textContent=row.note||'沒有備註';
    document.getElementById('areaDetailState').textContent=areaApplicationText(row);
    document.getElementById('areaDetailToggleBtn').textContent=row.enabled?'停用':'啟用';
  }

  function openAvoidAreaDetail(id) {
    if(!readAvoidAreas().some(z=>z.id===id))return;
    state.areaDetailId=id;
    const d=document.getElementById('avoidAreaDetailDialog');
    if(!d.open)d.showModal();refreshAvoidDetail();
    if(state.fitLocked)map.stop();
  }

  function areaActivityKey() {
    const D=window.DoorDelivery;
    return D?readAvoidAreas().map(z=>z.id+':'+D.activeAt(z,D.taipeiMinute())).join('|'):'';
  }

  function scheduleAvoidAreaBoundary() {
    clearTimeout(state.areaBoundaryTimer);state.areaBoundaryTimer=null;
    if(document.hidden || !window.DoorDelivery)return;
    const delay=window.DoorDelivery.nextAreaBoundaryMs(readAvoidAreas());
    if(delay!==null)state.areaBoundaryTimer=setTimeout(()=>{
      state.areaBoundaryTimer=null;checkAvoidAreaClock();
    },delay);
  }

  function checkAvoidAreaClock() {
    const key=areaActivityKey(),changed=state.areaActiveKey!==null && key!==state.areaActiveKey;
    state.areaActiveKey=key;
    if(changed || state.areaRouteNeedsRefresh) {
      state.deliveryRevision++;clearDeliveryPreview(false);
      state.areaRoutePhase='idle';state.areaRouteIds=[];state.areaRouteExempt=[];
      syncDeliveryMap();
      state.areaRouteNeedsRefresh=document.hidden;
      if(!document.hidden && state.routeEnabled && state.position && state.destination)requestRoute({force:true});
    } else syncDeliveryMap();
    scheduleAvoidAreaBoundary();
  }

  function avoidAreasChanged() {
    (typeof planner==='undefined'?null:planner)?.queueBackup();
    state.deliveryRevision++;state.areaActiveKey=areaActivityKey();
    state.areaRoutePhase='idle';state.areaRouteIds=[];state.areaRouteExempt=[];
    clearDeliveryPreview(false);syncDeliveryMap();scheduleAvoidAreaBoundary();
    state.areaRouteNeedsRefresh=document.hidden;
    if(!document.hidden && state.routeEnabled && state.position && state.destination)requestRoute({force:true});
  }

  function resetDeliveryForDestination(dest) {
    if(!state.destination || haversineMeters(dest,state.destination)>8){
      state.deliveryVia=[];state.deliveryViaProgress=[];state.deliveryRevision++;
      clearDeliveryPreview(false);deliveryMessage('');
    }
  }

  function markViaPositions() {
    state.deliveryViaProgress=state.deliveryVia.map(p=>({
      ...p,along:window.DoorDelivery.closest(routeCoordinates(),p)?.along ?? Infinity,near:false
    }));
    syncDeliveryMap();
  }

  function updateDeliveryProgress() {
    if((typeof planner==='undefined'?null:planner)?.editing || !(state.navigationActive||state.navigationRequested))return;
    if(!window.DoorDelivery || !state.position || !state.deliveryVia.length || Number(state.position.accuracy)>35)return;
    const q=window.DoorDelivery.closest(routeCoordinates(),state.position);
    if(!q || q.distance>45)return;
    const first=state.deliveryViaProgress[0];if(!first)return;
    const dist=window.DoorDelivery.meters(first,state.position);
    if(dist<45)first.near=true;
    if(first.near && (dist<=22 || q.along>first.along+25)){
      state.deliveryVia.shift();state.deliveryViaProgress.shift();state.deliveryRevision++;
      if(state.deliveryPicked || state.deliveryAwaitPick)clearDeliveryPreview(false);
      state.deliveryEditorKey='';
      syncDeliveryMap();deliveryMessage(state.deliveryVia.length?'已通過途經點；繼續下一點':'已通過途經點');
      // Do not recalculate solely because a via was reached. Future reroutes omit it.
    }
  }

  function openDeliveryPoint(p) {
    if(!window.DoorDelivery.point(p))return;
    const editIndex=state.deliveryEditIndex;
    setMoreOpen(false);clearDeliveryPreview(false);
    if(Number.isInteger(editIndex) && editIndex>=0 && editIndex<state.deliveryVia.length)
      state.deliveryEditIndex=editIndex;
    state.deliveryPicked={lat:p.lat,lng:p.lng};state.deliveryLongPressAt=Date.now();
    document.getElementById('routeEditPanel').hidden=false;
    document.getElementById('routeEditStatus').textContent=state.deliveryEditIndex===null?
      '已選位置。先預覽，不會直接改終點。':`已重選途經點 ${state.deliveryEditIndex+1}；按「走這裡」才替換。`;
    syncDeliveryEditor();map.stop();syncDeliveryMap();
  }

  function draftDeliveryVias() {
    return window.DoorDelivery.editVias(state.deliveryVia,state.deliveryPicked,state.deliveryEditIndex);
  }

  function syncDeliveryEditor() {
    const panel=document.getElementById('routeEditPanel');if(!panel)return;
    const manage=document.getElementById('viaManageBtn');
    if(manage)manage.textContent='編輯路線';
    if(panel.hidden)return;
    const picked=!!state.deliveryPicked,editing=Number.isInteger(state.deliveryEditIndex);
    const canPreview=picked && state.routeEnabled && !!state.position && !!state.destination && !!draftDeliveryVias();
    const preview=document.getElementById('viaPreviewBtn'),apply=document.getElementById('viaApplyBtn');
    preview.disabled=!canPreview || state.deliveryPreviewBusy;
    preview.textContent=state.deliveryPreviewBusy?'預覽中…':editing?'預覽替換':state.deliveryVia.length>=2?'已滿 2 點，請刪除或重選':'預覽經過這裡';
    apply.disabled=!deliveryPreviewCurrent() || state.deliveryPreviewBusy;
    document.getElementById('viaDraftActions').hidden=!picked;
    document.getElementById('viaPreviewActions').hidden=!picked;
    document.getElementById('areaCreateBtn').hidden=!picked;
    document.getElementById('viaAddBtn').hidden=picked || state.deliveryVia.length>=2;
    document.getElementById('viaRemoveAllBtn').hidden=state.deliveryVia.length===0;
    document.getElementById('routeEditTitle').textContent=picked?(editing?`重選途經點 ${state.deliveryEditIndex+1}`:'指定經過這裡'):'管理途經點';
    const key=JSON.stringify(state.deliveryVia);
    if(key!==state.deliveryEditorKey) {
      state.deliveryEditorKey=key;
      const rows=document.getElementById('viaPointRows');rows.replaceChildren();
      state.deliveryVia.forEach((point,index)=>{
        const row=document.createElement('div');row.className='via-point-row';
        const label=document.createElement('span');label.textContent=`途經點 ${index+1}`;
        const coord=document.createElement('small');coord.textContent=`${point.lat.toFixed(5)}, ${point.lng.toFixed(5)}`;
        label.append(coord);
        const pick=document.createElement('button');pick.type='button';pick.className='secondary-btn';pick.textContent='重選';
        pick.dataset.viaReselect=String(index);pick.setAttribute('aria-label',`重選途經點 ${index+1}`);pick.onclick=()=>beginDeliveryReselect(index);
        const remove=document.createElement('button');remove.type='button';remove.className='secondary-btn';remove.textContent='刪除';
        remove.dataset.viaRemove=String(index);remove.setAttribute('aria-label',`刪除途經點 ${index+1}`);remove.onclick=()=>removeDeliveryVia(index);
        row.append(label,pick,remove);rows.append(row);
      });
    }
  }

  function openDeliveryManager() {
    (typeof planner==='undefined'?null:planner)?.openEditor();
  }

  function beginDeliveryReselect(index=null) {
    if(index!==null && (!Number.isInteger(index) || index<0 || index>=state.deliveryVia.length))return;
    clearDeliveryPreview(false);
    state.deliveryEditIndex=index;state.deliveryAwaitPick=true;
    const hint=document.getElementById('viaPickHint');hint.hidden=false;
    document.getElementById('viaPickHintText').textContent=index===null?'長按地圖重選位置':`長按新位置替換途經點 ${index+1}`;
    state.deliveryLongPressAt=Date.now();map.stop();
    // No automatic zoom/translation while selecting; genuine pan/pinch still unlocks FIT.
  }

  function clearDeliverySelection() {
    clearDeliveryPreview(false);openDeliveryManager();
    document.getElementById('routeEditStatus').textContent='已清除未套用的位置與橘色預覽；原路線及已套用途經點保留。';
  }

  function removeDeliveryVia(index) {
    if(!Number.isInteger(index) || index<0 || index>=state.deliveryVia.length)return;
    const next=state.deliveryVia.filter((_,i)=>i!==index);
    clearDeliveryPreview(false);state.deliveryVia=next;state.deliveryViaProgress=[];state.deliveryRevision++;
    openDeliveryManager();syncDeliveryMap();
    document.getElementById('routeEditStatus').textContent=`已刪除途經點 ${index+1}，正重新規劃；原目的地不變。`;
    deliveryMessage(`已移除途經點 ${index+1}`);
    if(state.routeEnabled && state.position && state.destination)requestRoute({force:true});
  }

  async function previewDeliveryVia() {
    if(!state.deliveryPicked || !state.position || !state.destination || !state.routeEnabled || state.deliveryPreviewBusy)return;
    const via=draftDeliveryVias();if(!via)return;
    const origin={lat:state.position.lat,lng:state.position.lng},target={...state.destination};
    const options=deliveryRequestOptions(via);
    const seq=++state.deliveryPreviewSeq,revision=state.deliveryRevision,routeSeq=state.routeRequestSeq;
    state.deliveryPreview=null;state.deliveryPreviewBusy=true;syncDeliveryMap();
    const from=`${origin.lng.toFixed(6)},${origin.lat.toFixed(6)}`,to=`${target.lng.toFixed(6)},${target.lat.toFixed(6)}`;
    document.getElementById('routeEditStatus').textContent='正在預覽指定路線；原導航仍保留…';
    document.getElementById('viaPreviewBtn').disabled=true;document.getElementById('viaApplyBtn').disabled=true;
    try{
      const record=await fetchRouteVariant(from,to,'main',options);
      if(seq!==state.deliveryPreviewSeq || revision!==state.deliveryRevision || routeSeq!==state.routeRequestSeq ||
         window.DoorDelivery.meters(target,state.destination)>1)return;
      state.deliveryPreview={record,via,options,origin,target,revision,routeSeq,seq};
      document.getElementById('routeEditStatus').textContent=`預覽 ${(record.distance/1000).toFixed(1)} km／約 ${Math.max(1,Math.round(record.duration/60))} 分。橘色虛線為預覽；套用後終點不變。`;
      document.getElementById('viaApplyBtn').disabled=false;syncDeliveryMap();
      // Show the preview once without changing the selected route or releasing FIT.
      if(window.DoorFitCamera){const plan=DoorFitCamera.solve(record.geometry.coordinates,[origin.lng,origin.lat],
        [target.lng,target.lat],fitViewport(),{full:true,maxZoom:18.85,riderAnchor:true,previousBearing:map.getBearing()});
        if(plan)map.easeTo({...plan,duration:500});}
    }catch(err){if(seq===state.deliveryPreviewSeq)document.getElementById('routeEditStatus').textContent=`預覽失敗：${String(err.message||err)}。原路線未改。`;}
    finally{if(seq===state.deliveryPreviewSeq){state.deliveryPreviewBusy=false;syncDeliveryEditor();}}
  }

  function applyDeliveryVia() {
    const preview=state.deliveryPreview;if(!preview || !deliveryPreviewCurrent())return;
    if(preview.revision!==state.deliveryRevision || preview.routeSeq!==state.routeRequestSeq ||
       window.DoorDelivery.meters(preview.target,state.destination)>1 ||
       window.DoorDelivery.meters(preview.origin,state.position)>70){
      document.getElementById('routeEditStatus').textContent='位置或路線已改變，請重新預覽。';
      document.getElementById('viaApplyBtn').disabled=true;return;
    }
    clearDeliveryPreview(false);
    state.deliveryVia=preview.via.map(p=>({...p}));state.deliveryRevision++;
    const seq=++state.routeRequestSeq;state.routeRequestedAt=Date.now();
    // No second route call: promote the already-validated preview.
    acceptDeliveryRoute(preview.record,seq,preview.origin);
    syncDeliveryMap();deliveryMessage(`已套用 ${state.deliveryVia.length} 個途經點`);
  }

  function clearDeliveryVia() {
    if(!state.deliveryVia.length){clearDeliverySelection();return;}
    clearDeliveryPreview(false);
    state.deliveryVia=[];state.deliveryViaProgress=[];state.deliveryRevision++;
    openDeliveryManager();syncDeliveryMap();deliveryMessage('已清除全部途經點');
    document.getElementById('routeEditStatus').textContent='已清除全部途經點，重新規劃到原目的地。';
    if(state.routeEnabled && state.position && state.destination)requestRoute({force:true});
  }

  function openAvoidAreaEditor() {
    if(!state.deliveryPicked)return;
    document.getElementById('areaName').value='';document.getElementById('areaNote').value='';
    document.getElementById('areaRadius').value='80';document.getElementById('areaStart').value='00:00';document.getElementById('areaEnd').value='00:00';
    document.getElementById('areaEditStatus').textContent='半徑以選取的位置為中心；跨到旁邊大路也會一起避開，請縮小範圍。';
    document.getElementById('avoidAreaDialog').showModal();
  }

  function saveAvoidArea() {
    if(!state.deliveryPicked)return;
    const rows=readAvoidAreas();if(rows.length>=50){document.getElementById('areaEditStatus').textContent='最多 50 區，請先移除不用的區域。';return;}
    const item={...state.deliveryPicked,id:`area-${Date.now()}-${Math.random().toString(16).slice(2,8)}`,
      name:document.getElementById('areaName').value.trim()||'避開區域',note:document.getElementById('areaNote').value.trim(),
      radius:Number(document.getElementById('areaRadius').value),start:document.getElementById('areaStart').value,
      end:document.getElementById('areaEnd').value,enabled:true,createdAt:Date.now()};
    const clean=window.DoorDelivery.sanitizeAreas([...rows,item]);
    try{localStorage.setItem('581-delivery-areas-v1',JSON.stringify(clean));}
    catch(_){document.getElementById('areaEditStatus').textContent='儲存失敗，原路線未改。';return;}
    document.getElementById('avoidAreaDialog').close();
    avoidAreasChanged();toast(`已儲存道路避開區 · ${item.radius}m`);
  }

  function showAvoidAreas() {
    const box=document.getElementById('avoidAreaRows');box.replaceChildren();
    const rows=readAvoidAreas();
    if(!rows.length){const p=document.createElement('p');p.textContent='尚未設定。長按地圖 → 標記避開區域。';box.append(p);}
    for(const row of rows){
      const div=document.createElement('div');div.className='avoid-row';
      const label=document.createElement('span');label.textContent=`${row.name} · ${row.radius}m · ${row.start===row.end?'全天':row.start+'–'+row.end}${row.note?'／'+row.note:''}`;
      const toggle=document.createElement('button');toggle.type='button';toggle.className='secondary-btn';toggle.textContent=row.enabled?'停用':'啟用';
      toggle.onclick=()=>updateAvoidArea(row.id,'toggle');
      const remove=document.createElement('button');remove.type='button';remove.className='secondary-btn';remove.textContent='刪除';remove.onclick=()=>updateAvoidArea(row.id,'remove');
      const details=document.createElement('button');details.type='button';details.className='secondary-btn area-details-btn';details.textContent='查看';details.onclick=()=>openAvoidAreaDetail(row.id);
      div.append(label,details,toggle,remove);box.append(div);
    }
    setMoreOpen(false);const dialog=document.getElementById('avoidAreasDialog');if(!dialog.open)dialog.showModal();
  }

  function updateAvoidArea(id,action) {
    let rows=readAvoidAreas();rows=action==='remove'?rows.filter(z=>z.id!==id):rows.map(z=>z.id===id?{...z,enabled:!z.enabled}:z);
    try{localStorage.setItem('581-delivery-areas-v1',JSON.stringify(rows));}catch(_){toast('儲存失敗');return;}
    avoidAreasChanged();
    if(document.getElementById('avoidAreasDialog').open)showAvoidAreas();
    refreshAvoidDetail();
  }

  function exportAvoidAreas() {
    const blob=new Blob([JSON.stringify({schema:'581-delivery-areas-v1',areas:readAvoidAreas()},null,2)],{type:'application/json'});
    const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='581-避開區域.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
  }

  function installDeliveryInteractions() {
    if(!window.DoorDelivery){console.warn('Optional delivery module not ready; base destination/routing remains available');return;}
    document.getElementById('viaManageBtn').addEventListener('click',openDeliveryManager);
    document.getElementById('viaRemoveAllBtn').addEventListener('click',clearDeliveryVia);
    document.getElementById('viaReselectBtn').addEventListener('click',()=>beginDeliveryReselect(state.deliveryEditIndex));
    document.getElementById('viaClearSelectionBtn').addEventListener('click',clearDeliverySelection);
    document.getElementById('viaAddBtn').addEventListener('click',()=>beginDeliveryReselect(null));
    document.getElementById('viaPickCancelBtn').addEventListener('click',()=>clearDeliveryPreview());
    document.getElementById('viaPreviewBtn').addEventListener('click',previewDeliveryVia);
    document.getElementById('viaApplyBtn').addEventListener('click',applyDeliveryVia);
    document.getElementById('routeEditCloseBtn').addEventListener('click',clearDeliveryPreview);
    document.getElementById('viaClearBtn').addEventListener('click',()=>{setMoreOpen(false);clearDeliveryVia();});
    document.getElementById('areaCreateBtn').addEventListener('click',openAvoidAreaEditor);
    document.getElementById('areaSaveBtn').addEventListener('click',saveAvoidArea);
    document.getElementById('areasManageBtn').addEventListener('click',showAvoidAreas);
    document.getElementById('areasExportBtn').addEventListener('click',exportAvoidAreas);
    document.getElementById('areasImportFile').addEventListener('change',async e=>{
      const f=e.target.files?.[0];if(!f)return;
      try{
        if(f.size>100000)throw Error('備份檔太大');
        const data=JSON.parse(await f.text());if(data.schema!=='581-delivery-areas-v1'||!Array.isArray(data.areas)||data.areas.length>50)throw Error('不是此 App 的區域備份');
        const merged=[...readAvoidAreas()];for(const z of window.DoorDelivery.sanitizeAreas(data.areas))if(!merged.some(x=>x.id===z.id))merged.push(z);
        if(merged.length>50)throw Error('合併後超過 50 區');
        localStorage.setItem('581-delivery-areas-v1',JSON.stringify(merged));avoidAreasChanged();showAvoidAreas();
      }catch(err){toast('匯入失敗：'+err.message);}finally{e.target.value='';}
    });

    const surface=map.getCanvasContainer();let press=null,timer=null;
    const cancel=()=>{clearTimeout(timer);timer=null;press=null;};
    surface.addEventListener('pointerdown',e=>{
      cancel();if(e.button!==0||e.isPrimary===false||e.target.closest?.('button,dialog,input,[role=button]'))return;
      press={x:e.clientX,y:e.clientY,id:e.pointerId};
      timer=setTimeout(()=>{
        if(!press)return;const r=surface.getBoundingClientRect();const p=map.unproject([press.x-r.left,press.y-r.top]);
        if(p&&Date.now()-state.deliveryLongPressAt>=900)handleMapLongPress({lat:p.lat,lng:p.lng});cancel();
      },650);
    },{passive:true});
    surface.addEventListener('pointermove',e=>{if(press&&(e.pointerId!==press.id||Math.hypot(e.clientX-press.x,e.clientY-press.y)>7))cancel();},{passive:true});
    for(const type of ['pointerup','pointercancel','wheel'])window.addEventListener(type,cancel,{passive:true});
    surface.addEventListener('touchstart',e=>{
      if(e.touches.length!==1){cancel();return;}if(press)return;
      const t=e.touches[0];press={x:t.clientX,y:t.clientY,id:'touch'};
      timer=setTimeout(()=>{if(!press)return;const r=surface.getBoundingClientRect(),p=map.unproject([press.x-r.left,press.y-r.top]);if(p&&Date.now()-state.deliveryLongPressAt>=900)handleMapLongPress({lat:p.lat,lng:p.lng});cancel();},650);
    },{passive:true});
    surface.addEventListener('touchmove',e=>{const t=e.touches[0];if(press&&(e.touches.length!==1||!t||Math.hypot(t.clientX-press.x,t.clientY-press.y)>10))cancel();},{passive:true});
    for(const type of ['touchend','touchcancel'])window.addEventListener(type,cancel,{passive:true});
    surface.addEventListener('contextmenu',e=>e.preventDefault());
    map.on('contextmenu',e=>{e.originalEvent?.preventDefault();if(Date.now()-state.deliveryLongPressAt<1200)return;
      if(e.lngLat)handleMapLongPress({lat:e.lngLat.lat,lng:e.lngLat.lng});});
    map.on('style.load',()=>{state.deliveryRenderCache.clear();state.deliveryRenderDirty=true;syncDeliveryMap();});
    map.on('load',()=>{state.deliveryRenderDirty=true;syncDeliveryMap();});
    for(const name of ['styledata','sourcedata','idle'])map.on(name,()=>{if(state.deliveryRenderDirty)queueDeliverySync();});
    // Control-point modification is available only in the explicit route editor.
    map.on('click','delivery-areas-fill',e=>{
      if((typeof planner==='undefined'?null:planner)?.editing)return;
      if(document.getElementById('gogoroPanel')&&!document.getElementById('gogoroPanel').hidden)return;
      if(!state.areaOverlayVisible || Date.now()-state.deliveryLongPressAt<1000 || !document.getElementById('routeEditPanel').hidden)return;
      const id=e.features?.[0]?.properties?.id;if(id)openAvoidAreaDetail(id);
    });
    document.getElementById('areaOverlayToggle').addEventListener('change',e=>setAvoidAreaOverlay(e.target.checked));
    document.getElementById('areaDetailToggleBtn').addEventListener('click',()=>updateAvoidArea(state.areaDetailId,'toggle'));
    document.getElementById('areaDetailDeleteBtn').addEventListener('click',()=>updateAvoidArea(state.areaDetailId,'remove'));
    document.getElementById('areaDetailLocateBtn').addEventListener('click',()=>{
      const z=readAvoidAreas().find(z=>z.id===state.areaDetailId);if(!z)return;
      document.getElementById('avoidAreaDetailDialog').close();document.getElementById('avoidAreasDialog').close();
      stopFitLock('area-locate');state.following=false;state.cameraUserOverride=true;syncCameraControls();
      setAvoidAreaOverlay(true);map.easeTo({center:[z.lng,z.lat],zoom:17,pitch:0,bearing:0,duration:400,padding:{top:0,right:0,bottom:0,left:0},offset:[0,0]});
    });
    window.addEventListener('storage',e=>{
      if(e.key==='581-delivery-areas-v1')avoidAreasChanged();
      if(e.key==='581-avoid-overlay-visible-v1'){state.areaOverlayVisible=e.newValue!=='0';syncDeliveryMap();}
    });
    document.addEventListener('visibilitychange',()=>{
      if(document.hidden){clearTimeout(state.areaBoundaryTimer);clearTimeout(state.deliverySyncTimer);state.deliverySyncTimer=null;}
      else {checkAvoidAreaClock();queueDeliverySync();}
    });
    state.areaActiveKey=areaActivityKey();scheduleAvoidAreaBoundary();
    for(const id of ['avoidAreaDialog','avoidAreasDialog','avoidAreaDetailDialog'])document.getElementById(id).addEventListener('close',()=>{
      if(state.fitLocked){state.fitNeedsRefresh=true;updateFitCamera({force:true});}});
  }

  installDeliveryInteractions();

  async function navigateGogoroStation(station, mode, stillCurrent) {
    const E=window.DoorExtras;
    if(!E?.point(station)||!E.point(state.position))throw Error('站點或 GPS 座標尚未有效');
    if(!['via','direct'].includes(mode))throw Error('未知導航操作');
    if(mode==='via'&&!state.destination)throw Error('尚無原目的地，請選「導航到這站」');
    if(mode==='via'&&state.deliveryVia.length>=window.DoorRoutePersonal.MAX_POINTS)throw Error('控制點容量已滿；原路線不變');
    const origin={lat:state.position.lat,lng:state.position.lng};
    const destination=mode==='via'?{...state.destination}:{lat:station.lat,lng:station.lng};
    const via=mode==='via'?[{lat:station.lat,lng:station.lng,name:station.name,kind:'gogoro'},...state.deliveryVia.map(p=>({...p}))]:[];
    const snapshot=JSON.stringify({raw:state.rawDestination,dest:state.destination,via:state.deliveryVia});
    const revision=state.deliveryRevision,requestSeq=state.routeRequestSeq;
    const chosen=window.DoorDelivery.chooseAreas(readAvoidAreas(),origin,destination,via);
    const options={via,areas:chosen.areas,endpointExempt:chosen.endpointExempt.map(x=>x.name),endpointExemptIds:chosen.endpointExempt.map(x=>x.id),overflow:chosen.overflow};
    // Plan first. A timeout, a shortcut intake or a different route change cannot destroy the current trip.
    const route=await fetchRouteVariant(`${origin.lng.toFixed(6)},${origin.lat.toFixed(6)}`,`${destination.lng.toFixed(6)},${destination.lat.toFixed(6)}`,'main',options);
    if(!stillCurrent()||revision!==state.deliveryRevision||requestSeq!==state.routeRequestSeq||snapshot!==JSON.stringify({raw:state.rawDestination,dest:state.destination,via:state.deliveryVia}))throw Error('導航狀態已改變，未套用舊結果');
    if(!E.point(state.position)||E.meters(state.position,origin)>60)throw Error('位置已移動，請重新按導航；原路線保留');
    const wasLocked=state.fitLocked;
    clearDeliveryPreview(false);
    if(mode==='direct')setDestination({...destination,__sourceMeta:{source:'gogoro-official',stationId:station.id,stationName:station.name,targetText:station.name}}, {fit:false,persist:false,planRoute:false});
    state.deliveryVia=via;state.deliveryRevision++;setRouteEnabled(true,{persist:false,request:false});
    try{
      localStorage.setItem('581-door-route-enabled-v2','1');
      if(mode==='direct'){localStorage.setItem('581-door-dest',`${destination.lat},${destination.lng}`);localStorage.setItem('581-door-dest-raw',`${destination.lat},${destination.lng}`);localStorage.setItem('581-door-dest-meta',JSON.stringify(state.destinationIntent));}
    }catch(_){ /* lack of persistence never blocks an otherwise valid live route */ }
    state.navigationRequested=true;state.cameraUserOverride=false;
    state.routeRequestedAt=Date.now();const seq=++state.routeRequestSeq;
    if(!acceptDeliveryRoute(route,seq,origin))throw Error('路線未套用');
    state.fitLocked=wasLocked;state.fitNeedsRefresh=true;syncDeliveryMap();syncNavigationUi();syncCameraControls();
    // Panel closes after this promise resolves; FIT is resumed on the next frame, without a second route call.
    requestAnimationFrame(()=>{if(state.fitLocked)updateFitCamera({force:true,full:true});else followCamera({force:true});});
  }

  if(window.DoorMapExtras&&window.DoorExtras){
    mapExtras=new window.DoorMapExtras({map,
      getState:()=>({theme:state.theme,position:state.position,destination:state.destination,destinationInfo:state.destinationInfo,via:state.deliveryVia,addresses:state.cleanAddressCandidates,route:routeDisplayCoordinates(),houseRoute:state.routeEnabled?routeCoordinates():[]}),
      offlineHouses:(c,r)=>offlineOfficialAddressesNear(c,r,true),navigateStation:navigateGogoroStation,notify:toast,
      pauseCamera:()=>{stopFitLock('station-inspect');state.following=false;state.cameraUserOverride=true;map.stop();syncCameraControls();}});
    mapExtras.init();
  }


  if (window.DoorBuildings3D) {
    let buildingStorage = null;
    try { buildingStorage = window.localStorage; } catch (_) {}
    buildings3d = new window.DoorBuildings3D.Controller(map, {
      getState:()=>({destination:state.destination,theme:state.theme,destinationInfo:state.destinationInfo,
        communityItems:state.communityItems,placeItems:state.placeItems,entranceItems:state.entranceItems,
        addressCandidates:state.cleanAddressCandidates,areaDestination:window.DoorAdaptiveScene?.isAreaIntent(state)||false}),
      onChange:()=>adaptiveScene?.sync(),
      storage:buildingStorage,documentRef:document,
      toggle:document.getElementById('buildings3dToggle'),
      status:document.getElementById('buildings3dStatus')
    });
    buildings3d.init();
    document.getElementById('buildings3dToggle')?.addEventListener('change',()=>{
      if(!buildings3d?.enabled&&!state.fitLocked){state.manual3dAutoPitch=false;if(state.cameraUserOverride)map.easeTo({pitch:0,duration:260});}
      adaptiveScene?.sync();
      if(state.following&&!state.cameraUserOverride)followCamera({force:true});else setTimeout(maybeApplyManual3dPitch,0);
      syncCameraControls();
    });
  }

  if(window.DoorAdaptiveScene){
    adaptiveScene=new window.DoorAdaptiveScene.Controller(map,{
      getState:()=>({threeD:!!buildings3d?.active&&!!buildings3d?.enabled,fitLocked:state.fitLocked,
        theme:state.theme,destination:state.destination,destinationInfo:state.destinationInfo,
        placeItems:state.placeItems,communityItems:state.communityItems,
        areaDestination:window.DoorAdaptiveScene.isAreaIntent(state),exactBuilding:!!buildings3d?.targetKey&&buildings3d?.targetMode!=='virtual'}),
      getNative:()=>mapExtras?.native,documentRef:document
    });
    adaptiveScene.init();
  }

  window.__581DoorMapCanary = {
    nativeDiagnostics:()=>({renderer:map.diagnostics(),position:state.position,display:state.displayPosition,heading:state.displayHeading,headingSource:Date.now()-state.lastOrientationAt<2500?'compass':'gps-or-unavailable',insetZoom:inset.getZoom(),insetCenter:inset.getCenter(),destination:state.destination,navigationRequested:state.navigationRequested,pip:state.pipView,routeEnabled:state.routeEnabled,following:state.following,fitLocked:state.fitLocked}),
    efficiencyDiagnostics:()=>({...efficiencyStats,bySource:{...efficiencyStats.bySource},house:mapExtras?.diagnostics(),motion:visualMotion?.diagnostics()}),
    motionDiagnostics:()=>visualMotion?.diagnostics()||null,
    buildingDiagnostics:()=>buildings3d?.diagnostics()||null,
    adaptiveDiagnostics:()=>adaptiveScene?.diagnostics()||null,
    localSearchDiagnostics:()=>window.DoorLocalSearch?.diagnostics?.()||null,
    setBuildings3d:on=>buildings3d?.setEnabled(on),
    extrasDiagnostics:()=>({stationOn:mapExtras?.stationOn||false,stationCount:mapExtras?.stationRows.length||0,stationStatus:mapExtras?.stationMessage||'',houseStatus:mapExtras?.houseStatus||'',houseRequests:mapExtras?.housePending.size||0,house:mapExtras?.diagnostics()||null}),
    VERSION, parseDestination, resolveGoogleMapsShare, setDestination, fitOverview,
    setFitLock, updateFitCamera,
    deliveryDiagnostics:()=>({vias:state.deliveryVia.length,areas:readAvoidAreas().length,preview:!!state.deliveryPreview,editingVia:state.deliveryEditIndex,awaitingPick:state.deliveryAwaitPick,areaOverlayVisible:state.areaOverlayVisible,areaRoutePhase:state.areaRoutePhase,renderPending:state.deliveryRenderDirty}),
    cameraInteractionDiagnostics:()=>cameraInteraction?.diagnostics()||null,
    fitDiagnostics:()=>({locked:state.fitLocked,waiting:state.fitRouteWaiting,gestureHold:state.fitGestureHold,pipBottom:fitPipBottom(map.getContainer().clientHeight,map.getContainer().clientWidth),
      stats:{...state.fitStats},camera:state.fitLastPlan,manual:state.cameraUserOverride}),
    cameraDiagnostics:()=>({...state.cameraPlan,manual:state.cameraUserOverride,arrivalState:{...state.arrivalCamera}}),
    navigationDisplayDiagnostics:()=>({raw:state.position?{lat:state.position.lat,lng:state.position.lng,accuracy:state.position.accuracy,speed:state.position.speed}:null,display:state.displayPosition?{lat:state.displayPosition.lat,lng:state.displayPosition.lng}:null,leadMeters:Number(state.displayLeadMeters)||0}),
    recenterInset, setInsetCollapsed, setHudCollapsed, setMoreOpen, openDestDialog, toggleNavigation, setPipView,
    navigationPitch, navigationPitch3d, manual3dPitchForZoom, navigationViewport, routeCameraPreview, houseNumberFeatures,
    openDeliveryManager,removeDeliveryVia,beginDeliveryReselect,clearDeliverySelection,
    detailDiagnostics:()=>({zoom:map.getZoom(),minZoom:NLSC_DOORPLATE_MIN_ZOOM,visible:nlscDetailShouldShow(),paint:nlscDetailPaint(state.theme)}), offlineOneWayFeatures, refreshNearbyEntrances, setTheme, setRouteEnabled,
    requestRoute, ensureMainDoorplateOverlay, bringOperationalLayersToFront,
    syncMainScene, syncInsetScene, showRouteOverview, mainSceneHealth,
    scheduleMainSceneSync, geocodeAddress, rememberSearchSelectedDestination, centerNavigateTarget, setCenterPickEnabled, setAvatarMode,
    promoteAlternateRoute, applyChineseRoadLabels,
    updateRouteProgressDisplay, routeDisplayCoordinates,
    installTaichungOfflinePack, deleteTaichungOfflinePack, refreshOfflinePackUi, offlineNearbyData, offlineElementsForRoute, offlineOfficialAddressesNear
  };
  if(window.DoorCommunities){
    const communityLayer=new window.DoorCommunities.Controller(map).init();
    window.__581DoorMapCanary.communityDiagnostics=()=>communityLayer.diagnostics();
  }
  if(window.DoorPlanner && window.DoorRoutePersonal){
    planner=window.DoorPlanner.install({state,map,toast,
      routeCoordinates,
      captureRoute:()=>({geometry:routeCoordinates().length?state.routeGeoJson.features[0].geometry:null,distance:state.routeDistance,duration:state.routeDuration,maneuvers:state.routeManeuvers||[],avoidApplied:state.areaRouteIds||[],endpointExempt:state.areaRouteExempt||[],avoidExemptIds:state.areaRouteExemptIds||[]}),
      invalidateRoute:()=>{state.routeRequestSeq++;state.autoFitRoutePending=false;},
      clearLegacy:()=>clearDeliveryPreview(false),closeMore:()=>setMoreOpen(false),
      pauseCamera:()=>{stopFitLock('route-editor');state.following=false;state.cameraUserOverride=true;map.stop();syncCameraControls();},
      restoreCamera:c=>{state.following=c.following;state.cameraUserOverride=c.cameraUserOverride;if(c.fitLocked)setFitLock(true);syncCameraControls();},
      applyRoute:(record,via,alts)=>{state.deliveryVia=via.map(p=>({...p}));state.deliveryRevision++;state.routeRequestedAt=Date.now();acceptDeliveryRoute(record,++state.routeRequestSeq,{lat:state.position.lat,lng:state.position.lng},alts);syncNavigationUi();},
      fetchEdited:(via,signal)=>{const origin=state.position,target=state.destination;if(!origin||!target)throw Error('GPS 或目的地尚未就緒');return fetchRouteSet(`${origin.lng.toFixed(6)},${origin.lat.toFixed(6)}`,`${target.lng.toFixed(6)},${target.lat.toFixed(6)}`,deliveryRequestOptions(via),signal);},
      fetchPreference:(from,to,via,options,signal)=>fetchRouteVariant(from,to,'main',{...options,via},signal),
      searchCenter:()=>currentSearchCenter(),
      searchLocal:q=>localPlaceSearch(q,currentSearchCenter(),60),searchLocalAt:(q,c)=>localPlaceSearch(q,c,60),searchLocalAll:(q,c=currentSearchCenter())=>allLocalPlaceSearch(q,c),
      searchFull:q=>geocodeAddress(q),searchFullAt:(q,c)=>geocodeAddress(q,{center:c}),
      searchPoi:(q,c=currentSearchCenter())=>searchNearbyPoi(q,c,5200),
      searchApple:(q,c=currentSearchCenter(),radiusM=3000)=>nativeAppleSearch(q,c,radiusM),
      searchRemote:async(q,signal,c=currentSearchCenter())=>{if(!c||state.nativeNetworkOnline===false)return [];const u=new URL('/api/search-suggest',location.origin);u.searchParams.set('q',q);u.searchParams.set('lat',c.lat.toFixed(3));u.searchParams.set('lng',c.lng.toFixed(3));const r=await fetch(u,{signal,headers:{Accept:'application/json'}});if(!r.ok)return [];return (await r.json()).results||[];},
      mergeSearch:(groups,c=currentSearchCenter())=>mergeAddressSearchResults(groups,c),
      parse:parseDestination,isMaps:looksLikeGoogleMapsShare,resolve:resolveGoogleMapsShare,
      selectPoint:point=>{setDestination(point,{fit:true,persist:true});rememberSearchSelectedDestination(point);},
      selectResult:r=>{const p={lat:Number(r.lat),lng:Number(r.lng),__sourceMeta:{kind:'search',source:r.source||'search',targetText:r.address||r.displayName||'',placeName:r.approximate?'':(r.name||(!looksLikeStreetAddressQuery(r.displayName||'')?r.displayName:'')),addressText:r.address||'',approximate:!!r.approximate}};setDestination(p,{fit:true,persist:true});rememberSearchSelectedDestination(p);},
      refreshSettings:()=>{setTheme(localStorage.getItem('581-door-theme')==='light'?'light':'dark');if(localStorage.getItem('581-door-pip-view')!==null)setPipView(localStorage.getItem('581-door-pip-view')==='1');setAvoidAreaOverlay(localStorage.getItem('581-avoid-overlay-visible-v1')!=='0');avoidAreasChanged();}
    });
    window.__581DoorMapCanary.plannerDiagnostics=planner.diagnostics;
    window.__581DoorMapCanary.openRouteEditor=planner.openEditor;
  }

  async function checkRuntimeRelease() {
    try{
      const r=await fetch('/release.json?ts='+Date.now(),{cache:'no-store',headers:{Accept:'application/json'}});
      if(!r.ok)return;
      const info=await r.json(),want=String(info?.version||'').trim(),have=VERSION.replace(/-standalone$/,'');
      if(!want||want===have||state.navigationActive||state.navigationRequested)return;
      const u=new URL(location.href);if(u.searchParams.get('__build')===want)return;
      u.searchParams.set('__build',want);location.replace(u.href);
    }catch(_){}
  }

  document.body.dataset.theme = state.theme;
  window.DoorNativeBundle.installStateBridge({state,map,inset,cameraInteraction,locationError:onPositionError,position:onPosition,setDestination,acceptDeliveryRoute,setMode,clearDestination:()=>{stopFitLock('clear-destination');const enabled=state.routeEnabled;setRouteEnabled(false,{persist:false,request:false});state.destination=null;state.rawDestination=null;state.destinationIntent=null;state.destinationInfo={};state.navigationActive=false;state.navigationRequested=false;window.__581AppleDestination=false;for(const k of ['581-door-dest','581-door-dest-raw','581-door-dest-meta'])localStorage.removeItem(k);stabilizeBrowserUrl();clearNearbyPoiMarkers();setRouteEnabled(enabled,{persist:false,request:false});updateDestinationInfoUi();renderAll();syncMainScene();syncInsetScene();syncCameraControls();}});
  setHudCollapsed(true);
  setInsetCollapsed(true);
  setMoreOpen(false);
  syncCameraControls();
  setAvatarMode(state.avatarMode,{persist:false});
  if (els.themeBtn) {
    els.themeBtn.querySelector('.more-icon').textContent = state.theme === 'dark' ? '☾' : '☀';
    els.themeBtn.classList.toggle('active', state.theme === 'dark');
  }
  setRouteEnabled(state.routeEnabled,{persist:false,request:false});
  // Kick destination intake first so a Shortcut handoff is captured immediately.
  // GPS starts right after; neither path blocks the other.
  initializeOfflinePack();
  loadInitialDestination();
  scheduleOcrDestSyncBurst('startup');
  autoStartRememberedSensors();
  // Warm the compact local POI index before the rider needs search. A slow first
  // body download is allowed to finish; later searches then come from IndexedDB.
  setTimeout(()=>window.DoorLocalSearch?.ensure?.().catch(err=>console.warn('local search prewarm',err)),650);
  setTimeout(checkRuntimeRelease,2500);
  setInterval(checkRuntimeRelease,300000);
  document.addEventListener('visibilitychange',()=>{if(!document.hidden)setTimeout(checkRuntimeRelease,350);});
})();
