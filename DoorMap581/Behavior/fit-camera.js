/* 581 FIT camera v1.2 — deterministic Mercator screen fitting, no network/timer.
 * 0-degree pitch is intentional: an overview must expose the entire route.
 * Mercator projection follows the app's pinned MapLibre 5.12.0 convention.
 * QA uses independent geometry checks and a browser API test double, not iPhone GPU measurements.
 */
(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.DoorFitCamera=api;
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';
  const RAD=Math.PI/180;
  const clamp=(x,a,b)=>Math.max(a,Math.min(b,x));
  const delta=(a,b)=>((a-b+540)%360)-180;
  const bearing=b=>((b+540)%360)-180;
  function mercator(p){
    const lat=clamp(Number(p[1]),-85.05112878,85.05112878)*RAD;
    return [(Number(p[0])+180)/360,(1-Math.log(Math.tan(Math.PI/4+lat/2))/Math.PI)/2];
  }
  function lngLat(p){return [p[0]*360-180,Math.atan(Math.sinh(Math.PI*(1-2*p[1])))/RAD];}
  function valid(p){return Array.isArray(p)&&Number.isFinite(p[0])&&Number.isFinite(p[1])&&Math.abs(p[1])<=90;}
  function hull(points){
    const sorted=points.slice().sort((a,b)=>a[0]-b[0]||a[1]-b[1]);
    const cross=(a,b,c)=>(b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0]);
    const low=[],high=[];
    for(const p of sorted){while(low.length>1&&cross(low[low.length-2],low[low.length-1],p)<=0)low.pop();low.push(p);}
    for(let i=sorted.length-1;i>=0;i--){const p=sorted[i];while(high.length>1&&cross(high[high.length-2],high[high.length-1],p)<=0)high.pop();high.push(p);}
    low.pop();high.pop();return low.concat(high).length?low.concat(high):[sorted[0]];
  }
  function simplify(points,epsilon){
    if(points.length<3)return points.slice();
    const keep=new Uint8Array(points.length);keep[0]=keep[points.length-1]=1;
    const stack=[[0,points.length-1]],e2=epsilon*epsilon;
    while(stack.length){
      const [a,b]=stack.pop();if(b<=a+1)continue;
      const x=points[a][0],y=points[a][1],vx=points[b][0]-x,vy=points[b][1]-y,vv=vx*vx+vy*vy;
      let far=e2,k=-1;
      for(let i=a+1;i<b;i++){
        const t=vv?clamp(((points[i][0]-x)*vx+(points[i][1]-y)*vy)/vv,0,1):0;
        const d=(points[i][0]-x-t*vx)**2+(points[i][1]-y-t*vy)**2;
        if(d>far){far=d;k=i;}
      }
      if(k>=0){keep[k]=1;stack.push([a,k],[k,b]);}
    }
    return points.filter((_,i)=>keep[i]);
  }
  function rotate(p,c,s){return [c*p[0]+s*p[1],-s*p[0]+c*p[1]];}
  function extents(points){
    let x0=Infinity,y0=Infinity,x1=-Infinity,y1=-Infinity;
    for(const [x,y] of points){x0=Math.min(x0,x);x1=Math.max(x1,x);y0=Math.min(y0,y);y1=Math.max(y1,y);}
    return {x0,x1,y0,y1};
  }
  function overlaps(a,b){return a.left<b.right&&a.right>b.left&&a.top<b.bottom&&a.bottom>b.top;}
  // Liang-Barsky, includes segments crossing a rectangle with both endpoints outside.
  function segmentHits(a,b,r){
    let lo=0,hi=1;
    const dx=b[0]-a[0],dy=b[1]-a[1];
    for(const [p,q] of [[-dx,a[0]-r.left],[dx,r.right-a[0]],[-dy,a[1]-r.top],[dy,r.bottom-a[1]]]){
      if(Math.abs(p)<1e-12){if(q<0)return false;}
      else {const t=q/p;if(p<0)lo=Math.max(lo,t);else hi=Math.min(hi,t);if(lo>hi)return false;}
    }
    return true;
  }
  function markerBox(p,kind){
    // Destination pin is bottom-anchored. This protects the pin, not every POI label.
    return kind==='destination'
      ?{left:p[0]-23,right:p[0]+23,top:p[1]-46,bottom:p[1]+7}
      :{left:p[0]-18,right:p[0]+18,top:p[1]-18,bottom:p[1]+18};
  }
  function inRect(box,r,tol=0){return box.left>=r.left-tol&&box.right<=r.right+tol&&box.top>=r.top-tol&&box.bottom<=r.bottom+tol;}
  function normalViewport(v){
    const width=Number(v.width),height=Number(v.height);
    if(!Number.isFinite(width)||!Number.isFinite(height)||width<80||height<120)return null;
    const edge=Math.max(8,Number(v.edge)||12);
    const safe={left:edge,right:width-edge,top:edge,bottom:height-edge};
    const obstacles=(v.obstacles||[]).filter(r=>r&&[r.left,r.top,r.right,r.bottom].every(Number.isFinite))
      .map(r=>({left:clamp(r.left,0,width),right:clamp(r.right,0,width),top:clamp(r.top,0,height),bottom:clamp(r.bottom,0,height)}))
      .filter(r=>r.right>r.left&&r.bottom>r.top);
    return {width,height,safe,obstacles};
  }
  function prepare(coords,origin,destination){
    if(!valid(origin)||!valid(destination))return null;
    const line=(coords||[]).filter(valid);
    // Do not fabricate a road connection: separate marker points only affect fitting.
    const ref=mercator(origin),local=p=>{
      const m=mercator(p);let dx=m[0]-ref[0];dx-=Math.round(dx);
      return [dx*512,(m[1]-ref[1])*512];
    };
    const points=line.map(local),start=local(origin),end=local(destination);
    const all=[...points,start,end];
    return {ref,points,start,end,hull:hull(all),pointCount:line.length};
  }
  function solve(coords,origin,destination,viewport,options={}){
    const v=normalViewport(viewport),data=prepare(coords,origin,destination);
    if(!v||!data)return null;
    const maxZoom=clamp(Number.isFinite(options.maxZoom)?options.maxZoom:20,0,22);
    const maxScale=2**maxZoom;
    const span=extents(data.hull),dimension=Math.max(span.x1-span.x0,span.y1-span.y0,1e-8);
    const simplificationError=dimension/4000;
    const points=simplify(data.points,simplificationError);
    const obstacles=v.obstacles;
    const previous=Number.isFinite(options.previousBearing)?options.previousBearing:null;
    const full=options.full!==false||previous==null;
    let evaluations=0,collisionChecks=0;
    function atAngle(angle){
      evaluations++;
      const rad=angle*RAD,c=Math.cos(rad),s=Math.sin(rad);
      const shape=data.hull.map(p=>rotate(p,c,s)),bounds=extents(shape);
      const line=points.map(p=>rotate(p,c,s)),start=rotate(data.start,c,s),end=rotate(data.end,c,s);
      const w=v.safe.right-v.safe.left,h=v.safe.bottom-v.safe.top;
      const cap=Math.min(maxScale,w/Math.max(1e-10,bounds.x1-bounds.x0),h/Math.max(1e-10,bounds.y1-bounds.y0));
      function place(scale){
        // Legal translations keep every original route vertex and both marker glyphs visible.
        const startBox=markerBox([scale*start[0],scale*start[1]],'origin');
        const endBox=markerBox([scale*end[0],scale*end[1]],'destination');
        let x0=Math.max(v.safe.left-scale*bounds.x0,v.safe.left-startBox.left,v.safe.left-endBox.left);
        let x1=Math.min(v.safe.right-scale*bounds.x1,v.safe.right-startBox.right,v.safe.right-endBox.right);
        let y0=Math.max(v.safe.top-scale*bounds.y0,v.safe.top-startBox.top,v.safe.top-endBox.top);
        let y1=Math.min(v.safe.bottom-scale*bounds.y1,v.safe.bottom-startBox.bottom,v.safe.bottom-endBox.bottom);
        // Rider-first composition: bottom-right is a constraint, not a tiny tie-break.
        // A little zoom is deliberately sacrificed to stop diagonal layouts flipping corners.
        if(options.riderAnchor) {
          const anchor=options.anchorBounds || {left:.62,right:.80,top:.66,bottom:.88};
          x0=Math.max(x0,v.width*anchor.left-scale*start[0]);
          x1=Math.min(x1,v.width*anchor.right-scale*start[0]);
          y0=Math.max(y0,v.height*anchor.top-scale*start[1]);
          y1=Math.min(y1,v.height*anchor.bottom-scale*start[1]);
        }
        if(x0>x1||y0>y1)return null;
        const xs=[clamp(v.width*.70-scale*start[0],x0,x1),(x0+x1)/2,x0,x1];
        const ys=[clamp(v.height*.79-scale*start[1],y0,y1),(y0+y1)/2,y0,y1];
        const pad=6+simplificationError*scale;
        const inflated=obstacles.map(r=>({left:r.left-pad,right:r.right+pad,top:r.top-pad,bottom:r.bottom+pad}));
        const scaled=line.map(p=>[p[0]*scale,p[1]*scale]);
        let choice=null;
        for(const y of ys)for(const x of xs){
          const a=[scale*start[0]+x,scale*start[1]+y],b=[scale*end[0]+x,scale*end[1]+y];
          const mb1=markerBox(a,'origin'),mb2=markerBox(b,'destination');
          if(obstacles.some(r=>overlaps(mb1,r)||overlaps(mb2,r)))continue;
          const rbox={left:bounds.x0*scale+x,right:bounds.x1*scale+x,top:bounds.y0*scale+y,bottom:bounds.y1*scale+y};
          let blocked=false;
          for(const rect of inflated){
            if(!overlaps(rbox,rect))continue;
            const relative={left:rect.left-x,right:rect.right-x,top:rect.top-y,bottom:rect.bottom-y};
            for(let i=1;i<scaled.length;i++){
              collisionChecks++;
              if(segmentHits(scaled[i-1],scaled[i],relative)){blocked=true;break;}
            }
            if(blocked)break;
          }
          if(blocked)continue;
          // In a tie prefer the rider low and target high, but never sacrifice scale for a corner.
          const pref=options.riderAnchor
            ? -Math.hypot(a[0]/v.width-.70,a[1]/v.height-.79)+(a[1]-b[1])/v.height*.12
            : (a[1]-b[1])/v.height*.4-Math.abs((rbox.left+rbox.right)/2-v.width/2)/v.width*.06;
          if(!choice||pref>choice.preference)choice={x,y,scale,preference:pref,start:a,end:b};
        }
        return choice;
      }
      // Search the largest feasible scale, then refine to ~1 percent. No unbounded optimizer.
      let hi=cap,lo=0,fit=place(hi);
      if(!fit){
        for(let k=0;k<20;k++){
          const next=hi*.83,probe=place(next);
          if(probe){lo=next;fit=probe;break;}hi=next;
        }
        if(!fit)return null;
        for(let k=0;k<6;k++){
          const mid=(lo+hi)/2,probe=place(mid);
          if(probe){lo=mid;fit=probe;}else hi=mid;
        }
      }
      // Solve camera center from the screen translation; reset persistent navigation padding.
      const sx=(v.width/2-fit.x)/fit.scale,sy=(v.height/2-fit.y)/fit.scale;
      const center=lngLat([data.ref[0]+(c*sx-s*sy)/512,data.ref[1]+(s*sx+c*sy)/512]);
      const zoom=Math.log2(fit.scale);
      return {center,zoom,bearing:bearing(angle),pitch:0,padding:{top:0,right:0,bottom:0,left:0},
        offset:[0,0],start:fit.start,end:fit.end,preference:fit.preference,scale:fit.scale};
    }
    const candidates=[];
    const evaluate=a=>{const result=atAngle(a);if(result)candidates.push(result);};
    if(full){
      for(let a=-180;a<180;a+=6)evaluate(a);
      if(previous!=null)evaluate(previous);
    }else{
      for(let d=-12;d<=12;d+=3)evaluate(previous+d);
    }
    if(!candidates.length)return null;
    const targetGap=Math.max(18,Math.min(42,v.height*.04));
    const isTargetAbove=p=>p.start[1]>p.end[1]+targetGap;
    const score=p=>p.zoom+p.preference*.05-(options.riderAnchor&&previous!=null&&options.continuous?Math.abs(delta(p.bearing,previous))*.0025:0);
    candidates.sort((a,b)=>score(b)-score(a));
    const initialUpright=options.targetAbove?candidates.filter(isTargetAbove):[];
    // A local continuous search is not allowed to preserve a sideways/upside-down
    // composition. Return null so the caller immediately retries a full search.
    if(options.targetAbove && !full && !initialUpright.length)return null;
    const seeds=(initialUpright.length?initialUpright:candidates).slice(0,full?3:1);
    for(const p of seeds)for(let d=-3;d<=3;d+=.5)evaluate(p.bearing+d);
    candidates.sort((a,b)=>score(b)-score(a));
    const uprightCandidates=options.targetAbove?candidates.filter(isTargetAbove):[];
    const eligible=uprightCandidates.length?uprightCandidates:candidates;
    let best=eligible[0];
    // Legacy generic overview keeps its soft preference. FIT lock opts into
    // targetAbove and only falls back when no upright solution exists at all.
    if(!options.targetAbove && full && !options.continuous) {
      const upright=candidates.find(p=>p.start[1]>p.end[1]+20 && p.zoom>=best.zoom-.12);
      if(upright)best=upright;
    }
    // At almost-equal scales retain orientation rather than flip around symmetric routes.
    if(previous!=null && options.continuous){
      const stable=eligible.filter(p=>p.zoom>=best.zoom-(options.riderAnchor?.25:.055))
        .sort((a,b)=>Math.abs(delta(a.bearing,previous))-Math.abs(delta(b.bearing,previous)))[0];
      if(stable)best=stable;
    }
    // v0.3.35: never trade a tiny scale improvement for a large turn in layout.
    // All candidates here already obey the complete-polyline and rider-anchor constraints.
    if(options.riderAnchor && options.continuous && previous!=null && Math.abs(delta(best.bearing,previous))>35) {
      const steady=eligible.filter(p=>Math.abs(delta(p.bearing,previous))<=12 && p.zoom>=best.zoom-.35)
        .sort((a,b)=>Math.abs(delta(a.bearing,previous))-Math.abs(delta(b.bearing,previous)))[0];
      if(steady){best=steady;best.stabilityHeld=true;}
    }
    best.riderAnchor=!!options.riderAnchor;
    best.targetAbove=!!options.targetAbove && uprightCandidates.includes(best);
    best.stats={angleEvaluations:evaluations,collisionChecks,inputPoints:data.pointCount,collisionPoints:points.length,fullSearch:full};
    // Independent full-polyline certification, not just simplified geometry or endpoint boxes.
    if(!contains(best,coords,origin,destination,viewport))return null;
    return best;
  }
  function project(point,camera,width,height){
    const p=mercator(point),c=mercator(camera.center),scale=512*2**camera.zoom;
    let dx=p[0]-c[0];dx-=Math.round(dx);
    const q=rotate([dx*scale,(p[1]-c[1])*scale],Math.cos(camera.bearing*RAD),Math.sin(camera.bearing*RAD));
    return [q[0]+width/2,q[1]+height/2];
  }
  function contains(camera,coords,origin,destination,viewport){
    const v=normalViewport(viewport);if(!v||!camera||!valid(camera.center))return false;
    const line=(coords||[]).filter(valid).map(p=>project(p,camera,v.width,v.height));
    for(const p of line)if(!inRect({left:p[0],right:p[0],top:p[1],bottom:p[1]},v.safe,.1))return false;
    for(const [p,k] of [[origin,'origin'],[destination,'destination']]){
      const box=markerBox(project(p,camera,v.width,v.height),k);
      if(!inRect(box,v.safe,.1)||v.obstacles.some(r=>overlaps(box,r)))return false;
    }
    for(const r of v.obstacles){
      const expanded={left:r.left-4,right:r.right+4,top:r.top-4,bottom:r.bottom+4};
      for(let i=1;i<line.length;i++)if(segmentHits(line[i-1],line[i],expanded))return false;
    }
    return true;
  }
  return Object.freeze({solve,contains,project,mercator,lngLat,bearingDelta:delta});
});
