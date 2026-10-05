/* 581 v0.3.51 — address-first target resolution + place membership + virtual frontage lots.
 * Navigation Pin remains an approach/stop point. Official doorplate coordinates and
 * named place/community geometry decide visual destination highlighting when available.
 * No camera/network/GPS ownership or per-frame work lives here.
 */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.DoorTargetSelection=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
'use strict';
const MAX_ITEMS=160,MAX_BUILDINGS=6000,MAX_SELECTED=256,MAX_TOTAL_VERTICES=32000,MAX_VERTICES=12000;
const R=6371008.8;
const normal=s=>String(s||'').normalize('NFKC').replace(/臺/g,'台').replace(/[\s·・]/g,'').toLowerCase();
const house=s=>String(s||'').normalize('NFKC').replace(/號$/,'').trim();
const point=p=>p&&Number.isFinite(Number(p.lng))&&Number.isFinite(Number(p.lat))&&Math.abs(Number(p.lng))<=180&&Math.abs(Number(p.lat))<=85;
function meters(a,b){if(!point(a)||!point(b))return Infinity;const p1=Number(a.lat)*Math.PI/180,p2=Number(b.lat)*Math.PI/180,dp=p2-p1,dl=(Number(b.lng)-Number(a.lng))*Math.PI/180;const h=Math.sin(dp/2)**2+Math.cos(p1)*Math.cos(p2)*Math.sin(dl/2)**2;return 2*R*Math.asin(Math.min(1,Math.sqrt(h)));}
function valid(g){
 if(!g||!['Polygon','MultiPolygon'].includes(g.type))return false;
 const ps=g.type==='Polygon'?[g.coordinates]:g.coordinates;let n=0;
 return Array.isArray(ps)&&ps.length>0&&ps.every(p=>Array.isArray(p)&&p.length>0&&p.every(r=>{
  if(!Array.isArray(r)||r.length<4||(n+=r.length)>MAX_VERTICES)return false;
  const a=r[0],b=r.at(-1);return a?.[0]===b?.[0]&&a?.[1]===b?.[1]&&r.every(x=>Array.isArray(x)&&x.length>=2&&Number.isFinite(x[0])&&Number.isFinite(x[1])&&Math.abs(x[0])<=180&&Math.abs(x[1])<=85);
 }));
}
const polys=g=>g.type==='Polygon'?[g.coordinates]:g.coordinates;
function ringHit(p,r){
 let inside=false;
 for(let i=0,j=r.length-1;i<r.length;j=i++){
  const a=r[j],b=r[i],dx=b[0]-a[0],dy=b[1]-a[1],ll=dx*dx+dy*dy;
  const t=ll?Math.max(0,Math.min(1,((p.lng-a[0])*dx+(p.lat-a[1])*dy)/ll)):0;
  if(Math.hypot(p.lng-a[0]-t*dx,p.lat-a[1]-t*dy)<1e-9)return 0;
  if((a[1]>p.lat)!==(b[1]>p.lat)&&p.lng<(b[0]-a[0])*(p.lat-a[1])/(b[1]-a[1])+a[0])inside=!inside;
 }return inside?1:-1;
}
function hit(p,g){
 let boundary=false;
 for(const poly of polys(g)){
  const outer=ringHit(p,poly[0]);if(outer===-1)continue;
  const holes=poly.slice(1).map(r=>ringHit(p,r));if(holes.includes(1))continue;
  if(outer===0||holes.includes(0))boundary=true;else return 1;
 }return boundary?0:-1;
}
function contains(p,g){return point(p)&&valid(g)&&hit({lng:Number(p.lng),lat:Number(p.lat)},g)===1;}
function bounds(g){let w=Infinity,e=-Infinity,s=Infinity,n=-Infinity;for(const poly of polys(g))for(const r of poly)for(const [x,y] of r){w=Math.min(w,x);e=Math.max(e,x);s=Math.min(s,y);n=Math.max(n,y);}return {w,e,s,n};}
function ringArea(r){const o=r[0];let a=0;for(let i=1;i<r.length;i++)a+=(r[i-1][0]-o[0])*(r[i][1]-o[1])-(r[i][0]-o[0])*(r[i-1][1]-o[1]);return Math.abs(a)/2;}
function area(g){return polys(g).reduce((s,p)=>s+Math.max(0,ringArea(p[0])-p.slice(1).reduce((n,r)=>n+ringArea(r),0)),0);}
function key(g){
 function rk(r){const pts=r.slice(0,-1).map(p=>p.slice(0,2).join(','));let i=0;for(let j=1;j<pts.length;j++)if(pts[j]<pts[i])i=j;const f=pts.slice(i).concat(pts.slice(0,i)).join(';'),b=[pts[i],...pts.slice(0,i).reverse(),...pts.slice(i+1).reverse()].join(';');return f<b?f:b;}
 return polys(g).map(p=>rk(p[0])+'|'+p.slice(1).map(rk).sort().join('|')).sort().join('||');
}
function itemGeometry(item){
 if(valid(item.geometry))return JSON.parse(JSON.stringify(item.geometry));
 const ps=[];for(const shape of item.shapes||[]){if(shape.type!=='Polygon')continue;let r=(shape.coords||[]).map(p=>[p[0],p[1]]);if(r.length>=3&&(r[0][0]!==r.at(-1)[0]||r[0][1]!==r.at(-1)[1]))r.push([...r[0]]);const g={type:'Polygon',coordinates:[r]};if(!valid(g))return null;ps.push(g.coordinates);}
 const g=ps.length===1?{type:'Polygon',coordinates:ps[0]}:{type:'MultiPolygon',coordinates:ps};return valid(g)?g:null;
}
function interior(g){
 const b=bounds(g);const ys=[(b.s+b.n)/2];
 for(const poly of polys(g))for(let i=1;i<poly[0].length;i++)ys.push((poly[0][i-1][1]+poly[0][i][1])/2);
 let best=null,width=0;
 for(const y of ys.slice(0,768)){const xs=[];for(const p of polys(g))for(const r of p)for(let i=1;i<r.length;i++){const a=r[i-1],c=r[i];if((a[1]>y)!==(c[1]>y))xs.push(a[0]+(y-a[1])*(c[0]-a[0])/(c[1]-a[1]));}xs.sort((a,b)=>a-b);for(let i=1;i<xs.length;i++){const p={lng:(xs[i-1]+xs[i])/2,lat:y};if(xs[i]-xs[i-1]>width&&hit(p,g)===1){best=p;width=xs[i]-xs[i-1];}}}
 return best;
}
function cuts(a,b,c,d){const x=b[0]-a[0],y=b[1]-a[1],u=d[0]-c[0],v=d[1]-c[1],den=x*v-y*u;if(Math.abs(den)<1e-20)return [];const t=((c[0]-a[0])*v-(c[1]-a[1])*u)/den,s=((c[0]-a[0])*y-(c[1]-a[1])*x)/den;return t>0&&t<1&&s>=0&&s<=1?[t]:[];}
function covers(mask,g){
 if(!valid(mask)||!valid(g))return false;const mb=bounds(mask),gb=bounds(g),eps=1e-9;if(gb.w<mb.w-eps||gb.e>mb.e+eps||gb.s<mb.s-eps||gb.n>mb.n+eps)return false;let budget=0;
 for(const poly of polys(g))for(const r of poly)for(let i=1;i<r.length;i++){const a=r[i-1],b=r[i];if(hit({lng:a[0],lat:a[1]},mask)<0)return false;const ts=[0,1];for(const mp of polys(mask))for(const mr of mp)for(let j=1;j<mr.length;j++){if(++budget>180000)return false;ts.push(...cuts(a,b,mr[j-1],mr[j]));}ts.sort((a,b)=>a-b);for(let j=1;j<ts.length;j++){const t=(ts[j-1]+ts[j])/2;if(hit({lng:a[0]+t*(b[0]-a[0]),lat:a[1]+t*(b[1]-a[1])},mask)<0)return false;}}
 for(const p of polys(mask))for(const r of p.slice(1)){const h={type:'Polygon',coordinates:[r]},q=interior(h);if(q&&hit(q,g)===1)return false;}const q=interior(g);return !!q&&hit(q,mask)===1;
}
function siteItems(state={}){
 const seen=new Set(),out=[];for(const item of [...(state.communityItems||[]).map(i=>({...i,category:i.category||'residential'})),...(state.placeItems||[])].slice(0,MAX_ITEMS)){const geometry=itemGeometry(item);if(!geometry)continue;const k=normal(item.name)+'|'+key(geometry);if(seen.has(k))continue;seen.add(k);out.push({name:String(item.name||''),category:item.category||'commercial',geometry,key:k,area:area(geometry),raw:item});}return out;
}
function addressAnchor(state={}){
 const want=house(state.destinationInfo?.houseNumber),road=normal(state.destinationInfo?.road),d=state.destination;
 if(!want)return null;const rows=(state.addressCandidates||state.addresses||[]).filter(r=>point(r)&&house(r.houseNumber)===want);if(!rows.length)return null;
 const scored=rows.map(r=>{const rr=normal(r.road),roadMatch=!road||!rr||road.includes(rr)||rr.includes(road);const official=r.source==='taichung-official-address';return {row:r,score:(roadMatch?0:10000)+(official?-1000:0)+(Number(r.distance)||meters(d,r))};}).sort((a,b)=>a.score-b.score);
 const row=scored[0].row;return {point:{lat:Number(row.lat),lng:Number(row.lng)},row,houseNumber:want,road:String(row.road||state.destinationInfo?.road||''),source:row.source||'address',reason:'official-address'};
}
function resolveAmong(all,names,reason){
 if(!all.length)return {site:null,reason:'none'};const named=all.filter(s=>names.includes(normal(s.name))),choices=named.length?named:all;if(choices.length===1)return {site:choices[0],reason};const sorted=choices.slice().sort((a,b)=>b.area-a.area),outer=sorted[0];if(normal(outer.name)===names[0]&&sorted.slice(1).every(x=>covers(outer.geometry,x.geometry)))return {site:outer,reason:`${reason}-named-parent`};return {site:null,reason:'ambiguous-place'};
}
function distanceToGeometryMeters(p,g){
 if(!point(p)||!valid(g))return Infinity;if(hit(p,g)>=0)return 0;const lat=Number(p.lat)*Math.PI/180,mx=111320*Math.max(.15,Math.cos(lat)),my=111320;let best=Infinity;
 for(const poly of polys(g))for(const r of poly)for(let i=1;i<r.length;i++){const a=r[i-1],b=r[i],ax=(a[0]-p.lng)*mx,ay=(a[1]-p.lat)*my,bx=(b[0]-p.lng)*mx,by=(b[1]-p.lat)*my,dx=bx-ax,dy=by-ay,ll=dx*dx+dy*dy,t=ll?Math.max(0,Math.min(1,-(ax*dx+ay*dy)/ll)):0;best=Math.min(best,Math.hypot(ax+t*dx,ay+t*dy));}return best;
}
function region(state={}){
 const d=state.destination,items=siteItems(state),names=[state.destinationInfo?.parentName,state.destinationInfo?.placeName].map(normal).filter(Boolean),address=addressAnchor(state);
 if(!point(d)&&!address)return {site:null,reason:'no-destination',address};
 // 1) Explicit official doorplate is the strongest evidence for site membership.
 if(address){
  const hitSites=items.filter(s=>contains(address.point,s.geometry)),r=resolveAmong(hitSites,names,'address-contained');if(r.site||r.reason==='ambiguous-place')return {...r,address};
  if(names.length){const choices=items.filter(s=>names.includes(normal(s.name))).map(s=>({s,d:distanceToGeometryMeters(address.point,s.geometry)})).filter(x=>x.d<=10).sort((a,b)=>a.d-b.d);
   if(choices.length===1||choices[0]&&(!choices[1]||choices[1].d-choices[0].d>=6))return {site:choices[0].s,reason:'address-named-near-boundary',address};}
 }
 // 2) A Pin genuinely inside a polygon remains a direct hit.
 if(point(d)){const hitSites=items.filter(s=>contains(d,s.geometry));const r=resolveAmong(hitSites,names,'pin-contained');if(r.site||r.reason==='ambiguous-place')return {...r,address};}
 // 3) Roadside Pin: use only an entrance already geometry-linked to a named site.
 if(point(d)){
  const entries=(state.entranceItems||[]).filter(e=>point(e)&&meters(d,e)<=28&&String(e.placeName||e.communityName||'')).sort((a,b)=>(a.kind==='main'?-1:0)-(b.kind==='main'?-1:0)||meters(d,a)-meters(d,b));
  for(const e of entries){const n=normal(e.placeName||e.communityName),matches=items.filter(s=>normal(s.name)===n);if(matches.length===1)return {site:matches[0],reason:'entrance-linked',address,entrance:e};}
 }
 // 4) Last fallback: exact destination place/parent name and a very small edge gap.
 if(point(d)&&names.length){const named=items.filter(s=>names.includes(normal(s.name))).map(s=>({s,d:distanceToGeometryMeters(d,s.geometry)})).filter(x=>x.d<=22).sort((a,b)=>a.d-b.d);if(named.length===1||named[0]&&(!named[1]||named[1].d-named[0].d>=6))return {site:named[0].s,reason:'named-near-boundary',address};}
 return {site:null,reason:'no-confirmed-place',address};
}
function belongs(mask,g){
 if(!valid(mask)||!valid(g))return {yes:false,reason:'invalid'};
 const q=interior(g);if(q&&hit(q,mask)>=0)return {yes:true,reason:'building-representative'};
 const m=interior(mask);if(m&&hit(m,g)>=0)return {yes:true,reason:'site-inside-building'};
 let inside=0,total=0;for(const poly of polys(g))for(const r of [poly[0]]){const step=Math.max(1,Math.ceil((r.length-1)/48));for(let i=0;i<r.length-1;i+=step){const a=r[i],b=r[Math.min(r.length-1,i+step)],pts=[[a[0],a[1]],[(a[0]+b[0])/2,(a[1]+b[1])/2]];for(const p of pts){total++;if(hit({lng:p[0],lat:p[1]},mask)>=0)inside++;}}}
 return {yes:total>0&&inside/total>=.55,reason:'majority-overlap',ratio:total?inside/total:0};
}
const yes=v=>v===true||v===1||v==='true'||v==='yes'||v==='1';
const excluded=p=>yes(p.hide_3d)||yes(p.underground)||p.location==='underground'||p.building==='no';
function inRegion(features,site){
 if(!site||!valid(site.geometry))return {features:[],reason:'no-place-geometry',examined:0};
 if(!Array.isArray(features)||features.length>MAX_BUILDINGS)return {features:[],reason:'too-many',examined:0};
 const rows=new Map();let examined=0,boundarySkipped=0,vertices=0;const mb=bounds(site.geometry);
 for(const f of features){examined++;if(excluded(f.properties||{})||!valid(f.geometry))continue;for(const coordinates of polys(f.geometry)){const geometry={type:'Polygon',coordinates},bb=bounds(geometry);if(bb.e<mb.w||bb.w>mb.e||bb.n<mb.s||bb.s>mb.n)continue;const membership=belongs(site.geometry,geometry);if(!membership.yes){boundarySkipped++;continue;}const k=key(geometry)+'|'+JSON.stringify([f.properties?.render_height,f.properties?.height,f.properties?.['building:levels'],f.properties?.min_height,f.properties?.render_min_height]);if(rows.has(k))continue;vertices+=coordinates.reduce((n,r)=>n+r.length,0);if(rows.size>=MAX_SELECTED||vertices>MAX_TOTAL_VERTICES)return {features:[],reason:'place-budget-exceeded',examined,boundarySkipped};rows.set(k,{...f,geometry,selectionCategory:site.category,selectionEvidence:membership.reason});}}
 const dims=f=>JSON.stringify([f.properties?.render_height,f.properties?.height,f.properties?.['building:height'],f.properties?.['building:levels'],f.properties?.levels,f.properties?.min_height,f.properties?.render_min_height]);const selected=[];
 for(const f of [...rows.values()].sort((a,b)=>area(b.geometry)-area(a.geometry))){if(f.id!=null&&selected.some(k=>k.id===f.id&&dims(k)===dims(f)&&covers(k.geometry,f.geometry)))continue;selected.push(f);}
 return {features:selected.sort((a,b)=>key(a.geometry).localeCompare(key(b.geometry))),reason:selected.length?'place-buildings':'place-no-confirmed-buildings',examined,boundarySkipped};
}
function geometryDistanceMeters(p,g){return distanceToGeometryMeters(p,g);}
function routeCoords(route){if(Array.isArray(route))return route;return route?.features?.[0]?.geometry?.coordinates||route?.geometry?.coordinates||[];}
function routeSide(p,route){if(!point(p))return {side:'unknown',distance:Infinity,signed:0};const cs=routeCoords(route);if(!Array.isArray(cs)||cs.length<2)return {side:'unknown',distance:Infinity,signed:0};const lat=Number(p.lat)*Math.PI/180,mx=111320*Math.max(.15,Math.cos(lat)),my=111320,start=Math.max(1,cs.length-36);let best=null;for(let i=start;i<cs.length;i++){const a=cs[i-1],b=cs[i];if(!Array.isArray(a)||!Array.isArray(b))continue;const ax=(a[0]-p.lng)*mx,ay=(a[1]-p.lat)*my,bx=(b[0]-p.lng)*mx,by=(b[1]-p.lat)*my,dx=bx-ax,dy=by-ay,ll=dx*dx+dy*dy;if(ll<16)continue;const t=Math.max(0,Math.min(1,-(ax*dx+ay*dy)/ll)),qx=ax+t*dx,qy=ay+t*dy,d=Math.hypot(qx,qy),signed=(dx*(-ay)-dy*(-ax))/Math.sqrt(ll);if(!best||d<best.distance)best={distance:d,signed,side:Math.abs(signed)<1.5?'unknown':signed>0?'left':'right'};}return best||{side:'unknown',distance:Infinity,signed:0};}
function dedupeBuildings(list){const m=new Map();for(const f of list){const g=key(f.geometry),k=f.id==null?'geom:'+g:'id:'+String(f.id)+'|'+g;if(!m.has(k))m.set(k,f);}return [...m.values()];}
function exactBuilding(features,p){const exact=[];let examined=0;for(const f of features||[]){examined++;if(excluded(f.properties||{})||!valid(f.geometry))continue;for(const coordinates of polys(f.geometry)){const geometry={type:'Polygon',coordinates};if(contains(p,geometry))exact.push({...f,geometry});}}const ex=dedupeBuildings(exact);if(!ex.length)return {feature:null,examined};ex.sort((a,b)=>area(a.geometry)-area(b.geometry));return {feature:ex[0],examined,ambiguous:ex.length>1};}
function sameSideBuilding(features,p,route,maxDistanceM=14){const targetSide=routeSide(p,route);if(targetSide.side==='unknown'||targetSide.distance>22)return {feature:null,reason:'side-unknown',examined:0};const near=[];let examined=0;for(const f of features||[]){examined++;if(excluded(f.properties||{})||!valid(f.geometry))continue;for(const coordinates of polys(f.geometry)){const geometry={type:'Polygon',coordinates},d=distanceToGeometryMeters(p,geometry);if(d>maxDistanceM)continue;const c=interior(geometry),side=c?routeSide(c,route):{side:'unknown'};if(side.side!==targetSide.side)continue;near.push({feature:{...f,geometry},d});}}near.sort((a,b)=>a.d-b.d);if(!near.length)return {feature:null,reason:'same-side-none',examined};if(near[1]&&near[1].d-near[0].d<2.8)return {feature:null,reason:'same-side-ambiguous',examined};return {feature:near[0].feature,reason:'same-side-near',distance:near[0].d,examined};}
function buildingForCoordinate(features,p,route,maxDistanceM=14){if(!point(p))return {feature:null,reason:'no-point',examined:0,confidence:'none'};const exact=exactBuilding(features,p);if(exact.feature){if(exact.ambiguous)return {feature:null,reason:'contained-ambiguous',examined:exact.examined,confidence:'none'};return {feature:exact.feature,reason:'contained',examined:exact.examined,confidence:'high'};}const near=sameSideBuilding(features,p,route,maxDistanceM);return near.feature?{...near,confidence:'medium'}:{...near,confidence:'none'};}
function buildingForAddress(features,p,maxDistanceM=12,route=null){if(!point(p))return {feature:null,reason:'no-address-point',examined:0,confidence:'none'};if(!Array.isArray(features)||features.length>MAX_BUILDINGS)return {feature:null,reason:'no-buildings',examined:0,confidence:'none'};const exact=exactBuilding(features,p);if(exact.feature)return {feature:exact.feature,reason:exact.ambiguous?'address-contained-smallest':'address-contained',examined:exact.examined,confidence:'high'};const near=sameSideBuilding(features,p,route,maxDistanceM);return near.feature?{...near,reason:'address-same-side-building',confidence:'medium'}:{...near,reason:near.reason||'address-no-building',confidence:'none'};}
function virtualLot(rows,anchor,{destination=null}={}){
 const target=anchor?.row||anchor;if(!point(target)||!house(target.houseNumber))return {feature:null,reason:'no-address-anchor'};const road=normal(target.road),lane=normal(target.lane),alley=normal(target.alley);if(!road)return {feature:null,reason:'no-road'};
 const targetN=parseInt(house(target.houseNumber),10),parity=Number.isFinite(targetN)?Math.abs(targetN)%2:null,lat0=Number(target.lat),lng0=Number(target.lng),mx=111320*Math.max(.15,Math.cos(lat0*Math.PI/180)),my=111320;
 let peers=(rows||[]).filter(r=>r!==target&&point(r)&&normal(r.road)===road&&normal(r.lane)===lane&&normal(r.alley)===alley&&meters(target,r)<=55);if(parity!==null){const same=peers.filter(r=>{const n=parseInt(house(r.houseNumber),10);return Number.isFinite(n)&&Math.abs(n)%2===parity;});if(same.length)peers=same;}if(peers.length<1)return {feature:null,reason:'not-enough-row-addresses'};
 const pts=peers.map(r=>({x:(Number(r.lng)-lng0)*mx,y:(Number(r.lat)-lat0)*my,r})).sort((a,b)=>Math.hypot(a.x,a.y)-Math.hypot(b.x,b.y)).slice(0,8);let xx=0,xy=0,yy=0,w=0;for(const p of pts){const d=Math.max(2,Math.hypot(p.x,p.y)),q=1/d;xx+=q*p.x*p.x;xy+=q*p.x*p.y;yy+=q*p.y*p.y;w+=q;}if(!w)return {feature:null,reason:'row-axis-unavailable'};const theta=.5*Math.atan2(2*xy,xx-yy),ux=Math.cos(theta),uy=Math.sin(theta),vx=-uy,vy=ux;const along=pts.map(p=>Math.abs(p.x*ux+p.y*uy)).filter(v=>v>2).sort((a,b)=>a-b);if(!along.length)return {feature:null,reason:'row-spacing-unavailable'};const width=Math.max(4,Math.min(9,along[0]*.86)),depth=16;
 let shift=0;if(point(destination)&&meters(destination,target)<=28){const dx=(lng0-Number(destination.lng))*mx,dy=(lat0-Number(destination.lat))*my;const side=dx*vx+dy*vy;if(Math.abs(side)>1)shift=Math.sign(side)*Math.min(4,depth*.25);}const cx=vx*shift,cy=vy*shift;
 const corners=[[-width/2,-depth/2],[width/2,-depth/2],[width/2,depth/2],[-width/2,depth/2],[-width/2,-depth/2]].map(([a,b])=>[lng0+(cx+ux*a+vx*b)/mx,lat0+(cy+uy*a+vy*b)/my]);const label=`${house(target.houseNumber)}號`;
 return {feature:{type:'Feature',geometry:{type:'Polygon',coordinates:[corners]},properties:{virtual:1,label,category:'residential',confidence:'row-address',source:target.source||'official-address'}},reason:'virtual-row-lot',widthM:width,depthM:depth,label};
}
function color(category,theme='dark'){const dark=theme!=='light';if(category==='residential')return dark?'#aa87f5':'#7953c4';if(category==='business')return dark?'#5ab3f1':'#277ebb';if(category==='public')return dark?'#55c894':'#238553';return dark?'#efb04e':'#c57f22';}
return {region,addressAnchor,inRegion,buildingForAddress,buildingForCoordinate,routeSide,virtualLot,belongs,itemGeometry,valid,contains,hit,covers,interior,bounds,key,area,color,meters,distanceToGeometryMeters,MAX_SELECTED,MAX_BUILDINGS,MAX_TOTAL_VERTICES};
});
