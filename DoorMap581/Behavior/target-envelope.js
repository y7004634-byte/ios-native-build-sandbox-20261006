/* Native target envelope, v0.3.49. One selected building only. Thin polygon
 * beams and posts are rendered by MapLibre fill-extrusion, not a DOM/Canvas
 * overlay. Real footprint/Pin/house coordinates are never rewritten.
 * Display shell clearance (12cm) only prevents coplanar depth flicker against
 * the base map building. Concave outlines and courtyard holes are preserved.
 */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.DoorTargetEnvelope=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
'use strict';
const MAX_RING_POINTS=768, MAX_POSTS=96, CLEARANCE=.12, BEAM_HALF=.16, BEAM_HEIGHT=.24;
const fc=features=>({type:'FeatureCollection',features});
function signedArea(r){let a=0;for(let i=0;i<r.length;i++){const j=(i+1)%r.length;a+=r[i][0]*r[j][1]-r[j][0]*r[i][1];}return a/2;}
function clean(r){const out=[];for(const p of r){if(!out.length||Math.hypot(p[0]-out.at(-1)[0],p[1]-out.at(-1)[1])>.02)out.push(p);}if(out.length>1&&Math.hypot(out[0][0]-out.at(-1)[0],out[0][1]-out.at(-1)[1])<.02)out.pop();return out;}
function outsideRing(r,amount){const sign=signedArea(r)>=0?1:-1;return r.map((v,i)=>{
 const p=r[(i+r.length-1)%r.length],n=r[(i+1)%r.length],a=[v[0]-p[0],v[1]-p[1]],b=[n[0]-v[0],n[1]-v[1]],al=Math.hypot(...a),bl=Math.hypot(...b);
 const n1=[sign*a[1]/al,-sign*a[0]/al],n2=[sign*b[1]/bl,-sign*b[0]/bl];
 const sx=n1[0]+n2[0],sy=n1[1]+n2[1],len=Math.hypot(sx,sy);if(len<.01)return [v[0]+n1[0]*amount,v[1]+n1[1]*amount];
 const ux=sx/len,uy=sy/len,scale=Math.min(Math.abs(amount)*2,Math.abs(amount)/Math.max(.5,ux*n1[0]+uy*n1[1]))*Math.sign(amount);
 return [v[0]+ux*scale,v[1]+uy*scale];
 });}
function build(geometry,height,base=0){
 if(!geometry||geometry.type!=='Polygon'||!Number.isFinite(height)||height<=0)return fc([]);
 const raw=geometry.coordinates;if(!raw?.length)return fc([]);
 const origin=raw[0][0],mx=111320*Math.max(.15,Math.cos(origin[1]*Math.PI/180)),my=111320;
 const xy=p=>[(p[0]-origin[0])*mx,(p[1]-origin[1])*my],ll=p=>[origin[0]+p[0]/mx,origin[1]+p[1]/my];
 const rings=raw.map(r=>clean(r.map(xy)));if(rings.some(r=>r.length<3))return fc([]);
 // Bounded geometry generation. Body tint still works without a detailed frame
 // for abnormally complex footprints; never replace an L shape by a rectangle.
 const points=rings.reduce((n,r)=>n+r.length,0),detailed=points<=MAX_RING_POINTS;
 const shell=rings.map((r,i)=>outsideRing(r,i===0?CLEARANCE:-CLEARANCE));
 const close=r=>[...r.map(ll),ll(r[0])];
 const features=[{type:'Feature',properties:{part:'body',low:Math.max(0,base-.08),high:height+.12},geometry:{type:'Polygon',coordinates:shell.map(close)}}];
 if(!detailed)return {...fc(features),frameReason:'complex-footprint-body-only'};
 const add=(r,low,high,kind)=>features.push({type:'Feature',properties:{part:'edge',kind,low,high},geometry:{type:'Polygon',coordinates:[close(r)]}});
 let posts=0;
 for(const r of shell){for(let i=0;i<r.length;i++){
  const a=r[i],b=r[(i+1)%r.length],dx=b[0]-a[0],dy=b[1]-a[1],len=Math.hypot(dx,dy);if(len<.05)continue;
  const nx=-dy/len*BEAM_HALF,ny=dx/len*BEAM_HALF;
  const band=[[a[0]+nx,a[1]+ny],[b[0]+nx,b[1]+ny],[b[0]-nx,b[1]-ny],[a[0]-nx,a[1]-ny]];
  add(band,height,height+BEAM_HEIGHT,'roof');add(band,Math.max(0,base),Math.max(0,base)+BEAM_HEIGHT,'base');
  const prev=r[(i+r.length-1)%r.length],u=[a[0]-prev[0],a[1]-prev[1]],ul=Math.hypot(...u);
  const cos=(u[0]*dx+u[1]*dy)/Math.max(.001,ul*len);
  if(cos<.94&&posts<MAX_POSTS){const w=BEAM_HALF;add([[a[0]-w,a[1]-w],[a[0]+w,a[1]-w],[a[0]+w,a[1]+w],[a[0]-w,a[1]+w]],Math.max(0,base),height+BEAM_HEIGHT,'post');posts++;}
 }}
 return {...fc(features),frameReason:'native-beams',postCount:posts};
}
return {build,MAX_RING_POINTS,MAX_POSTS,CLEARANCE};
});
