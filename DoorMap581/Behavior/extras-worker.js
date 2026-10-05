import {OFFICIAL_VERSION,OFFICIAL_BASE,OFFICIAL_TILES} from './official-address-index.js';
import './map-extras.js';
const E=globalThis.DoorExtras;
const STATION_SOURCES=['https://official-site-pro.gogoroapp.com/PartnerService/Gogoro/GetVmList?offset=0&pageSize=10000'];
const OVERPASS=['https://overpass.private.coffee/api/interpreter','https://overpass-api.de/api/interpreter','https://maps.mail.ru/osm/tools/overpass/api/interpreter'];
const inflight=new Map();
async function limitedJson(response,maxBytes){
 if(!response.ok)throw Error(`upstream ${response.status}`);
 if(Number(response.headers.get('content-length'))>maxBytes)throw Error('upstream response too large');
 const reader=response.body?.getReader();if(!reader){const t=await response.text();if(t.length>maxBytes)throw Error('upstream response too large');return JSON.parse(t);}
 const parts=[];let length=0;try{while(true){const {value,done}=await reader.read();if(done)break;length+=value.length;if(length>maxBytes){await reader.cancel();throw Error('upstream response too large');}parts.push(value);}}finally{reader.releaseLock();}
 const b=new Uint8Array(length);let i=0;for(const p of parts){b.set(p,i);i+=p.length;}return JSON.parse(new TextDecoder().decode(b));
}
async function cached(key){try{const r=await caches.default.match(new Request(key));return r?await r.json():null;}catch(_){return null;}}
async function store(key,obj,ttl){try{await caches.default.put(new Request(key),Response.json(obj,{headers:{'Cache-Control':`public, max-age=${ttl}`}}));}catch(_){}}
async function single(key,fn){if(inflight.has(key))return inflight.get(key);const p=fn().finally(()=>inflight.delete(key));inflight.set(key,p);return p;}
const response=(x,code=200)=>Response.json(x,{status:code,headers:{'Cache-Control':'no-store'}});
async function publicGogoro(url,signal){
 const allowed=new Set(['official-site-pro.gogoroapp.com','wapi.gogoro.com','www.gogoro.com','gogoro.com','network.gogoro.com']);
 for(let i=0;i<4;i++){
  const u=new URL(url);if(u.protocol!=='https:'||!allowed.has(u.hostname)||u.username||u.password||u.port)throw Error('unexpected official redirect');
  const r=await fetch(u.href,{headers:{Accept:'application/json'},redirect:'manual',signal});
  if([301,302,303,307,308].includes(r.status)){
   const location=r.headers.get('location');if(!location)throw Error('missing official redirect');
   await r.body?.cancel();url=new URL(location,u).href;continue;
  }
  return {response:r,url:u.href};
 }
 throw Error('too many official redirects');
}
async function loadStations(origin){
 const key=`${origin}/__581_gogoro_positions_v2`,now=Date.now(),old=await cached(key),age=now-Number(old?.fetchedAt);
 if(old?.stations?.length&&age>=0&&age<6*3600000)return {...old,cached:true,stale:false};
 return single(key,async()=>{
  let err;for(const url of STATION_SOURCES){const ac=new AbortController(),timer=setTimeout(()=>ac.abort(),6500);
   try{
    // Fixed public endpoints only. No login/session token or arbitrary-URL proxy.
    const got=await publicGogoro(url,ac.signal);
    const rows=E.stations(await limitedJson(got.response,10*1024*1024));
    const data={stations:rows,fetchedAt:Date.now(),source:got.url,attribution:'Gogoro 公開站點資料',liveBatteries:false,stale:false};
    await store(key,data,7*86400);return data;
   }catch(e){err=e;}finally{clearTimeout(timer);}
  }
  if(old?.stations?.length&&age>=0&&age<7*86400000)return {...old,cached:true,stale:true};
  throw Error(`官方站點暫時無法取得；不代表附近沒有站點 (${String(err?.message||'unavailable').slice(0,80)})`);
 });
}
async function loadHouseTile(url,env){
 const x=Number(url.searchParams.get('x')),y=Number(url.searchParams.get('y'));
 if(!url.searchParams.has('x')||!url.searchParams.has('y'))throw Error('invalid address tile');
 const b=E.gridBounds(x,y),tile=`${x}/${y}`;
 if(OFFICIAL_TILES.has(tile)){
  const key=`${url.origin}/__581_official_house/${OFFICIAL_VERSION}/${tile}`;
  const old=await cached(key);if(old?.version===OFFICIAL_VERSION&&Array.isArray(old.rows)&&old.rows.length)return {...old,cached:true};
  return single(key,async()=>{
   if(!env?.ASSETS?.fetch)throw Error('官方門牌靜態資產未連接');
   // Known versioned assets only; no source download, external proxy, or guessed points.
   const r=await env.ASSETS.fetch(new Request(`${url.origin}${OFFICIAL_BASE}/tiles/${x}-${y}.json`));
   const raw=await limitedJson(r,1024*1024);
   if(raw?.version!==OFFICIAL_VERSION||raw.tile!==tile||!raw.rows?.length)throw Error('官方門牌分片版本或格網不符');
   const rows=E.officialRows(raw.rows);
   if(rows.some(p=>p.lng<b.west||p.lng>=b.east||p.lat>b.north||p.lat<=b.south))throw Error('官方門牌超出分片');
   const data={rows,version:OFFICIAL_VERSION,tile,fetchedAt:Date.now(),dataDate:'2026-08',source:'taichung-official-address',attribution:'臺中市官方 GIS 門牌 · 2026-08',official:true,truncated:false};
   await store(key,data,7*86400);return data;
  });
 }
 const key=`${url.origin}/__581_house_nodes_v1/${x}/${y}`;
 const old=await cached(key),age=Date.now()-Number(old?.fetchedAt);
 if(Array.isArray(old?.rows)&&age>=0&&age<7*86400000)return {...old,cached:true};
 return single(key,async()=>{
  const query=`[out:json][timeout:9];node["addr:housenumber"](${b.south.toFixed(7)},${b.west.toFixed(7)},${b.north.toFixed(7)},${b.east.toFixed(7)});out body 6000;`;
  let err;for(const base of OVERPASS){const ac=new AbortController(),timer=setTimeout(()=>ac.abort(),10500);
   try{const r=await fetch(base,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:`data=${encodeURIComponent(query)}`,signal:ac.signal,redirect:'error'});
    const raw=await limitedJson(r,5*1024*1024);if(raw.remark)throw Error('incomplete OSM query');
    const data={rows:E.houseRows(raw),fetchedAt:Date.now(),source:'OpenStreetMap address nodes',attribution:'© OpenStreetMap contributors · ODbL',truncated:raw.elements.length>=6000};
    await store(key,data,7*86400);return data;
   }catch(e){err=e;}finally{clearTimeout(timer);}
  }throw Error(`門牌來源暫時不可用 (${String(err?.message||'unavailable').slice(0,60)})`);
 });
}
export async function extrasRequest(request,env){
 const u=new URL(request.url);if(!['/api/gogoro-stations','/api/house-numbers'].includes(u.pathname))return null;
 if(request.method!=='GET')return response({error:'GET required'},405);
 try{if(u.pathname==='/api/gogoro-stations')return response(await loadStations(u.origin));
  try{if(!u.searchParams.has('x')||!u.searchParams.has('y'))throw Error();E.gridBounds(Number(u.searchParams.get('x')),Number(u.searchParams.get('y')));}catch(_){return response({error:'invalid Taiwan address tile'},400);}
  return response(await loadHouseTile(u,env));
 }catch(e){return response({error:String(e?.message||e)},502);}
}
