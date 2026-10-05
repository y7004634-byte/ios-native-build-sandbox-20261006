/* 581 v0.3.62 — display-only GPS interpolation and one adaptive ordinary-follow
 * camera clock. Raw fixes never leave/return through this module. No GPS calls,
 * route decisions, map matching, networking or unbounded dead reckoning.
 * Without a newer fix the display stops at the last measured position.
 */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.DoorVisualMotion=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
'use strict';
const finite=Number.isFinite, clamp=(x,a,b)=>Math.max(a,Math.min(b,x));
const BASE_FPS=15,BOOST_FPS=30,BOOST_MS=700;
const valid=p=>p&&finite(p.lng)&&finite(p.lat)&&Math.abs(p.lng)<=180&&Math.abs(p.lat)<=85;
const delta=(a,b)=>((b-a+540)%360)-180;
function distance(a,b){const r=Math.PI/180,dlat=(b.lat-a.lat)*r,dlng=delta(a.lng,b.lng)*r,q=Math.sin(dlat/2)**2+Math.cos(a.lat*r)*Math.cos(b.lat*r)*Math.sin(dlng/2)**2;return 12742000*Math.asin(Math.sqrt(clamp(q,0,1)));}
function mix(a,b,t){return {lng:((a.lng+delta(a.lng,b.lng)*t+540)%360)-180,lat:a.lat+(b.lat-a.lat)*t};}
function sceneEvent(e){return !e?.doorVisualFrame||!!e.doorVisualRefresh;}
function centerOf(v){if(Array.isArray(v)&&finite(Number(v[0]))&&finite(Number(v[1])))return {lng:Number(v[0]),lat:Number(v[1])};if(valid(v))return {lng:Number(v.lng),lat:Number(v.lat)};return null;}
class Track {
 constructor(){this.from=null;this.to=null;this.raw=null;this.at=0;this.duration=0;this.period=1000;this.lastReceipt=null;this.reason='no-fix';this.accepted=0;this.rejected=0;}
 sample(t){if(!this.to)return null;return mix(this.from,this.to,this.duration>0?clamp((t-this.at)/this.duration,0,1):1);}
 moving(t){return !!this.to&&this.duration>0&&t<this.at+this.duration;}
 push(fix,t,{immediate=false}={}){
  if(!valid(fix)||!finite(t)){this.rejected++;return false;}
  if(this.raw&&finite(fix.ts)&&finite(this.raw.ts)&&fix.ts<=this.raw.ts){this.rejected++;return false;}
  const p=this.sample(t),previous=this.raw;
  const receipt=this.lastReceipt===null?1000:t-this.lastReceipt;
  const stamp=previous&&finite(fix.ts)&&finite(previous.ts)?fix.ts-previous.ts:receipt;
  const gap=receipt>4000||stamp>4000;
  if(previous&&receipt>=150&&receipt<=3000)this.period=clamp(this.period*.5+receipt*.5,200,1100);
  const d=p?distance(p,fix):0;
  const jump=previous&&(distance(previous,fix)>60||distance(previous,fix)/Math.max(.15,stamp/1000)>50);
  const poor=finite(fix.accuracy)&&fix.accuracy>65;
  const stopped=finite(fix.speed)&&fix.speed<.7;
  const jitter=stopped&&p&&d<=clamp((fix.accuracy||0)*.22,1.2,4);
  this.raw={...fix};this.lastReceipt=t;this.accepted++;
  this.from=p||{lng:fix.lng,lat:fix.lat};this.to=jitter&&!immediate?{...this.from}:{lng:fix.lng,lat:fix.lat};this.at=t;
  this.reason=!p?'first-fix':immediate?'immediate':gap?'reacquired':jump?'jump-correction':poor?'low-accuracy':jitter?'stationary-hold':stopped?'stopping':'interpolate';
  this.duration=!p||immediate||gap||jump||poor?0:jitter?0:stopped?160:clamp(this.period*1.05,200,1150);
  return true;
 }
 settle(t){if(this.raw){this.from=this.to={lng:this.raw.lng,lat:this.raw.lat};this.at=t;this.duration=0;this.reason='resumed-at-measured-fix';}}
 diagnostics(t){return {mode:this.reason,raw:this.raw?{...this.raw}:null,display:this.sample(t),animating:this.moving(t),durationMs:this.duration,cadenceMs:this.period,accepted:this.accepted,rejected:this.rejected,extrapolation:false,mapMatching:false};}
}
class Controller {
 constructor({map,marker,getState,documentRef=null,clock=()=>performance.now(),raf=f=>requestAnimationFrame(f),caf=id=>cancelAnimationFrame(id)}={}){
  Object.assign(this,{map,marker,getState,doc:documentRef,clock,raf,caf});this.track=new Track();this.frame=null;this.lastFrame=-Infinity;this.lastScene=-Infinity;this.plan=null;this.cam=null;this.cameraAllowed=false;this.applying=false;this.destroyed=false;this.paused=false;this.lastMarker=null;this.boostUntil=-Infinity;this.lastFrameHz=BASE_FPS;
  this.metrics={frames:0,markerWrites:0,cameraWrites:0,plans:0,sceneRefreshes:0,errors:0,planSkips:0,cameraSkips:0};this.error='';
  this.onVisibility=()=>{if(this.doc?.hidden)this.suspend();else this.resume();};
  this.doc?.addEventListener('visibilitychange',this.onVisibility);
 }
 canCamera(){const s=this.getState?.()||{};return !this.paused&&!this.doc?.hidden&&!s.fitLocked&&s.following&&!s.cameraUserOverride&&!!s.position;}
 push(fix){const s=this.getState?.()||{},t=this.clock();const riding=!!(s.fitLocked||s.navigationActive||s.navigationRequested);const ok=this.track.push(fix,t,{immediate:riding||this.paused||!!this.doc?.hidden});if(ok){this.writeMarker(this.track.sample(t));this.wake();}return ok;}
 writeMarker(p){if(!p||this.doc?.hidden||this.paused)return;
  if(this.lastMarker&&distance(this.lastMarker,p)<.01&&this.marker?._map)return;
  this.marker?.setLngLat([p.lng,p.lat]);if(this.marker&&!this.marker._map)this.marker.addTo(this.map);this.lastMarker={...p};this.metrics.markerWrites++;
 }
 render(){const s=this.getState?.()||{},p=s.fitLocked?(s.displayPosition||s.position):this.track.sample(this.clock())||s.displayPosition||s.position;this.writeMarker(p);}
 setPlan(options,{force=false}={}){
  if(!this.canCamera()){this.stopCamera();return false;}
  const t=this.clock(),newOwner=!this.cameraAllowed,previous=this.plan;
  const nextMode=options.centerMode==='plan'?'plan':'gps',prevMode=previous?.centerMode==='plan'?'plan':'gps',modeChanged=!!previous&&nextMode!==prevMode;
  const pc=centerOf(previous?.center),nc=centerOf(options.center),centerSame=nextMode!=='plan'||(!pc&&!nc)||(pc&&nc&&distance(pc,nc)<.08);
  if(!newOwner&&!force&&!modeChanged&&previous&&centerSame&&Math.abs(delta(previous.bearing,options.bearing))<.75&&Math.abs(previous.pitch-options.pitch)<.01&&Math.abs(previous.zoom-options.zoom)<.0005&&
    ['top','bottom','left','right'].every(k=>(previous.padding?.[k]||0)===(options.padding?.[k]||0))&&[0,1].every(i=>(previous.offset?.[i]||0)===(options.offset?.[i]||0))){this.metrics.planSkips++;if(this.track.moving(t))this.wake();return true;}
  const turnDelta=previous?Math.abs(delta(previous.bearing,options.bearing)):0,pitchDelta=previous?Math.abs(previous.pitch-options.pitch):0,zoomDelta=previous?Math.abs(previous.zoom-options.zoom):0;
  this.plan={...options,centerMode:nextMode,padding:{...options.padding},offset:[...(options.offset||[0,0])]};this.metrics.plans++;
  if(force||newOwner||modeChanged||turnDelta>=4||pitchDelta>=2||zoomDelta>=.18)this.boostUntil=Math.max(this.boostUntil,t+BOOST_MS);
  if(newOwner||force||modeChanged||!this.cam){
   this.lastCameraWrite=null;this.map.stop();const c=this.map.getCenter();
   this.cam={bearing:this.map.getBearing(),pitch:this.map.getPitch(),zoom:this.map.getZoom(),center:{lng:c.lng,lat:c.lat}};
   if(nextMode==='plan')this.catchup=null;
   else {
    // Capture the geographic location underneath the *existing* navigation
    // anchor so recenter has no first-frame padding/offset jump.
    const v=this.map.getContainer().getBoundingClientRect(),p=this.plan.padding,o=this.plan.offset;
    const xy=[(v.width+(p.left||0)-(p.right||0))/2+o[0],(v.height+(p.top||0)-(p.bottom||0))/2+o[1]];
    let anchor=c;try{anchor=this.map.unproject(xy);}catch(_){}
    this.catchup={from:{lng:anchor.lng,lat:anchor.lat},at:t,duration:force?550:350};
   }
  }
  this.cameraAllowed=true;this.wake();return true;
 }
 stopCamera(){this.cameraAllowed=false;this.plan=null;this.catchup=null;this.cam=null;this.lastCameraWrite=null;}
 suspend(){this.paused=true;if(this.frame!==null)this.caf(this.frame);this.frame=null;this.stopCamera();}
 resume(){if(this.destroyed)return;this.paused=false;this.track.settle(this.clock());this.lastFrame=-Infinity;this.render();this.wake();}
 wake(){if(this.destroyed||this.paused||this.doc?.hidden||this.frame!==null)return;this.frame=this.raf(t=>this.tick(t));}
 tick(){this.frame=null;if(this.destroyed||this.paused||this.doc?.hidden)return;const t=this.clock();
  // Ordinary GPS follow is deliberately 15 Hz. A real camera-plan change (turn,
  // pitch or zoom transition) temporarily boosts to 30 Hz. Finger pan/pinch is
  // native MapLibre input and never passes through this clock.
  const hz=t<this.boostUntil?BOOST_FPS:BASE_FPS;this.lastFrameHz=hz;
  if(t-this.lastFrame<1000/hz-.5){this.wake();return;}
  const dt=finite(this.lastFrame)?clamp(t-this.lastFrame,1,120):1000/hz;this.lastFrame=t;this.metrics.frames++;
  const s=this.getState?.()||{};if(s.fitLocked){this.track.settle(t);this.stopCamera();}
  const point=this.track.sample(t)||s.position;this.writeMarker(point);
  if(!this.canCamera())this.stopCamera();
  let cameraMoving=false;
  if(this.cameraAllowed&&this.plan&&point){
   const target=this.plan,c=this.cam,alpha=1-Math.exp(-dt/125);
   c.bearing+=delta(c.bearing,target.bearing)*alpha;c.pitch+=(target.pitch-c.pitch)*alpha;c.zoom+=(target.zoom-c.zoom)*alpha;
   const db=Math.abs(delta(c.bearing,target.bearing)),dp=Math.abs(c.pitch-target.pitch),dz=Math.abs(c.zoom-target.zoom);
   cameraMoving=db>.035||dp>.025||dz>.002;
   if(!cameraMoving){c.bearing+=delta(c.bearing,target.bearing);c.pitch=target.pitch;c.zoom=target.zoom;}
   let center=point;
   if(target.centerMode==='plan'){
    const wanted=centerOf(target.center);
    if(wanted){
     if(!c.center)c.center={...wanted};
     const ca=1-Math.exp(-dt/160);c.center=mix(c.center,wanted,ca);
     const dc=distance(c.center,wanted);if(dc>.08)cameraMoving=true;else c.center={...wanted};
     center=c.center;
    }
   }else if(this.catchup){const q=clamp((t-this.catchup.at)/this.catchup.duration,0,1);center=mix(this.catchup.from,point,1-(1-q)**3);if(q>=1)this.catchup=null;else cameraMoving=true;}
   const active=this.track.moving(t)||cameraMoving;
   const refresh=t-this.lastScene>=350||!active;if(refresh){this.lastScene=t;this.metrics.sceneRefreshes++;}
   const options={center:[center.lng,center.lat],bearing:c.bearing,pitch:c.pitch,zoom:c.zoom,padding:target.padding,offset:target.offset,duration:0};
   try{
    this.applying=true;
    // Zero-duration native transform; one owner/clock. No stack of 350ms
    // easings restarted by 180ms compass ticks. Event tag throttles readers,
    // not drawing; native symbols/buildings still transform every map frame.
    const last=this.lastCameraWrite,same=last&&distance({lng:last.center[0],lat:last.center[1]},{lng:options.center[0],lat:options.center[1]})<.05&&Math.abs(delta(last.bearing,options.bearing))<.12&&Math.abs(last.pitch-options.pitch)<.005&&Math.abs(last.zoom-options.zoom)<.0001&&['top','bottom','left','right'].every(k=>(last.padding?.[k]||0)===(options.padding?.[k]||0))&&[0,1].every(i=>(last.offset?.[i]||0)===(options.offset?.[i]||0));
    if(!same){this.map.easeTo(options,{doorVisualFrame:true,doorVisualRefresh:refresh});this.lastCameraWrite=options;this.metrics.cameraWrites++;}else this.metrics.cameraSkips++;
    this.error='';
   }catch(e){this.error=String(e.message||e);this.metrics.errors++;this.stopCamera();}
   finally{this.applying=false;}
  }
  if(this.track.moving(t)||cameraMoving)this.wake();
 }
 get animating(){return this.frame!==null;}
 diagnostics(){const boosting=this.clock()<this.boostUntil;return {...this.track.diagnostics(this.clock()),cameraOwner:this.cameraAllowed,rafPending:this.frame!==null,frameLimit:boosting?BOOST_FPS:BASE_FPS,lastFrameLimit:this.lastFrameHz,baseFrameLimit:BASE_FPS,boostFrameLimit:BOOST_FPS,boosting,error:this.error,...this.metrics};}
 destroy(){this.suspend();this.destroyed=true;this.doc?.removeEventListener('visibilitychange',this.onVisibility);}
}
return {Track,Controller,distance,mix,sceneEvent};
});
