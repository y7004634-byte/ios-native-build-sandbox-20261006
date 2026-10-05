/* Camera ownership survives input and lifecycle changes. No sensor/network loop.
 * Drag/pinch pauses an active riding camera; release resumes it without changing
 * the selected navigation/FIT mode. Preferences contain no geographic data. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.DoorCameraInteraction=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
'use strict';
const KEY='581-door-camera-owner-v1';
const cameraKeys=['ArrowUp','ArrowDown','ArrowLeft','ArrowRight','+','-','=','PageUp','PageDown'];
function readPreference(storage){
  try{const p=JSON.parse(storage?.getItem(KEY)||'null');
    if(!p||p.v!==1||!['fit','heading','north','manual'].includes(p.owner)||!['heading','north'].includes(p.mode))return null;
    return {v:1,owner:p.owner,mode:p.mode,navigationRequested:p.navigationRequested===true};
  }catch(_){return null;}
}
class Controller{
  constructor({getState,stop,resume,storage=null,isHidden=()=>false,isEditing=()=>false,setTimer=(f,ms)=>globalThis.setTimeout(f,ms),clearTimer=id=>globalThis.clearTimeout(id)}={}){
    Object.assign(this,{getState,stop,resume,storage,isHidden,isEditing,setTimer,clearTimer});
    this.active=false;this.moved=false;this.origin=null;this.pointers=new Set();this.timer=null;this.saved='';this.resumes=0;
  }
  protected(){const s=this.getState();return !!(s.fitLocked||(s.following&&!s.cameraUserOverride&&(s.navigationActive||s.navigationRequested||s.mode==='heading')));}
  clearTimerOnly(){if(this.timer!==null)this.clearTimer(this.timer);this.timer=null;}
  clearHold(){const s=this.getState();this.active=false;this.moved=false;this.origin=null;this.pointers.clear();s.cameraGestureHold=false;s.fitGestureHold=false;s.fitGestureOrigin=null;}
  pause(){const s=this.getState();s.cameraGestureHold=true;s.fitGestureHold=!!s.fitLocked;this.stop?.();}
  finish(delay=0){
    this.clearTimerOnly();this.active=false;this.origin=null;this.pointers.clear();
    if(this.isHidden()){this.clearHold();return;}
    const done=()=>{this.timer=null;this.clearHold();if(this.protected()&&!this.isHidden()&&!this.isEditing()){this.resumes++;this.resume?.();}};
    if(delay>0)this.timer=this.setTimer(done,delay);else done();
  }
  begin(raw){
    if(!this.protected()||this.isHidden()||this.isEditing())return false;
    this.clearTimerOnly();
    const p=raw?.touches?.[0]||raw;
    if(!this.active){this.active=true;this.moved=false;this.origin={x:Number(p?.clientX)||0,y:Number(p?.clientY)||0};}
    if(raw?.type==='pointerdown'&&raw.pointerId!==undefined)this.pointers.add(raw.pointerId);
    this.pause();return true;
  }
  move(raw){
    if(!this.active)return;
    const p=raw?.touches?.[0]||raw;
    if(this.origin&&Math.hypot((Number(p?.clientX)||0)-this.origin.x,(Number(p?.clientY)||0)-this.origin.y)>=8)this.moved=true;
  }
  end(raw={}){
    if(!this.active)return;
    if(/cancel/.test(raw.type||'')){this.finish(0);return;}
    if(raw.type==='pointerup'&&raw.pointerId!==undefined)this.pointers.delete(raw.pointerId);
    if((raw.touches?.length||0)>0||this.pointers.size>0)return;
    this.finish(this.moved?1500:0);
  }
  handle(ev){
    const raw=ev?.originalEvent||ev,type=raw?.type||'';
    const direct=/^(pointerdown|touchstart|mousedown|wheel|keydown)$/.test(type);
    if(!ev?.originalEvent&&!direct)return false;
    if(type==='keydown'&&!cameraKeys.includes(raw.key))return false;
    if(!this.protected()||this.isEditing())return false;
    if(this.isHidden())return true;
    if(ev?.originalEvent&&/^(dragstart|zoomstart|rotatestart|pitchstart)$/.test(ev?.type||'')){this.moved=true;return true;}
    if(/^(pointerdown|touchstart|mousedown)$/.test(type)&&!ev?.originalEvent){this.begin(raw);return true;}
    if(type==='wheel'||type==='keydown'){this.pause();this.finish(900);return true;}
    this.begin(raw);this.moved=true;return true;
  }
  persist(){
    if(this.isEditing())return;
    const s=this.getState(),owner=s.fitLocked?'fit':s.following&&!s.cameraUserOverride?(s.mode==='heading'?'heading':'north'):'manual';
    const p={v:1,owner,mode:s.mode==='heading'?'heading':'north',navigationRequested:!!(s.navigationRequested||s.navigationActive)};
    const text=JSON.stringify(p);if(text===this.saved)return;
    try{this.storage?.setItem(KEY,text);this.saved=text;}catch(_){}
  }
  selectionChanged(){const s=this.getState(),key=[s.fitLocked,s.following,s.cameraUserOverride,s.mode].join();if(!this.protected()||(this.selectionKey&&this.selectionKey!==key)){this.clearTimerOnly();this.clearHold();}this.selectionKey=key;this.persist();}
  lifecycle(active){
    this.clearTimerOnly();this.clearHold();this.persist();
    if(!active){this.stop?.();return;}
    if(this.protected()&&!this.isHidden()&&!this.isEditing()){this.resumes++;this.resume?.();}
  }
  diagnostics(){const s=this.getState();return {revision:'fitlock3',protected:this.protected(),holding:!!s.cameraGestureHold,active:this.active,timerPending:this.timer!==null,resumes:this.resumes};}
  destroy(){this.clearTimerOnly();this.clearHold();}
}
return Object.freeze({KEY,readPreference,Controller});
});
