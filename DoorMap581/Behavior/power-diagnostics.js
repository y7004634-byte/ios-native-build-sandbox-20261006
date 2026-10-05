/* 581 Door Map v0.3.58 — opt-in five-minute workload / power diagnostic.
 * Counts Door Map work. It does NOT record GPS coordinates, OS temperature,
 * watts, battery current, or upload telemetry. No IndexedDB writes per frame.
 */
(function(root,factory){const api=factory(root);if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.DoorPowerDiag=api;})(typeof globalThis!=='undefined'?globalThis:this,function(root){
'use strict';
const DEFAULT_MS=300000;
const KEYS=['gps','orientation','mapMove','mapRender','sourceWrite','sourceSkip','layerMove','routeRequest','houseBuild','houseRead','networkRequest','networkBytesKnown','longTask','longTaskMs','houseBuildAttempt','houseBuildSkip','houseReadAttempt','orientationSkip','headingUi'];
let longTaskSupported=false;
let run=null,lastReport=null,wrappedFetch=null,originalFetch=null,longObserver=null,visibilityHandler=null,tickTimer=null,stopTimer=null;
const now=()=>root.performance?.now?.()??Date.now();
function blank(){return Object.fromEntries(KEYS.map(k=>[k,0]));}
function active(){return !!run;}
function mark(key,n=1){if(!run||!Object.hasOwn(run.counts,key)||!Number.isFinite(Number(n)))return;run.counts[key]+=Number(n);}
function batterySnapshot(){const b=run?.battery;return b?{supported:true,startLevel:run.batteryStartLevel,endLevel:Number.isFinite(b.level)?b.level:null,charging:!!b.charging}: {supported:false};}
function foregroundUpdate(){if(!run)return;const t=now();if(!run.hidden)run.foregroundMs+=Math.max(0,t-run.lastVisibilityAt);run.lastVisibilityAt=t;run.hidden=!!root.document?.hidden;}
function hotspots(counts,minutes){const per=k=>(counts[k]||0)/Math.max(minutes,.001),out=[];
 if(per('mapRender')>1800)out.push('MapLibre render 很密集');
 if(per('layerMove')>300)out.push('圖層排序／moveLayer 偏高');
 if(per('sourceWrite')>180)out.push('GeoJSON setData 偏高');
 if(per('houseBuild')>90)out.push('門牌完整重建偏高');
 if(per('routeRequest')>3)out.push('路線重算偏高');
 if(per('networkRequest')>45)out.push('網路請求偏高');
 if(per('longTask')>8||(counts.longTaskMs||0)/Math.max(minutes,.001)>500)out.push('JS long task 偏高');
 return out;
}
function reportText(s){const c=s.counts,m=Math.max(s.durationMs/60000,.001),rate=k=>`${(c[k]/m).toFixed(c[k]/m<10?1:0)}/分`;
 const lines=[
  `581 5 分鐘運算／耗電診斷${s.running?'（進行中）':''}`,
  `時間 ${(s.durationMs/60000).toFixed(1)} 分 · 前景 ${(s.foregroundMs/60000).toFixed(1)} 分`,
  `方向畫面更新 ${c.headingUi} · 高頻略過 ${c.orientationSkip}`,
  `GPS ${c.gps}（${rate('gps')}） · 方向感測 ${c.orientation}（${rate('orientation')}）`,
  `地圖 move ${c.mapMove}（${rate('mapMove')}） · render ${c.mapRender}（${rate('mapRender')}）`,
  `圖層資料寫入 ${c.sourceWrite} · 相同資料跳過 ${c.sourceSkip} · moveLayer ${c.layerMove}`,
  `門牌實際重建 ${c.houseBuild} · 跳過 ${c.houseBuildSkip} · 呼叫 ${c.houseBuildAttempt}\n門牌實際讀取 ${c.houseRead} · 讀取呼叫 ${c.houseReadAttempt}`,
  `路線請求 ${c.routeRequest}`,
  `網路請求 ${c.networkRequest} · 已知回應量 ${(c.networkBytesKnown/1024).toFixed(1)} KiB`,
  s.longTaskSupported?`Long task ${c.longTask} · 合計 ${Math.round(c.longTaskMs)} ms`:'Long task：此瀏覽器不支援量測，不能以 0 當作無卡頓'
 ];
 const hot=hotspots(c,m);lines.push(hot.length?`高負載線索：${hot.join('、')}`:'高負載線索：目前計數沒有明顯失控項目');
 if(s.battery?.supported&&Number.isFinite(s.battery.startLevel)&&Number.isFinite(s.battery.endLevel))lines.push(`Battery API：${Math.round(s.battery.startLevel*100)}% → ${Math.round(s.battery.endLevel*100)}%（僅參考）`);
 else lines.push('iPhone Web App 無可靠溫度／瓦數權限；本報告只代表 Door Map 工作量。');
 return lines.join('\n');
}
function snapshot(){if(!run)return lastReport||{running:false,durationMs:0,foregroundMs:0,remainingMs:0,counts:blank(),battery:{supported:false},reportText:'尚未測試'};foregroundUpdate();const t=now(),durationMs=Math.max(0,t-run.startAt),remainingMs=Math.max(0,run.durationMs-durationMs);const s={running:true,durationMs,foregroundMs:run.foregroundMs,remainingMs,counts:{...run.counts},longTaskSupported,battery:batterySnapshot()};s.reportText=reportText(s);return s;}
function restore(){if(tickTimer){clearInterval(tickTimer);tickTimer=null;}if(stopTimer){clearTimeout(stopTimer);stopTimer=null;}if(visibilityHandler&&root.document?.removeEventListener)root.document.removeEventListener('visibilitychange',visibilityHandler);visibilityHandler=null;try{longObserver?.disconnect?.();}catch(_){}longObserver=null;if(originalFetch&&root.fetch===wrappedFetch)root.fetch=originalFetch;wrappedFetch=originalFetch=null;}
function stop(reason='complete'){if(!run)return lastReport;foregroundUpdate();const t=now(),durationMs=Math.max(0,t-run.startAt),s={running:false,reason,durationMs,foregroundMs:run.foregroundMs,remainingMs:0,counts:{...run.counts},longTaskSupported,battery:batterySnapshot()};s.reportText=reportText(s);const cb=run.onStop;lastReport=s;run=null;restore();try{cb?.(s);}catch(_){}return s;}
async function attachBattery(){if(!run||typeof root.navigator?.getBattery!=='function')return;try{const b=await root.navigator.getBattery();if(!run)return;run.battery=b;run.batteryStartLevel=Number.isFinite(b.level)?b.level:null;}catch(_){} }
function start({durationMs=DEFAULT_MS,onUpdate=null,onStop=null}={}){if(run)stop('restart');durationMs=Math.max(60000,Math.min(900000,Number(durationMs)||DEFAULT_MS));run={startAt:now(),durationMs,counts:blank(),foregroundMs:0,lastVisibilityAt:now(),hidden:!!root.document?.hidden,onUpdate,onStop,battery:null,batteryStartLevel:null};
 if(root.document?.addEventListener){visibilityHandler=()=>{foregroundUpdate();if(run&&now()-run.startAt>=run.durationMs)stop('complete');};root.document.addEventListener('visibilitychange',visibilityHandler);}
 if(typeof root.fetch==='function'){originalFetch=root.fetch;wrappedFetch=async function(...args){mark('networkRequest');const res=await originalFetch.apply(this,args);const n=Number(res?.headers?.get?.('content-length'));if(Number.isFinite(n)&&n>0)mark('networkBytesKnown',n);return res;};root.fetch=wrappedFetch;}
 longTaskSupported=false;
 if(typeof root.PerformanceObserver==='function'&&root.PerformanceObserver.supportedEntryTypes?.includes('longtask'))try{longTaskSupported=true;longObserver=new root.PerformanceObserver(list=>{for(const e of list.getEntries()){mark('longTask');mark('longTaskMs',e.duration||0);}});longObserver.observe({entryTypes:['longtask']});}catch(_){longTaskSupported=false;}
 attachBattery();tickTimer=setInterval(()=>{if(!run)return;try{run.onUpdate?.(snapshot());}catch(_){}},1000);stopTimer=setTimeout(()=>stop('complete'),durationMs);return snapshot();}
return Object.freeze({start,stop,mark,snapshot,active,DEFAULT_MS,keys:Object.freeze(KEYS.slice())});
});
