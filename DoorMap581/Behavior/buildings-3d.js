/* 581 Door Map v0.3.51 — address-first place/building highlight + virtual frontage lot fallback.
 * Reuses the base map's building source. No new tile service, DEM, model,
 * camera/GPS owner, animation loop, or mutation of the door-number layer.
 * The displayed heights are compressed illustrations, not surveyed heights.
 */
(function(root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.DoorBuildings3D = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function() {
  'use strict';
  const KEY = '581-door-buildings3d-v1';
  const BUILDINGS = 'extra-buildings-3d';
  const ROOF = 'extra-destination-roof-3d';
  const ROOF_MEDIUM = 'extra-destination-roof-3d-medium';
  const OUTLINE = 'extra-destination-building-outline';
  const TARGET = 'extra-destination-building';
  const ENVELOPE='extra-destination-envelope', EDGES='extra-destination-edges-3d', EDGES_MEDIUM='extra-destination-edges-3d-medium';
  const F=typeof module==='object'&&module.exports ? require('./target-envelope.js') : globalThis.DoorTargetEnvelope;
  const FLOOR='extra-destination-ground-fill', GROUND_LABEL='extra-destination-ground-label';
  const S=typeof module==='object'&&module.exports ? require('./target-selection.js') : globalThis.DoorTargetSelection;
  const IDS = [BUILDINGS, FLOOR, ROOF, ROOF_MEDIUM, EDGES, EDGES_MEDIUM, OUTLINE, GROUND_LABEL];
  const START_ZOOM = 16.65, FULL_ZOOM = 17.35, LOWER_ZOOM = 19.05, END_ZOOM = 19.55;
  const INTERVAL = 650, MAX_FEATURES = 6000, MAX_VERTICES = 12000, SITE_CACHE_LIMIT = 8;
  const empty = () => ({type:'FeatureCollection', features:[]});
  const now = () => typeof performance !== 'undefined' ? performance.now() : Date.now();
  const validPoint = p => p && Number.isFinite(p.lng) && Number.isFinite(p.lat) && Math.abs(p.lng) <= 180 && Math.abs(p.lat) <= 85;
  const positive = v => { if (v === null || v === '' || typeof v === 'boolean') return null; const n=Number(v); return Number.isFinite(n) && n>0 ? n : null; };
  const yes = v => v === true || v === 1 || v === 'true' || v === 'yes' || v === '1';
  const excluded = p => yes(p.hide_3d) || yes(p.underground) || p.location === 'underground' || p.building === 'no';
  function heights(p={}) {
    const levels=positive(p['building:levels']) || positive(p.levels);
    const raw=positive(p.render_height) || positive(p.height) || positive(p['building:height']) || (levels ? levels*3 : 9);
    const h=Math.min(60,Math.max(4,raw));
    const rawBase=Math.max(0, Number(p.render_min_height ?? p.min_height ?? 0) || 0);
    return {height:h, base:Math.min(h,rawBase), approximate:true};
  }
  // Numeric schema fields only. Bad or unit-bearing values fall back safely,
  // rather than claiming a guessed string is a reliable metre measurement.
  function firstPositiveExpr(keys, fallback) {
    const out=['case'];
    for (const key of keys) out.push(['>', ['to-number',['get',key],0],0], ['to-number',['get',key],0]);
    out.push(fallback); return out;
  }
  function heightExpr() {
    const levels=firstPositiveExpr(['building:levels','levels'],3);
    const raw=firstPositiveExpr(['render_height','height','building:height'],['*',levels,3]);
    return ['min',60,['max',4,raw]];
  }
  function baseExpr() {
    return ['min',heightExpr(),['max',0,['to-number',['coalesce',['get','render_min_height'],['get','min_height'],0],0]]];
  }
  function zoomFactor(z) {
    if (!Number.isFinite(z) || z<=START_ZOOM || z>=END_ZOOM) return 0;
    if (z<17.05) return (z-START_ZOOM)/.4*.30;
    if (z<FULL_ZOOM) return .30+(z-17.05)/(FULL_ZOOM-17.05)*.70;
    if (z<=LOWER_ZOOM) return 1;
    return (END_ZOOM-z)/(END_ZOOM-LOWER_ZOOM);
  }
  // A top-level zoom interpolation is deliberately used: valid in both the
  // deployed MapLibre 5.12.0 and older engines, with continuous native scaling.
  function zoomHeight(expr) {
    return ['interpolate',['linear'],['zoom'],START_ZOOM,0,17.05,['*',expr,.30],FULL_ZOOM,expr,LOWER_ZOOM,expr,END_ZOOM,0];
  }
  const palette = theme => theme==='light' ? {building:'#c8d1d8',target:'#c5a66b',roof:'#dfb35f',edge:'#c57f22'} : {building:'#566575',target:'#9a7d4e',roof:'#d1a153',edge:'#efb04e'};
  function discover(style) {
    if (!style || !Array.isArray(style.layers)) return null;
    // Exact building source-layer, never landuse/community/place polygons.
    const matches=style.layers.filter(l=>!String(l.id).startsWith('extra-') &&
      (l.type==='fill' || l.type==='fill-extrusion') && style.sources?.[l.source] &&
      (l['source-layer']==='building' || (!l['source-layer'] && style.sources[l.source].type==='geojson' && /^building(?:$|[-_])/.test(l.id))));
    const l=matches.find(l=>l.type==='fill') || matches[0];
    return l ? {source:l.source, sourceLayer:l['source-layer'] || null, layer:l.id} : null;
  }
  function filterExpr() {
    return ['all',['==',['geometry-type'],'Polygon'],
      ['!', ['in',['to-string',['coalesce',['get','hide_3d'],false]],['literal',['true','1','yes']]]],
      ['!', ['in',['to-string',['coalesce',['get','underground'],false]],['literal',['true','1','yes']]]],
      ['!=',['get','location'],'underground'],['!=',['get','building'],'no']];
  }
  function layers(descriptor,theme='dark',category='commercial') {
    const p={...palette(theme),edge:S.color(category,theme)};
    const building={id:BUILDINGS,type:'fill-extrusion',source:descriptor.source,minzoom:START_ZOOM,maxzoom:END_ZOOM,
      filter:filterExpr(),layout:{visibility:'none'},paint:{
        'fill-extrusion-height':zoomHeight(heightExpr()),'fill-extrusion-base':zoomHeight(baseExpr()),
        'fill-extrusion-color':p.building,
        'fill-extrusion-opacity':.93,'fill-extrusion-vertical-gradient':true,
        'fill-extrusion-height-transition':{duration:0},'fill-extrusion-base-transition':{duration:0}}};
    if (descriptor.sourceLayer) building['source-layer']=descriptor.sourceLayer;
    return [building,
      // Explicit opaque ground color, not merely a footprint LINE. Placed after
      // all base-map fills (including late building fills) and before labels/route.
      {id:FLOOR,type:'fill',source:TARGET,minzoom:START_ZOOM,maxzoom:END_ZOOM,
        layout:{visibility:'none'},paint:{'fill-color':p.edge,'fill-opacity':['case',['==',['get','virtual'],1],.22,['==',['get','confidence'],'medium'],.55,1],'fill-antialias':true}},
      // Legacy layer ID retained; this now tints the WHOLE target body, not a
      // wafer-thin roof. The same hue covers walls/base/roof. Beams share it.
      {id:ROOF,type:'fill-extrusion',source:ENVELOPE,minzoom:START_ZOOM,maxzoom:END_ZOOM,
        filter:['all',['==',['get','part'],'body'],['!=',['get','confidence'],'medium']],layout:{visibility:'none'},paint:{
        'fill-extrusion-height':zoomHeight(['get','high']),
        'fill-extrusion-base':zoomHeight(['get','low']),
        'fill-extrusion-color':p.edge,'fill-extrusion-opacity':.86,'fill-extrusion-vertical-gradient':false,
        'fill-extrusion-height-transition':{duration:0},'fill-extrusion-base-transition':{duration:0}}},
      {id:ROOF_MEDIUM,type:'fill-extrusion',source:ENVELOPE,minzoom:START_ZOOM,maxzoom:END_ZOOM,
        filter:['all',['==',['get','part'],'body'],['==',['get','confidence'],'medium']],layout:{visibility:'none'},paint:{
        'fill-extrusion-height':zoomHeight(['get','high']),
        'fill-extrusion-base':zoomHeight(['get','low']),
        'fill-extrusion-color':p.edge,'fill-extrusion-opacity':.56,'fill-extrusion-vertical-gradient':false,
        'fill-extrusion-height-transition':{duration:0},'fill-extrusion-base-transition':{duration:0}}},
      {id:EDGES,type:'fill-extrusion',source:ENVELOPE,minzoom:START_ZOOM,maxzoom:END_ZOOM,
        filter:['all',['==',['get','part'],'edge'],['!=',['get','confidence'],'medium']],layout:{visibility:'none'},paint:{
        'fill-extrusion-height':zoomHeight(['get','high']),'fill-extrusion-base':zoomHeight(['get','low']),
        'fill-extrusion-color':p.edge,'fill-extrusion-opacity':.96,'fill-extrusion-vertical-gradient':false,
        'fill-extrusion-height-transition':{duration:0},'fill-extrusion-base-transition':{duration:0}}},
      {id:EDGES_MEDIUM,type:'fill-extrusion',source:ENVELOPE,minzoom:START_ZOOM,maxzoom:END_ZOOM,
        filter:['all',['==',['get','part'],'edge'],['==',['get','confidence'],'medium']],layout:{visibility:'none'},paint:{
        'fill-extrusion-height':zoomHeight(['get','high']),'fill-extrusion-base':zoomHeight(['get','low']),
        'fill-extrusion-color':p.edge,'fill-extrusion-opacity':.68,'fill-extrusion-vertical-gradient':false,
        'fill-extrusion-height-transition':{duration:0},'fill-extrusion-base-transition':{duration:0}}},
      {id:OUTLINE,type:'line',source:TARGET,minzoom:START_ZOOM,maxzoom:END_ZOOM,
        layout:{visibility:'none','line-join':'round'},paint:{'line-color':p.edge,'line-opacity':['case',['==',['get','virtual'],1],.96,['==',['get','confidence'],'medium'],.48,.72],'line-width':['case',['==',['get','virtual'],1],1.8,1.35]}},
      {id:GROUND_LABEL,type:'symbol',source:TARGET,minzoom:START_ZOOM,maxzoom:END_ZOOM,
        filter:['all',['==',['get','virtual'],1],['==',['get','labelPoint'],1]],layout:{visibility:'none','symbol-placement':'point','text-field':['get','label'],'text-font':['Noto Sans Regular'],'text-size':12,'text-anchor':'center','text-rotation-alignment':'viewport','text-pitch-alignment':'viewport','text-allow-overlap':true,'text-ignore-placement':true},
        paint:{'text-color':p.edge,'text-halo-color':theme==='light'?'rgba(255,255,255,.96)':'rgba(18,23,30,.96)','text-halo-width':1.6,'text-halo-blur':.15}}];
  }
  // Strict geometry, including holes and multiple polygons. No nearest-building
  // snap: a Pin outside/on a boundary never lights a guessed neighbouring house.
  function geometryOK(g) {
    if (!g || !['Polygon','MultiPolygon'].includes(g.type)) return false;
    const polys=g.type==='Polygon'?[g.coordinates]:g.coordinates;
    if (!Array.isArray(polys) || !polys.length) return false;
    let n=0;
    return polys.every(poly=>Array.isArray(poly)&&poly.length&&poly.every(ring=>{
      if (!Array.isArray(ring)||ring.length<4 || (n+=ring.length)>MAX_VERTICES) return false;
      const a=ring[0], b=ring[ring.length-1];
      return a?.[0]===b?.[0] && a?.[1]===b?.[1] && ring.every(p=>Array.isArray(p)&&p.length>=2&&Number.isFinite(p[0])&&Number.isFinite(p[1])&&Math.abs(p[0])<=180&&Math.abs(p[1])<=85);
    }));
  }
  function ringHit(p,ring) {
    let inside=false;
    for (let i=0,j=ring.length-1;i<ring.length;j=i++) {
      const a=ring[j],b=ring[i],dx=b[0]-a[0],dy=b[1]-a[1],len=dx*dx+dy*dy;
      const t=len?Math.max(0,Math.min(1,((p.lng-a[0])*dx+(p.lat-a[1])*dy)/len)):0;
      if (Math.hypot(p.lng-a[0]-t*dx,p.lat-a[1]-t*dy)<1e-9) return 0;
      if ((a[1]>p.lat)!==(b[1]>p.lat) && p.lng < (b[0]-a[0])*(p.lat-a[1])/(b[1]-a[1])+a[0]) inside=!inside;
    }
    return inside?1:-1;
  }
  function contains(p,g) {
    if (!validPoint(p)||!geometryOK(g)) return false;
    const polys=g.type==='Polygon'?[g.coordinates]:g.coordinates;
    return polys.some(poly=>ringHit(p,poly[0])===1 && poly.slice(1).every(h=>ringHit(p,h)===-1));
  }
  function chooseBuilding(features,destination) {
    if (!validPoint(destination)) return {feature:null,reason:'no-destination',examined:0};
    if (!Array.isArray(features)) return {feature:null,reason:'no-buildings',examined:0};
    if (features.length>MAX_FEATURES) return {feature:null,reason:'too-many',examined:0};
    // querySourceFeatures includes buffered copies from adjacent tiles. Prefer
    // the canonical tile containing the Pin, not copies outside their own tile.
    // Keep the source geometry (possibly clipped); do not reconstruct a building
    // or treat a tile-local numeric ID as globally unique.
    const ownsPin=f=>{const t=f.tile;if(!t||![t.z,t.x,t.y].every(Number.isFinite))return false;
      const n=2**t.z,lat=destination.lat*Math.PI/180;
      return Math.floor((destination.lng+180)/360*n)===t.x &&
        Math.floor((1-Math.asinh(Math.tan(lat))/Math.PI)/2*n)===t.y;};
    const owned=features.filter(ownsPin),candidates=owned.length?owned:features;
    const matches=new Map();let examined=0;
    for (const f of candidates) {
      examined++;
      if (excluded(f.properties||{}) || !contains(destination,f.geometry)) continue;
      const pieces=f.geometry.type==='MultiPolygon'?f.geometry.coordinates.map(coordinates=>({type:'Polygon',coordinates})):[f.geometry];
      for(const geometry of pieces){
        if(!contains(destination,geometry))continue;
        const key=JSON.stringify([f.id??null,geometry]);
        // Same ID + same geometry is a duplicate tile copy. Repeated IDs with
        // different overlapping geometry are ambiguous; never highlight them all.
        if(!matches.has(key))matches.set(key,{...f,geometry});
      }
    }
    if (matches.size!==1) return {feature:null,reason:matches.size?'ambiguous':'not-inside',examined};
    return {feature:[...matches.values()][0],reason:'contained',examined};
  }
  class Controller {
    constructor(map,{getState=()=>({}),storage=null,toggle=null,status=null,documentRef=null,onChange=()=>{}}={}) {
      this.map=map;this.getState=getState;this.onChange=onChange;this.reportKey='';this.storage=storage;this.toggle=toggle;this.status=status;this.doc=documentRef;
      this.enabled=true;this.persistFailed=!this.storage;
      try {this.enabled=this.storage?.getItem(KEY)!=='0';}catch(_){this.persistFailed=true;}
      this.descriptor=null;this.bound=false;this.installing=false;this.error='';this.timer=null;this.lastScan=-Infinity;
      this.sceneKey='';this.targetKey='';this.targetData=empty();this.envelopeData=empty();this.targetState=null;this.reason='no-destination';
      this.siteInputs=null;this.siteResult=null;this.targetCategory='commercial';this.targetMode='none';this.siteName='';this.boundarySkipped=0;this.virtualLabel='';this.siteCache=new Map();
      this.active=false;this.theme='dark';this.metrics={installs:0,scans:0,lastScanMs:0,maxScanMs:0,examined:0,targetSubmits:0};
    }
    init() {
      if (this.bound) return;this.bound=true;
      this.onStyle=()=>{if(this.ensure())this.sync();};
      this.onReload=()=>{this.descriptor=null;this.targetState=null;this.targetKey='';this.targetData=empty();this.envelopeData=empty();this.error='';this.onStyle();this.queue();};
      this.onZoom=e=>{if(e?.doorVisualFrame&&!e.doorVisualRefresh)return;this.sync();};
      this.onMove=e=>{if(e?.doorVisualFrame&&!e.doorVisualRefresh)return;this.sync();this.queue();};
      this.onData=e=>{if(e.sourceId===this.descriptor?.source && e.isSourceLoaded && e.sourceDataType!=='visibility')this.queue();};
      this.onVisibility=()=>{if(this.doc?.hidden){clearTimeout(this.timer);this.timer=null;this.syncVisibility();}else {this.sync();this.queue();}};
      this.onToggle=()=>this.setEnabled(!!this.toggle.checked);
      this.onError=e=>{if(e.sourceId===TARGET || e.sourceId===ENVELOPE || IDS.some(id=>String(e.error?.message||'').includes(id))) {
        this.error=String(e.error?.message||'3D 圖層錯誤').slice(0,160);this.syncVisibility();this.report();
      }};
      this.map.on('style.load',this.onReload);this.map.on('load',this.onStyle);this.map.on('styledata',this.onStyle);
      this.map.on('zoom',this.onZoom);this.map.on('moveend',this.onMove);this.map.on('sourcedata',this.onData);this.map.on('error',this.onError);
      this.doc?.addEventListener('visibilitychange',this.onVisibility);this.toggle?.addEventListener('change',this.onToggle);
      this.ensure();this.sync();this.queue();
    }
    ensure() {
      if(this.installing||this.error)return false;
      if(this.descriptor&&IDS.every(id=>this.map.getLayer(id))&&this.map.getSource(TARGET)&&this.map.getSource(ENVELOPE))return true;
      this.installing=true;
      try {
        const style=this.map.getStyle?.();if(!style?.layers)return false;
        this.descriptor=discover(style);if(!this.descriptor){this.report();return false;}
        if(!this.map.getSource(TARGET))this.map.addSource(TARGET,{type:'geojson',data:this.targetData,maxzoom:20,tolerance:0,buffer:64});
        if(!this.map.getSource(ENVELOPE))this.map.addSource(ENVELOPE,{type:'geojson',data:this.envelopeData,maxzoom:20,tolerance:0,buffer:128});
        const before=this.beforeLayer(style);
        for(const spec of layers(this.descriptor,this.theme,this.targetCategory))if(!this.map.getLayer(spec.id))this.map.addLayer(spec,before);
        // A base style may ship its own optional 3D layer. Never stack it with
        // ours or let it reappear when the user explicitly selected 2D.
        for(const l of style.layers)if(l.type==='fill-extrusion'&&!IDS.includes(l.id)&&l.source===this.descriptor.source&&l['source-layer']===this.descriptor.sourceLayer)
          this.map.setLayoutProperty(l.id,'visibility','none');
        this.metrics.installs++;this.syncVisibility();return true;
      }catch(e){this.error=String(e.message||e).slice(0,160);this.syncVisibility();this.report();return false;}
      finally {this.installing=false;}
    }
    beforeLayer(style) {
      return (style.layers||[]).find(l=>!IDS.includes(l.id)&&(l.type==='symbol'||l.id==='accuracy-fill'||/^main-|^delivery-/.test(l.id)))?.id;
    }
    targetBeforeLayer(style) {
      // Some base styles place an early symbol before a LATER building fill.
      // Insert only after the last background ground fill/line, never underneath
      // a grey 2D footprint. Ordinary road labels and operational UI stay above.
      const operational=l=>l.id==='accuracy-fill'||/^main-|^delivery-|^reference-route|^alternate-route|^dest-guide|^extra-house/.test(l.id);
      const ls=style.layers||[];let last=-1;
      ls.forEach((l,i)=>{if(!IDS.includes(l.id)&&!operational(l)&&['fill','line','fill-extrusion','raster','hillshade','background'].includes(l.type))last=i;});
      return ls.find((l,i)=>i>last&&!IDS.includes(l.id)&&(l.type==='symbol'||operational(l)))?.id;
    }
    order() {
      if(!this.descriptor||!IDS.every(id=>this.map.getLayer(id)))return;
      const style=this.map.getStyle?.();if(!style)return;
      // Preserve the ordinary grey building insertion point. Only TARGET
      // surfaces must be after later grey 2D fills, otherwise their floor is
      // painted black again. Compare a complete desired order to avoid repeated
      // moves/styledata recursion when both groups share the same anchor.
      const rest=(style.layers||[]).filter(l=>!IDS.includes(l.id));
      const clean={...style,layers:rest};
      const ordinaryBefore=this.beforeLayer(clean),targetBefore=this.targetBeforeLayer(clean)||ordinaryBefore;
      const wanted=rest.map(l=>l.id),targetIds=IDS.filter(id=>id!==BUILDINGS);
      const insert=(ids,before)=>{const i=before?wanted.indexOf(before):-1;wanted.splice(i<0?wanted.length:i,0,...ids);};
      insert([BUILDINGS],ordinaryBefore);insert(targetIds,targetBefore);
      const actual=style.layers.map(l=>l.id);if(actual.every((id,i)=>id===wanted[i]))return;
      this.map.moveLayer(BUILDINGS,ordinaryBefore);for(const id of targetIds)this.map.moveLayer(id,targetBefore);
    }
    selectionContext(state=this.getState()||{}) {
      const d=state.destination,inputs=[state.communityItems,state.placeItems,state.addressCandidates,state.entranceItems,d?.lat,d?.lng,state.destinationInfo?.parentName,state.destinationInfo?.placeName,state.destinationInfo?.houseNumber,state.destinationInfo?.road];
      if(!this.siteInputs||inputs.some((v,i)=>v!==this.siteInputs[i])){this.siteInputs=inputs;this.siteResult=S.region(state);}
      return this.siteResult;
    }
    sync() {
      const state=this.getState()||{},d=validPoint(state.destination)?state.destination:null;
      const context=this.selectionContext(state);
      const a=context.address?.point,key=d?`${d.lng},${d.lat}|${a?.lng||''},${a?.lat||''}|${context.site?.key||context.reason}|${state.areaDestination?'area':'building'}`:'';
      const changed=key!==this.sceneKey;
      if(changed){this.sceneKey=key;this.boundarySkipped=0;this.clearTarget();this.reason=context.site?'place-awaiting-buildings':(context.reason==='ambiguous-place'?'ambiguous-place':(d?'not-inside':'no-destination'));}
      if(state.theme&&state.theme!==this.theme)this.setTheme(state.theme);
      const active=this.enabled&&!this.error&&!this.doc?.hidden&&zoomFactor(Number(this.map.getZoom()))>0;
      const entered=active&&!this.active;this.active=active;
      this.syncVisibility();this.order();this.report();
      if(changed||entered)this.queue();
    }
    syncVisibility() {
      const visible=this.enabled&&!this.error&&!this.doc?.hidden&&zoomFactor(Number(this.map.getZoom()))>0?'visible':'none';
      for(const id of IDS)if(this.map.getLayer(id)&&this.map.getLayoutProperty(id,'visibility')!==visible)this.map.setLayoutProperty(id,'visibility',visible);
    }
    setEnabled(on) {
      this.enabled=!!on;this.error='';
      try {this.storage?.setItem(KEY,this.enabled?'1':'0');this.persistFailed=!this.storage;}catch(_){this.persistFailed=true;}
      if(!this.enabled){clearTimeout(this.timer);this.timer=null;this.clearTarget();}
      this.ensure();this.sync();if(this.enabled)this.queue();
    }
    setTheme(theme) {
      const next=theme==='light'?'light':'dark';if(this.theme===next)return;this.theme=next;
      const p={...palette(next),edge:S.color(this.targetCategory,next)};
      if(this.map.getLayer(BUILDINGS))this.map.setPaintProperty(BUILDINGS,'fill-extrusion-color',p.building);
      if(this.map.getLayer(FLOOR))this.map.setPaintProperty(FLOOR,'fill-color',p.edge);
      if(this.map.getLayer(ROOF))this.map.setPaintProperty(ROOF,'fill-extrusion-color',p.edge);
      if(this.map.getLayer(ROOF_MEDIUM))this.map.setPaintProperty(ROOF_MEDIUM,'fill-extrusion-color',p.edge);
      if(this.map.getLayer(EDGES))this.map.setPaintProperty(EDGES,'fill-extrusion-color',p.edge);
      if(this.map.getLayer(EDGES_MEDIUM))this.map.setPaintProperty(EDGES_MEDIUM,'fill-extrusion-color',p.edge);
      if(this.map.getLayer(OUTLINE))this.map.setPaintProperty(OUTLINE,'line-color',p.edge);
      if(this.map.getLayer(GROUND_LABEL)){this.map.setPaintProperty(GROUND_LABEL,'text-color',p.edge);this.map.setPaintProperty(GROUND_LABEL,'text-halo-color',next==='light'?'rgba(255,255,255,.96)':'rgba(18,23,30,.96)');}
    }
    queue() {
      if(this.timer!==null||!this.enabled||this.error||this.doc?.hidden||zoomFactor(Number(this.map.getZoom()))<=0||!validPoint(this.getState()?.destination))return;
      this.timer=setTimeout(()=>{this.timer=null;this.scan();},Math.max(0,INTERVAL-(now()-this.lastScan)));
    }
    scan() {
      if(!this.enabled||this.doc?.hidden||this.error||zoomFactor(Number(this.map.getZoom()))<=0||!this.ensure())return;
      const d=this.getState()?.destination;if(!validPoint(d)){this.clearTarget();this.report();return;}
      const state=this.getState()||{},context=this.selectionContext(state);
      if(context.reason==='ambiguous-place'){this.clearTarget();this.reason='ambiguous-place';this.report();return;}
      // An area with no reliable polygon is not an excuse to select the nearest
      // apartment. Region intent only falls back to its existing ground outline.
      if(state.areaDestination&&!context.site){this.clearTarget();this.reason='area-no-confirmed-polygon';this.report();return;}
      const started=now();this.lastScan=started;
      try {
        const options=this.descriptor.sourceLayer?{sourceLayer:this.descriptor.sourceLayer}:{};
        const features=this.map.querySourceFeatures(this.descriptor.source,options);
        if(context.site){
          const result=S.inRegion(features,context.site);this.reason=result.reason;this.metrics.examined=result.examined;this.boundarySkipped=result.boundarySkipped||0;
          const cacheKey=context.site.key,cache=this.siteCache.get(cacheKey)||new Map();
          for(const f of result.features){const k=S.key(f.geometry)+'|'+JSON.stringify([f.properties?.render_height,f.properties?.height,f.properties?.['building:levels'],f.properties?.min_height,f.properties?.render_min_height]);if(!cache.has(k)&&cache.size<S.MAX_SELECTED)cache.set(k,f);}
          if(cache.size)this.rememberSite(cacheKey,cache);
          const selected=[...cache.values()];
          if(selected.length){this.setTargets(selected,context.site.category,'place');this.siteName=context.site.name;this.reason=result.features.length?'place-buildings':'place-buildings-session-cache';}else this.clearTarget();
        }else {
          const address=context.address,pointForBuilding=address?.point||d,route=state.routeDisplayGeoJson||state.routeGeoJson;
          const result=address?S.buildingForAddress(features,pointForBuilding,12,route):S.buildingForCoordinate(features,d,route,14);
          this.reason=result.reason;this.metrics.examined=result.examined||0;this.boundarySkipped=0;
          if(result.feature)this.setTarget(result.feature,result.confidence||'high');
          else if(address){const lot=S.virtualLot(state.addressCandidates||[],address,{destination:d});if(lot.feature){this.setGroundTarget(lot.feature,'residential');this.virtualLabel=lot.label;this.reason=lot.reason;}else this.clearTarget();}
          else this.clearTarget();
        }
      }catch(e){this.reason='query-unavailable';this.clearTarget();}
      finally {this.metrics.scans++;this.metrics.lastScanMs=now()-started;this.metrics.maxScanMs=Math.max(this.metrics.maxScanMs,this.metrics.lastScanMs);this.report();}
    }
    clearTarget() {
      this.targetMode='none';this.siteName='';this.virtualLabel='';
      if(this.targetState) {try{this.map.setFeatureState(this.targetState,{door581Destination:false});}catch(_){}this.targetState=null;}
      if(this.targetKey){this.targetKey='';this.targetData=empty();this.envelopeData=empty();this.map.getSource(TARGET)?.setData(this.targetData);this.map.getSource(ENVELOPE)?.setData(this.envelopeData);this.metrics.targetSubmits++;}
    }
    setTarget(feature,confidence='high') { this.setTargets([feature],'commercial','single',confidence); }
    setGroundTarget(feature,category='residential') {
      const k=JSON.stringify([category,'virtual',feature.geometry,feature.properties?.label||'']);if(k===this.targetKey)return;
      this.clearTarget();this.targetKey=k;this.targetCategory=category;this.targetMode='virtual';this.virtualLabel=String(feature.properties?.label||'');
      const geometry=JSON.parse(JSON.stringify(feature.geometry)),center=S.interior(geometry),features=[{type:'Feature',geometry,properties:{...feature.properties,virtual:1,category}}];
      if(center)features.push({type:'Feature',geometry:{type:'Point',coordinates:[center.lng,center.lat]},properties:{virtual:1,label:this.virtualLabel,category,labelPoint:1}});
      this.targetData={type:'FeatureCollection',features};this.envelopeData=empty();
      this.map.getSource(TARGET)?.setData(this.targetData);this.map.getSource(ENVELOPE)?.setData(this.envelopeData);this.metrics.targetSubmits++;const oldTheme=this.theme;this.theme='';this.setTheme(oldTheme);this.order();
    }
    rememberSite(key,cache) {
      // Session-only LRU: keep the current/last-used sites through tile changes,
      // but do not retain every customer's full building polygons all day.
      this.siteCache.delete(key);this.siteCache.set(key,cache);
      while(this.siteCache.size>SITE_CACHE_LIMIT)this.siteCache.delete(this.siteCache.keys().next().value);
    }
    setTargets(features,category='commercial',mode='single',confidence='high') {
      const prepared=features.map(f=>({feature:f,h:heights(f.properties||{})}));
      const key=JSON.stringify([category,mode,confidence,prepared.map(({feature:f,h})=>[f.id??null,f.geometry,h.height,h.base])]);
      if(key===this.targetKey)return;
      this.clearTarget();this.targetKey=key;this.targetCategory=category;this.targetMode=mode;
      const targets=[],envelope=[];let frames=0;
      for(const {feature:f,h} of prepared){
        targets.push({type:'Feature',geometry:JSON.parse(JSON.stringify(f.geometry)),properties:{displayHeight:h.height,displayBase:h.base,approximate:1,virtual:0,label:'',category,confidence}});
        const built=F?.build(f.geometry,h.height,h.base)||empty();
        // Bound decorative beams across a whole campus. Every selected building
        // still receives its BODY and opaque FLOOR when the edge budget is used.
        for(const part of built.features){if(part.properties.part==='edge'&&frames>=4096)continue;if(part.properties.part==='edge')frames++;envelope.push({...part,properties:{...part.properties,confidence}});}
      }
      this.targetData={type:'FeatureCollection',features:targets};
      this.envelopeData={type:'FeatureCollection',features:envelope,frameReason:frames>=4096?'edge-budget-body-floor-retained':'native-beams'};
      this.map.getSource(TARGET)?.setData(this.targetData);this.map.getSource(ENVELOPE)?.setData(this.envelopeData);this.metrics.targetSubmits++;
      const oldTheme=this.theme;this.theme='';this.setTheme(oldTheme);this.order();
    }
    report() {
      if(this.toggle)this.toggle.checked=this.enabled;
      const k=JSON.stringify([this.enabled,this.active,this.targetKey,this.reason,this.theme,this.error]);
      if(k!==this.reportKey){this.reportKey=k;this.onChange();}
      if(!this.status)return;
      const z=Number(this.map.getZoom());let text;
      if(!this.enabled)text='已關閉 · 永遠維持 2D；已記住選擇';
      else if(this.error)text='3D 暫不可用，維持 2D：'+this.error;
      else if(!this.descriptor)text='等待底圖建築資料；無輪廓處維持 2D';
      else if(z<=START_ZOOM)text='3D 已開啟 · 拉近才立起建築；遠距維持 2D';
      else if(z>=END_ZOOM)text='最近門牌視角 · 暫回 2D，保留原始門牌';
      else {
        text='3D 自適應導航 · 非目標框淡化；鄰近門牌保留 · 樓高為示意';
        if(this.targetKey){
          if(this.targetMode==='place')text+=` · 場所內 ${this.targetData.features.length} 個建築輪廓已提亮`;
          else if(this.targetMode==='virtual')text+=` · ${this.virtualLabel||'門牌'} 地面輔助框（底圖無可用建築輪廓）`;
          else text+=' · 地址對應單棟底牆頂同色／立體邊線';
        } else if(this.sceneKey)text+=' · 建築歸屬未確認，保留 Pin／場所地面框';
        if(this.boundarySkipped)text+=` · ${this.boundarySkipped} 個框外建築略過`;
      }
      if(this.persistFailed)text=text.replace('；已記住選擇','')+' · 此瀏覽器無法儲存開關';
      if(this.status.textContent!==text)this.status.textContent=text;
    }
    diagnostics() {
      return {enabled:this.enabled,active:this.enabled&&!this.error&&zoomFactor(Number(this.map.getZoom()))>0,zoom:Number(this.map.getZoom()),heightScale:zoomFactor(Number(this.map.getZoom())),source:this.descriptor,highlight:!!this.targetKey,highlightReason:this.reason,targetEnvelopeFeatures:this.envelopeData.features.length,frameReason:this.envelopeData.frameReason||'',highlightStyle:this.targetMode==='virtual'?'ground-address-box':'solid-floor-body-edges',highlightConfidence:this.targetData.features[0]?.properties?.confidence||'',selectionMode:this.targetMode,targetCategory:this.targetCategory,targetColor:S.color(this.targetCategory,this.theme),siteName:this.siteName,virtualLabel:this.virtualLabel,targetBuildings:this.targetMode==='virtual'?0:this.targetData.features.length,boundarySkipped:this.boundarySkipped,floorLayer:!!this.map.getLayer(FLOOR),cachedSites:this.siteCache.size,siteCacheLimit:SITE_CACHE_LIMIT,error:this.error,persistFailed:this.persistFailed,...this.metrics,newTileServices:0,animationLoops:0};
    }
    destroy() {
      clearTimeout(this.timer);this.timer=null;this.clearTarget();this.siteCache.clear();
      for(const [e,f] of [['style.load',this.onReload],['load',this.onStyle],['styledata',this.onStyle],['zoom',this.onZoom],['moveend',this.onMove],['sourcedata',this.onData],['error',this.onError]])this.map.off(e,f);
      this.doc?.removeEventListener('visibilitychange',this.onVisibility);this.toggle?.removeEventListener('change',this.onToggle);
      for(const id of [...IDS].reverse())if(this.map.getLayer(id))this.map.removeLayer(id);
      if(this.map.getSource(TARGET))this.map.removeSource(TARGET);if(this.map.getSource(ENVELOPE))this.map.removeSource(ENVELOPE);this.bound=false;
    }
  }
  return {Controller,SITE_CACHE_LIMIT,KEY,IDS,BUILDINGS,ROOF,ROOF_MEDIUM,OUTLINE,TARGET,ENVELOPE,EDGES,EDGES_MEDIUM,FLOOR,GROUND_LABEL,START_ZOOM,FULL_ZOOM,END_ZOOM,heights,heightExpr,baseExpr,zoomHeight,zoomFactor,discover,layers,geometryOK,contains,chooseBuilding,filterExpr};
});
