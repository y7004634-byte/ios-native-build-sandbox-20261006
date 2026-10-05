/* Native main-map adapter. The original 0.3.78 planners own state and camera;
 * MKMapView owns main-map pixels and gestures. MapLibre is used only for NLSC.
 * This file consumes public GeoJSON, never Apple tiles/POIs for the inset. */
(function(root,factory){const api=factory(root);if(typeof module==='object'&&module.exports)module.exports=api;else api.install();})(typeof globalThis==='object'?globalThis:this,function(root){
'use strict';
const empty=()=>({type:'FeatureCollection',features:[]}),clamp=(v,a,b)=>Math.max(a,Math.min(b,v));
const signed=x=>((x+540)%360)-180;
function mercator(p){const c=Array.isArray(p)?p:[p.lng,p.lat],lat=clamp(Number(c[1]),-85.051129,85.051129)*Math.PI/180;return {x:(Number(c[0])+180)/360,y:(1-Math.asinh(Math.tan(lat))/Math.PI)/2};}
function geographic(p){return {lng:p.x*360-180,lat:Math.atan(Math.sinh(Math.PI*(1-2*p.y)))*180/Math.PI};}
function evaluate(v,f={},zoom=18,featureState={}){
 if(!Array.isArray(v))return v;
 if(typeof v[0]!=='string'||/\s/.test(v[0]))return v;
 const p=f.properties||{},a=v.slice(1),e=x=>evaluate(x,f,zoom,featureState);
 switch(v[0]){
 case 'literal':return a[0]; case 'get':return (a[1]?e(a[1]):p)?.[a[0]];case 'has':return Object.hasOwn(a[1]?e(a[1]):p,a[0]);
 case 'feature-state':return featureState[a[0]];case 'zoom':return zoom;case 'id':return f.id;case 'geometry-type':return String(f.geometry?.type||'').replace(/^Multi/,'');
 case 'to-number':{for(const x of a){const n=Number(e(x));if(Number.isFinite(n))return n;}return 0;}
 case 'to-string':return String(e(a[0])??'');case 'coalesce':return a.map(e).find(x=>x!==null&&x!==undefined);
 case 'boolean':{const n=e(a[0]);return typeof n==='boolean'?n:e(a[1]);}
 case 'all':return a.every(e);case 'any':return a.some(e);case '!':return !e(a[0]);
 case '==':case '!=':case '>':case '>=':case '<':case '<=':{const l=e(a[0]),r=e(a[1]);return ({'==':()=>l===r,'!=':()=>l!==r,'>':()=>l>r,'>=':()=>l>=r,'<':()=>l<r,'<=':()=>l<=r})[v[0]]();}
 case 'in':return e(a[1])?.includes?.(e(a[0]))||false;
 case 'case':for(let i=0;i<a.length-1;i+=2)if(e(a[i]))return e(a[i+1]);return e(a.at(-1));
 case 'match':{const value=e(a[0]);for(let i=1;i<a.length-1;i+=2)if(Array.isArray(a[i])?a[i].includes(value):a[i]===value)return e(a[i+1]);return e(a.at(-1));}
 case 'step':{const x=Number(e(a[0]));let out=e(a[1]);for(let i=2;i<a.length;i+=2)if(x>=Number(a[i]))out=e(a[i+1]);return out;}
 case 'interpolate':{const x=Number(e(a[1])),pairs=a.slice(2);if(x<=pairs[0])return e(pairs[1]);for(let i=2;i<pairs.length;i+=2)if(x<=pairs[i]){const lo=e(pairs[i-1]),hi=e(pairs[i+1]),t=clamp((x-pairs[i-2])/(pairs[i]-pairs[i-2]),0,1);return typeof lo==='number'&&typeof hi==='number'?lo+(hi-lo)*t:lo;}return e(pairs.at(-1));}
 case 'concat':return a.map(x=>String(e(x)??'')).join('');case 'format':return a.filter((_,i)=>i%2===0).map(x=>String(e(x)??'')).join('');
 case '+':return a.map(e).reduce((s,x)=>s+Number(x),0);case '*':return a.map(e).reduce((s,x)=>s*Number(x),1);case '-':return a.length===1?-Number(e(a[0])):Number(e(a[0]))-Number(e(a[1]));case '/':return Number(e(a[0]))/Number(e(a[1]));
 case 'min':return Math.min(...a.map(e));case 'max':return Math.max(...a.map(e));case 'abs':return Math.abs(e(a[0]));case 'sqrt':return Math.sqrt(e(a[0]));case '^':return Math.pow(e(a[0]),e(a[1]));
 default:if(['top','bottom','left','right','center'].includes(v[0]))return v;throw Error('Unsupported native style expression: '+v[0]);
 }
}
function filter(v,f,z,state){
 if(!v)return true;
 // Legacy filters use property-name operands. Modern expressions use ['get',...].
 if(Array.isArray(v)&&['==','!=','>','>=','<','<=','in','!in','has','!has'].includes(v[0])&&typeof v[1]==='string'){
  const p=v[1]==='$type'?String(f.geometry?.type||'').replace(/^Multi/,''):(f.properties||{})[v[1]];
  if(v[0]==='has')return p!==undefined;if(v[0]==='!has')return p===undefined;if(v[0]==='in')return v.slice(2).includes(p);if(v[0]==='!in')return !v.slice(2).includes(p);
  return evaluate([v[0],['literal',p],['literal',v[2]]],f,z,state);
 }
 if(v?.[0]==='all')return v.slice(1).every(x=>filter(x,f,z,state));if(v?.[0]==='any')return v.slice(1).some(x=>filter(x,f,z,state));if(v?.[0]==='none')return !v.slice(1).some(x=>filter(x,f,z,state));
 return !!evaluate(v,f,z,state);
}
function post(type,payload={}){root.webkit?.messageHandlers?.appleMapEngine?.postMessage({type,payload});}
class NativePointerTracker{
 constructor(){this.contacts=new Set();this.primary=null;}
 packet(data){const id=data.pointerId??1,type=data.phase==='begin'?'pointerdown':data.phase==='end'?'pointerup':data.phase==='cancel'?'pointercancel':'pointermove';if(data.phase==='begin'){this.contacts.add(id);if(this.primary===null)this.primary=id;}const raw={type,pointerId:id,pointerType:'touch',isPrimary:id===this.primary,button:0,buttons:data.phase==='end'||data.phase==='cancel'?0:1,clientX:data.x||0,clientY:data.y||0};if(data.phase==='end'||data.phase==='cancel'){this.contacts.delete(id);if(this.contacts.size===0)this.primary=null;}return raw;}
}
class NativeMap{
 constructor(options){
  this._isNativeApple=true;this.options=options;this.container=root.document.getElementById(options.container);this.canvas=root.document.createElement('div');this.canvas.className='native-map-gesture-surface';this.canvas.style.cssText='position:absolute;inset:0;pointer-events:none';this.container.append(this.canvas);
  this._camera={center:{lng:options.center[0],lat:options.center[1]},zoom:options.zoom,bearing:options.bearing||0,pitch:options.pitch||0};this.sources=new Map();this.layers=[];this.events=new Map();this.images=new Map();this.featureStates=new Map();this.seq=0;this.revision=0;this.sceneTimer=null;this.sceneKey='';this.loaded=false;this.errors=[];this.animation=null;this.markers=new Set();this.nativeDiagnostics={};
  const gestures=['dragPan','scrollZoom','boxZoom','dragRotate','keyboard','doubleClickZoom','touchZoomRotate','touchPitch'];for(const name of gestures)this[name]={enable:()=>{},disable:()=>{}};
  this.addSource('native-osm-buildings',{type:'geojson',data:empty()});this.addLayer({id:'building',type:'fill',source:'native-osm-buildings',filter:['has','building'],layout:{visibility:'none'},paint:{'fill-color':'#88949e','fill-opacity':0}});
  root.__581NativeMap=this;
  setTimeout(()=>{this.loaded=true;this.fire('style.load');this.fire('load');this.fire('idle');this.easeTo({...this._camera,center:options.center,duration:0});},30);
 }
 on(name,layer,fn){if(typeof layer==='function'){fn=layer;layer=null;}if(!this.events.has(name))this.events.set(name,[]);this.events.get(name).push({layer,fn});return this;}
 once(name,fn){const wrap=e=>{this.off(name,wrap);fn(e);};return this.on(name,wrap);}
 off(name,layer,fn){if(typeof layer==='function'){fn=layer;layer=null;}this.events.set(name,(this.events.get(name)||[]).filter(x=>x.layer!==layer||x.fn!==fn));return this;}
 fire(name,event={}){const e={type:name,target:this,...event};for(const x of [...(this.events.get(name)||[])]){if(x.layer){const fs=event.layer===x.layer?event.features:this.queryRenderedFeatures(event.point,{layers:[x.layer]});if(!fs?.length)continue;x.fn({...e,features:fs});}else x.fn(e);}return this;}
 getContainer(){return this.container;}getCanvasContainer(){return this.canvas;}getCanvas(){return this.canvas;}isStyleLoaded(){return this.loaded;}loaded(){return this.loaded;}
 getCenter(){return {...this._camera.center};}getZoom(){return this._camera.zoom;}getPitch(){return this._camera.pitch;}getBearing(){return this._camera.bearing;}
 getBounds(){const w=this.container.clientWidth||390,h=this.container.clientHeight||844,pts=[[0,0],[w,0],[0,h],[w,h]].map(x=>this.unproject(x));const west=Math.min(...pts.map(p=>p.lng)),east=Math.max(...pts.map(p=>p.lng)),south=Math.min(...pts.map(p=>p.lat)),north=Math.max(...pts.map(p=>p.lat));return {getWest:()=>west,getEast:()=>east,getSouth:()=>south,getNorth:()=>north,getNorthEast:()=>({lng:east,lat:north}),getSouthWest:()=>({lng:west,lat:south})};}
 getStyle(){return {version:8,sources:Object.fromEntries([...this.sources].map(([id,s])=>[id,s.spec])),layers:this.layers};}
 addSource(id,spec){if(this.sources.has(id))throw Error('Duplicate source '+id);const map=this;const source={spec:{...spec},_data:spec.data||empty(),setData(data){this._data=data||empty();this.spec.data=this._data;map.revision++;map.scheduleScene();map.fire('sourcedata',{sourceId:id,sourceDataType:'content',isSourceLoaded:true});return this;},getClusterExpansionZoom:async()=>Math.min(19,map.getZoom()+2)};this.sources.set(id,source);this.revision++;this.scheduleScene();return this;}
 getSource(id){return this.sources.get(id);}removeSource(id){this.sources.delete(id);this.revision++;this.scheduleScene();return this;}
 addLayer(layer,before){if(this.getLayer(layer.id))return this;const value={...layer,paint:{...layer.paint},layout:{...layer.layout}};const i=this.layers.findIndex(x=>x.id===before);if(i<0)this.layers.push(value);else this.layers.splice(i,0,value);this.revision++;this.scheduleScene();return this;}
 getLayer(id){return this.layers.find(x=>x.id===id);}removeLayer(id){this.layers=this.layers.filter(x=>x.id!==id);this.revision++;this.scheduleScene();return this;}
 moveLayer(id,before){const l=this.getLayer(id);if(!l)return this;this.layers=this.layers.filter(x=>x!==l);const i=this.layers.findIndex(x=>x.id===before);if(i<0)this.layers.push(l);else this.layers.splice(i,0,l);this.revision++;this.scheduleScene();return this;}
 setPaintProperty(id,k,v){const l=this.getLayer(id);if(l){l.paint[k]=v;this.revision++;this.scheduleScene();}return this;}getPaintProperty(id,k){return this.getLayer(id)?.paint?.[k];}
 setLayoutProperty(id,k,v){const l=this.getLayer(id);if(l){l.layout[k]=v;this.revision++;this.scheduleScene();}return this;}getLayoutProperty(id,k){return this.getLayer(id)?.layout?.[k];}
 setFilter(id,v){const l=this.getLayer(id);if(l){l.filter=v;this.revision++;this.scheduleScene();}return this;}getFilter(id){return this.getLayer(id)?.filter;}
 setFeatureState(key,value){this.featureStates.set(key.source+':'+key.id,{...this.featureStates.get(key.source+':'+key.id),...value});this.revision++;this.scheduleScene();}
 hasImage(id){return this.images.has(id);}addImage(id,img){this.images.set(id,img);}removeImage(id){this.images.delete(id);}triggerRepaint(){this.fire('render');this.scheduleScene();}resize(){post('resize');this.fire('resize');this.scheduleScene();return this;}
 project(p){
  const v=mercator(p),c=mercator(this._camera.center),w=this.container.clientWidth||390,h=this.container.clientHeight||844;
  if(this.homography){const x=v.x-this.homography.origin.x,y=v.y-this.homography.origin.y,H=this.homography.matrix,d=H[6]*x+H[7]*y+1;return {x:(H[0]*x+H[1]*y+H[2])/d,y:(H[3]*x+H[4]*y+H[5])/d};}
  const scale=512*2**this.getZoom(),a=-this.getBearing()*Math.PI/180,dx=(v.x-c.x)*scale,dy=(v.y-c.y)*scale;return {x:w/2+dx*Math.cos(a)-dy*Math.sin(a),y:h/2+(dx*Math.sin(a)+dy*Math.cos(a))*Math.cos(this.getPitch()*Math.PI/180)};
 }
 unproject(p){
  const x=Array.isArray(p)?p[0]:p.x,y=Array.isArray(p)?p[1]:p.y;
  if(this.homography){const H=this.homography.matrix,A=H[0]-x*H[6],B=H[1]-x*H[7],C=x-H[2],D=H[3]-y*H[6],E=H[4]-y*H[7],F=y-H[5],det=A*E-B*D;if(Math.abs(det)>1e-15)return geographic({x:this.homography.origin.x+(C*E-B*F)/det,y:this.homography.origin.y+(A*F-C*D)/det});}
  const w=this.container.clientWidth||390,h=this.container.clientHeight||844,a=this.getBearing()*Math.PI/180,dx=x-w/2,dy=(y-h/2)/Math.max(.2,Math.cos(this.getPitch()*Math.PI/180)),scale=512*2**this.getZoom(),c=mercator(this.getCenter());return geographic({x:c.x+(dx*Math.cos(a)-dy*Math.sin(a))/scale,y:c.y+(dx*Math.sin(a)+dy*Math.cos(a))/scale});
 }
 cameraForBounds(bounds,options={}){
  const sw=Array.isArray(bounds)?{lng:bounds[0][0],lat:bounds[0][1]}:bounds.getSouthWest(),ne=Array.isArray(bounds)?{lng:bounds[1][0],lat:bounds[1][1]}:bounds.getNorthEast(),points=[[sw.lng,sw.lat],[ne.lng,sw.lat],[ne.lng,ne.lat],[sw.lng,ne.lat]],vs=points.map(mercator),a=-(options.bearing||0)*Math.PI/180;
  const rotated=vs.map(v=>({x:v.x*Math.cos(a)-v.y*Math.sin(a),y:v.x*Math.sin(a)+v.y*Math.cos(a)})),minX=Math.min(...rotated.map(v=>v.x)),maxX=Math.max(...rotated.map(v=>v.x)),minY=Math.min(...rotated.map(v=>v.y)),maxY=Math.max(...rotated.map(v=>v.y));
  const p=typeof options.padding==='number'?{top:options.padding,bottom:options.padding,left:options.padding,right:options.padding}:options.padding||{},w=this.container.clientWidth||390,h=this.container.clientHeight||844,aw=Math.max(1,w-(p.left||0)-(p.right||0)),ah=Math.max(1,h-(p.top||0)-(p.bottom||0)),z=Math.min(options.maxZoom??22,Math.log2(Math.min(aw/Math.max(1e-12,maxX-minX),ah/Math.max(1e-12,maxY-minY))/512));
  const scale=512*2**z,rx=(minX+maxX)/2+((p.right||0)-(p.left||0))/2/scale,ry=(minY+maxY)/2+((p.bottom||0)-(p.top||0))/2/scale;
  return {center:geographic({x:rx*Math.cos(-a)-ry*Math.sin(-a),y:rx*Math.sin(-a)+ry*Math.cos(-a)}),zoom:z,bearing:options.bearing||0};
 }
 fitBounds(b,o={}){const plan=this.cameraForBounds(b,o);return this.easeTo({...o,...plan,padding:{top:0,bottom:0,left:0,right:0}});}
 jumpTo(o){return this.easeTo({...o,duration:0});}setCenter(p){return this.jumpTo({center:p});}setZoom(z){return this.jumpTo({zoom:z});}setBearing(a){return this.jumpTo({bearing:a});}setPitch(p){return this.jumpTo({pitch:p});}
 easeTo(options,eventData={}){
  this.stop(false);const previous={...this._camera,center:{...this._camera.center}},center=options.center?(Array.isArray(options.center)?{lng:Number(options.center[0]),lat:Number(options.center[1])}:{lng:Number(options.center.lng),lat:Number(options.center.lat)}):previous.center;
  const target={center,zoom:Number.isFinite(options.zoom)?options.zoom:previous.zoom,bearing:Number.isFinite(options.bearing)?options.bearing:previous.bearing,pitch:Number.isFinite(options.pitch)?options.pitch:previous.pitch};
  const start=root.performance.now(),duration=Math.max(0,Number(options.duration)||0),easing=options.easing||((t)=>1-(1-t)**3),write=t=>{
   const q=easing(t);this._camera={center:{lng:previous.center.lng+(target.center.lng-previous.center.lng)*q,lat:previous.center.lat+(target.center.lat-previous.center.lat)*q},zoom:previous.zoom+(target.zoom-previous.zoom)*q,bearing:previous.bearing+signed(target.bearing-previous.bearing)*q,pitch:previous.pitch+(target.pitch-previous.pitch)*q};this.homography=null;
   post('camera',{...this._camera,padding:options.padding||{},offset:options.offset||[0,0],sequence:++this.seq,issuedAt:Date.now()});this.fire('move',eventData);if(previous.zoom!==target.zoom)this.fire('zoom',eventData);this.updateMarkers();this.fire('render',eventData);
  };
  const finish=()=>{this.animation=null;this.fire('moveend',eventData);this.fire('idle',eventData);this.scheduleScene();};
  if(duration===0){write(1);finish();}else{const tick=()=>{const t=clamp((root.performance.now()-start)/duration,0,1);write(t);if(t<1)this.animation=root.requestAnimationFrame(tick);else finish();};this.animation=root.requestAnimationFrame(tick);}return this;
 }
 stop(notify=true){if(this.animation!==null)root.cancelAnimationFrame(this.animation);this.animation=null;if(notify)post('stopCamera');return this;}
 updateMarkers(){for(const m of this.markers)m.update();}
 sourceFeatures(id){const d=this.getSource(id)?._data;if(typeof d==='string')return [];return d?.type==='FeatureCollection'?d.features:d?.type==='Feature'?[d]:[];}
 querySourceFeatures(id){return this.sourceFeatures(id);}
 queryRenderedFeatures(point,options={}){
  if(point&&point.layers&&!options.layers){options=point;point=null;}
  const fs=[],xy=point?(Array.isArray(point)?{x:point[0],y:point[1]}:point):null;
  for(const l of this.layers){if(options.layers&&!options.layers.includes(l.id)||l.layout?.visibility==='none'||this.getZoom()<(l.minzoom??0)||this.getZoom()>=(l.maxzoom??100))continue;
   for(const f of this.sourceFeatures(l.source)){try{if(!filter(l.filter,f,this.getZoom(),this.featureStates.get(l.source+':'+f.id)))continue;}catch(_){continue;}
    if(xy&&!hitFeature(f,xy,p=>this.project(p),l))continue;
    if(!xy&&!visibleFeature(f,p=>this.project(p),this.container.clientWidth,this.container.clientHeight))continue;
    fs.push({...f,layer:l,source:l.source});}
  }return fs;
 }
 nativeUpdate(data){
  if(data.gesture||Number(data.sequence)>=this.seq){if(data.camera)this._camera=data.camera;if(data.homography)this.homography=data.homography;this.nativeDiagnostics=data.diagnostics||{};this.updateMarkers();if(data.gesture){this.fire('move',{originalEvent:{type:'pointermove'}});this.fire('zoom',{originalEvent:{type:'pointermove'}});this.scheduleScene();}}
 }
 nativeGesture(data){if(data.transform){this.fire(data.transform,{originalEvent:{type:'pointermove'}});return;}this.nativePointers??=new NativePointerTracker();const raw=this.nativePointers.packet(data);this.canvas.dispatchEvent(new root.PointerEvent(raw.type,{bubbles:true,...raw}));if(data.phase==='begin')this.stop();if((data.phase==='end'||data.phase==='cancel')&&data.remaining===0){this.fire('zoomend',{originalEvent:raw});this.fire('moveend',{originalEvent:raw});this.fire('idle');}}
 nativeClick(data){const p={x:data.x,y:data.y},lngLat=data.lngLat||this.unproject(p),event={point:p,lngLat,originalEvent:{type:'click',preventDefault(){},stopPropagation(){}}};this.lastMapClick={point:p,lngLat};this.fire(data.longPress?'contextmenu':'click',event);}
 scheduleScene(){if(this.sceneTimer!==null)return;this.sceneTimer=root.setTimeout(()=>{this.sceneTimer=null;this.sendScene();},90);}
 sendScene(){
  if(!this.loaded||root.document.hidden)return;const z=this.getZoom(),output=[],rasterLayers=[],errors=new Set();
  for(const l of this.layers){if(l.type!=='raster'||l.layout?.visibility==='none'||z<(l.minzoom??0)||z>=(l.maxzoom??100))continue;const s=this.getSource(l.source)?.spec;if(s?.type==='raster')rasterLayers.push({id:l.id,tiles:s.tiles,maxzoom:s.maxzoom??19,opacity:evaluate(l.paint?.['raster-opacity']??1,{},z),brightness:evaluate(l.paint?.['raster-brightness-max']??1,{},z),saturation:evaluate(l.paint?.['raster-saturation']??0,{},z)});}
  for(const l of this.layers){if(l.layout?.visibility==='none'||z<(l.minzoom??0)||z>=(l.maxzoom??100)||!['line','fill','fill-extrusion','circle','symbol'].includes(l.type))continue;
   for(const f of this.sourceFeatures(l.source)){try{const s=this.featureStates.get(l.source+':'+f.id)||{};if(!filter(l.filter,f,z,s)||!visibleFeature(f,p=>this.project(p),this.container.clientWidth,this.container.clientHeight))continue;
    const paint={},layout={};for(const [k,v]of Object.entries(l.paint||{}))paint[k]=evaluate(v,f,z,s);for(const [k,v]of Object.entries(l.layout||{}))layout[k]=evaluate(v,f,z,s);
    const opacity=paint[l.type==='fill-extrusion'?'fill-extrusion-opacity':l.type==='symbol'?'text-opacity':l.type+'-opacity'];if(opacity===0&&!(l.type==='symbol'&&layout['icon-image']))continue;
    output.push({layer:l.id,source:l.source,type:l.type,id:String(f.id??''),geometry:f.geometry,paint,layout});
   }catch(e){errors.add(l.id+': '+String(e.message||e));}}
  }
   const key=JSON.stringify({output,rasterLayers,errors:[...errors]});if(key===this.sceneKey)return;this.sceneKey=key;this.errors=[...errors];post('scene',{features:output,rasterLayers,errors:this.errors,revision:this.revision});
 }
 diagnostics(){return {mainRenderer:'MKMapView',mainMapLibre:false,lastMapClick:this.lastMapClick||null,layerCount:this.layers.length,sourceCount:this.sources.size,styleErrors:this.errors,native:this.nativeDiagnostics};}
}
function visibleFeature(f,project,width,height){
 const coords=[];const visit=p=>{if(Array.isArray(p)&&typeof p[0]==='number')coords.push(project(p));else if(Array.isArray(p))p.forEach(visit);};visit(f.geometry?.coordinates);
 if(!coords.length)return false;const xs=coords.map(p=>p.x),ys=coords.map(p=>p.y),pad=24;
 return Math.max(...xs)>=-pad&&Math.min(...xs)<=width+pad&&Math.max(...ys)>=-pad&&Math.min(...ys)<=height+pad;
}
function hitFeature(f,p,project,layer={}){
 const g=f.geometry;if(!g)return false;const distance=q=>Math.hypot(p.x-q.x,p.y-q.y);
 if(g.type==='Point')return distance(project(g.coordinates))<=Math.max(14,Number(layer.paint?.['circle-radius'])||0);
 const rings=g.type==='Polygon'?g.coordinates:g.type==='MultiPolygon'?g.coordinates.flat():g.type==='LineString'?[g.coordinates]:g.type==='MultiLineString'?g.coordinates:[];
 for(const ring of rings){const pts=ring.map(project);if(/Polygon/.test(g.type)){let inside=false;for(let i=0,j=pts.length-1;i<pts.length;j=i++)if((pts[i].y>p.y)!==(pts[j].y>p.y)&&p.x<(pts[j].x-pts[i].x)*(p.y-pts[i].y)/(pts[j].y-pts[i].y)+pts[i].x)inside=!inside;if(inside)return true;}
  for(let i=1;i<pts.length;i++){const a=pts[i-1],b=pts[i],dx=b.x-a.x,dy=b.y-a.y,t=clamp(((p.x-a.x)*dx+(p.y-a.y)*dy)/(dx*dx+dy*dy||1),0,1);if(distance({x:a.x+t*dx,y:a.y+t*dy})<=10)return true;}}
 return false;
}
function install(){
 const Real=root.maplibregl;if(!Real)throw Error('NLSC renderer missing');const RealMap=Real.Map,RealMarker=Real.Marker,RealPopup=Real.Popup;
 Real.Map=function(options){if(options.container==='map')return new NativeMap(options);const inset=new RealMap(options);root.__581NativeInset=inset;installInsetFirewall(inset);return inset;};
 Real.Marker=class extends RealMarker{
  addTo(map){if(!map._isNativeApple)return super.addTo(map);this.remove();this._map=map;map.markers.add(this);map.canvas.append(this.getElement());this.update();return this;}
  setLngLat(p){if(!this._map?._isNativeApple)return super.setLngLat(p);this._lngLat=Real.LngLat.convert(p);this.update();return this;}
  remove(){if(this._map?._isNativeApple){this._map.markers.delete(this);this.getElement().remove();this._map=null;return this;}return super.remove();}
  update(){if(!this._map?._isNativeApple||!this._lngLat)return;const p=this._map.project(this._lngLat),o=this._offset||{x:0,y:0};this.getElement().style.transform=`translate(${p.x+o.x}px,${p.y+o.y}px) translate(-50%,-50%)`;}
 };
 Real.Popup=class extends RealPopup{
  addTo(map){if(!map._isNativeApple)return super.addTo(map);this.remove();this._map=map;this.nativeNode=root.document.createElement('div');this.nativeNode.className='maplibregl-popup native-popup';this.nativeNode.style.cssText='position:absolute;pointer-events:auto;max-width:320px;z-index:100';this.nativeNode.append(this._content);map.canvas.append(this.nativeNode);this.update=()=>{const p=map.project(this._lngLat);this.nativeNode.style.left=p.x+'px';this.nativeNode.style.top=p.y+'px';this.nativeNode.style.transform='translate(-50%,-100%)';};this.update();map.markers.add(this);return this;}
  remove(){if(this._map?._isNativeApple){this._map.markers.delete(this);this.nativeNode?.remove();this._map=null;return this;}return super.remove();}
 };
 root.__581NativeMapUpdate=d=>root.__581NativeMap?.nativeUpdate(d);root.__581NativeGesture=d=>root.__581NativeMap?.nativeGesture(d);root.__581NativeClick=d=>root.__581NativeMap?.nativeClick(d);
 installControlBridge();
}
function installInsetFirewall(inset){
 // Apple query results never become NLSC POI/route/name/Pin data. The camera can
 // center on a user-selected target; the NLSC source remains independent.
  const clean=(id,data)=>{if(root.__581AppleDestination&&/destination|guide|route/.test(id))return empty();const fs=data?.features;return fs?{...data,features:fs.filter(f=>!String(f.properties?.source||'').startsWith('apple'))}:data;};
  const add=inset.addSource.bind(inset);inset.addSource=(id,spec)=>{const source=add(id,spec.type==='geojson'?{...spec,data:clean(id,spec.data)}:spec);const s=inset.getSource(id);if(s?.setData){const write=s.setData.bind(s);s.setData=data=>write(clean(id,data));}return source;};
}
function installControlBridge(){
 const doc=root.document;let pending=false;
 const update=()=>{pending=false;const modal=!!doc.querySelector('dialog[open]'),els=[...doc.querySelectorAll('button,input,textarea,select,a,.maplibregl-popup,#morePanel,#insetCard:not(.collapsed),#plannerSuggestions,#routeEditPanel,#gogoroPanel,#centerCoordBody,#gpsState,#osmStatus')];
  const rects=els.filter(e=>!e.hidden&&root.getComputedStyle(e).visibility!=='hidden'&&root.getComputedStyle(e).display!=='none').map(e=>{const r=e.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height};}).filter(r=>r.width>0&&r.height>0);
  post('controls',{rects,modal,theme:doc.body.dataset.theme||'dark'});
 };
 const schedule=()=>{if(!pending){pending=true;root.setTimeout(update,100);}};
 new root.MutationObserver(schedule).observe(doc,{subtree:true,attributes:true,childList:true});root.addEventListener('resize',schedule);doc.addEventListener('scroll',schedule,true);root.addEventListener('DOMContentLoaded',()=>{
  const button=doc.createElement('button');button.id='nativeAppleSettingsBtn';button.className='more-option';button.setAttribute('aria-label','Apple 地圖設定');button.innerHTML='<span class="more-icon" aria-hidden="true"></span><span>Apple 地圖設定</span>';button.onclick=()=>post('settings',{state:root.__581NativePreferenceState?.()||{}});doc.querySelector('#morePanel .more-grid')?.prepend(button);schedule();
 });schedule();
}
return {NativeMap,NativePointerTracker,evaluate,filter,mercator,geographic,hitFeature,visibleFeature,signedAngle:signed,install};
});
