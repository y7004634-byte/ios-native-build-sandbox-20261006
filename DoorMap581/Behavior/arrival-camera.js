/* 581 v0.3.63 — lightweight arrival composition helpers. No GPS/network/timers. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.DoorArrivalCamera=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
'use strict';
const ENTER_M=500,EXIT_M=600,LOCK_M=200,UNLOCK_M=250,MAX_AUTO_ZOOM=17.0;
const finite=Number.isFinite,clamp=(x,a,b)=>Math.max(a,Math.min(b,x));
const valid=p=>Array.isArray(p)&&finite(Number(p[0]))&&finite(Number(p[1]));
function active(previous,meters){const m=Number(meters);if(!finite(m))return false;return previous?m<=EXIT_M:m<=ENTER_M;}
function shouldLock(locked,meters){const m=Number(meters);if(!finite(m))return false;if(locked)return m<=UNLOCK_M;return m<=LOCK_M;}
function bearing(a,b){if(!valid(a)||!valid(b))return null;const r=Math.PI/180,p1=Number(a[1])*r,p2=Number(b[1])*r,dl=(Number(b[0])-Number(a[0]))*r;const y=Math.sin(dl)*Math.cos(p2),x=Math.cos(p1)*Math.sin(p2)-Math.sin(p1)*Math.cos(p2)*Math.cos(dl);return (Math.atan2(y,x)*180/Math.PI+360)%360;}
function approachBearing(points,fallback=0){const pts=(Array.isArray(points)?points:[]).filter(valid);if(pts.length<2)return Number(fallback)||0;const b=bearing(pts[0],pts.at(-1));return finite(b)?b:(Number(fallback)||0);}
function padding(viewport,pip){const v=viewport||{},w=Math.max(1,Number(v.width)||390),h=Math.max(1,Number(v.height)||740),top=Math.max(0,Number(v.top)||0),bottom=Math.max(0,Number(v.bottom)||0),left=Math.max(0,Number(v.left)||0),right=Math.max(0,Number(v.right)||0);return {top:Math.round(clamp(top+(pip?38:18),0,h*.48)),bottom:Math.round(clamp(bottom+18,0,h*.34)),left:Math.round(clamp(left+8,8,w*.24)),right:Math.round(clamp(right+8,8,w*.28))};}
return Object.freeze({ENTER_M,EXIT_M,LOCK_M,UNLOCK_M,MAX_AUTO_ZOOM,active,shouldLock,bearing,approachBearing,padding});
});
