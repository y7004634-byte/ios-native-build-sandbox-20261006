/* 581 Door Map v0.3.78 — compact local Taichung POI search.
 * Reads a dedicated small static index generated from the existing prebuilt OSM
 * pack. It never scans the 163 MB phone-side OSM tile database during typing.
 * The static index is cached in its own IndexedDB after first load.
 */
(function(root,factory){
  const api=factory(root);
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.DoorLocalSearch=api;
})(typeof globalThis!=='undefined'?globalThis:this,function(root){
  'use strict';
  const VERSION='tcg-search-202609-v4-master-r2';
  const Core=root.DoorSearchCore||(typeof require==='function'?require('./search-core.js'):null);
  const converted=new WeakMap();
  const INDEX_URL='/offline/taichung-prebuilt/search-index.json';
  const DB='581-door-search-v1',STORE='index',KEY='taichung';
  let rows=null,pending=null,lastSource='none',lastError='';
  

  function normalize(value){return String(value||'').normalize('NFKC').replace(/臺/g,'台').replace(/[\s,，。．·・_\-()（）\[\]【】]/g,'').toLowerCase();}
  function tokens(value){const s=String(value||'').normalize('NFKC').replace(/臺/g,'台').toLowerCase().replace(/(\d)[-－](?=\d)/g,'$1');return s.split(/[\s,，。．·・_\-()（）\[\]【】]+/).map(normalize).filter(Boolean);}
  function validPoint(lat,lng){return Number.isFinite(lat)&&Number.isFinite(lng)&&lat>=20&&lat<=27&&lng>=117&&lng<=123;}
  function meters(a,b){
    if(!a||!b)return Infinity;
    const lat=(Number(a.lat)+Number(b.lat))*Math.PI/360;
    return Math.hypot((Number(a.lng)-Number(b.lng))*111320*Math.cos(lat),(Number(a.lat)-Number(b.lat))*111320);
  }
  function openDb(){return new Promise((resolve,reject)=>{
    if(!root.indexedDB)return reject(Error('IndexedDB unavailable'));
    const r=root.indexedDB.open(DB,1);
    r.onupgradeneeded=()=>{if(!r.result.objectStoreNames.contains(STORE))r.result.createObjectStore(STORE,{keyPath:'id'});};
    r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error||Error('search cache open failed'));
  });}
  async function dbGet(){const db=await openDb();return await new Promise((resolve,reject)=>{const tx=db.transaction(STORE,'readonly'),r=tx.objectStore(STORE).get(KEY);r.onsuccess=()=>resolve(r.result||null);r.onerror=()=>reject(r.error);tx.oncomplete=()=>db.close();});}
  async function dbPut(value){const db=await openDb();return await new Promise((resolve,reject)=>{const tx=db.transaction(STORE,'readwrite');tx.objectStore(STORE).put(value);tx.oncomplete=()=>{db.close();resolve();};tx.onerror=tx.onabort=()=>{const e=tx.error;db.close();reject(e);};});}
  function validate(obj){
    if(!obj||obj.version!==VERSION||!Array.isArray(obj.rows)||obj.rows.length<100)throw Error('本機搜尋索引格式不符');
    const out=[];
    for(const r of obj.rows){
      if(!Array.isArray(r)||r.length<8)continue;
      const lat=Number(r[3]),lng=Number(r[4]);if(!validPoint(lat,lng))continue;
      const n=String(r[0]||''),name=String(r[1]||'').trim();if(!n||!name)continue;
      out.push([n,name,String(r[2]||''),lat,lng,String(r[5]||''),String(r[6]||''),String(r[7]||''),String(r[8]||''),String(r[9]||''),String(r[10]||''),String(r[11]||'')]);
    }
    if(out.length<100)throw Error('本機搜尋索引有效資料不足');
    return out;
  }
  async function fetchIndex(){
    // Only time-bound the request until response headers arrive. The index is a
    // ~3.4 MB same-origin static file; aborting while iPhone/WebKit is still
    // downloading/parsing the body turns a slow first load into a false
    // "no local candidates" result.
    const ctl=new AbortController(),timer=setTimeout(()=>ctl.abort(),15000);
    const u=new root.URL(INDEX_URL,root.location?.origin||'https://local.invalid');u.searchParams.set('v',VERSION);
    let res;
    try{
      res=await fetch(u.href,{headers:{Accept:'application/json','Cache-Control':'no-cache'},cache:'no-store',signal:ctl.signal});
    }finally{clearTimeout(timer);}
    if(!res.ok)throw Error(`搜尋索引 HTTP ${res.status}`);
    const obj=await res.json(),parsed=validate(obj);
    rows=parsed;lastSource='network';lastError='';
    await dbPut({id:KEY,version:VERSION,rows:obj.rows,savedAt:Date.now()}).catch(()=>{});
    return rows;
  }
  async function ensure(){
    if(rows)return rows;if(pending)return pending;
    pending=(async()=>{
      try{
        const saved=await dbGet().catch(()=>null);
        if(saved?.version===VERSION&&Array.isArray(saved.rows)){
          rows=validate({version:VERSION,rows:saved.rows});lastSource='idb';lastError='';return rows;
        }
        return await fetchIndex();
      }catch(err){lastError=String(err?.message||err);throw err;}
      finally{pending=null;}
    })();return pending;
  }
  function searchRows(data,query,center=null,limit=12){
    if(!Array.isArray(data)||!Core)return [];
    if(!converted.has(data))converted.set(data,data.map(Core.fromRow));
    const matches=Core.rankResults([converted.get(data)],query,center);
    return limit===Infinity?matches:matches.slice(0,Math.max(1,Number(limit)||12));
  }
  async function search(query,center=null,limit=12){
    let data;try{data=await ensure();}catch(_){return [];}
    return searchRows(data,query,center,limit);
  }
  async function searchAll(query,center=null){
    let data;try{data=await ensure();}catch(_){return [];}
    const cap=normalize(query).length<2?200:Infinity;
    return searchRows(data,query,center,cap);
  }
  function diagnostics(){return {version:VERSION,ready:!!rows&&!pending,count:rows?.length||0,pending:!!pending,source:lastSource,error:lastError};}
  function clearMemory(){rows=null;pending=null;lastSource='none';lastError='';}
  return {VERSION,URL:INDEX_URL,normalize:Core.normalize,validate,searchRows,ensure,search,searchAll,diagnostics,clearMemory};
});
