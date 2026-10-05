/* 581 official-address add-on. Existing OSM database/builder/version remain untouched.
 * No startup network. Per-view tiles may be retained locally; full download is explicit.
 * Full-file receipts and their tiles commit together, so an interrupted install resumes.
 */
(function(root){'use strict';
const E=root.DoorExtras;
const VERSION='tcg-official-202608-v1',BASE='/offline/taichung-official-202608-v1';
const MANIFEST_SHA='e7be4459506dcf51ee14ad599b820fbe8a10d9dea3d3014b932f4907a51c2f31';
const TOTAL=756225,TILES=1145,DB_NAME='581-door-official-address-v1';
let manifest=null,manifestPending=null,activeInstall=null,generation=0;
const key=t=>`${VERSION}:${t}`;
const aborted=()=>new DOMException('已取消','AbortError');
function checkSignal(signal){if(signal?.aborted)throw aborted();}
function openDb(){return new Promise((resolve,reject)=>{
 if(!root.indexedDB)return reject(Error('此瀏覽器不支援 IndexedDB'));
 const r=root.indexedDB.open(DB_NAME,1);
 r.onupgradeneeded=()=>{for(const name of ['tiles','meta'])if(!r.result.objectStoreNames.contains(name))r.result.createObjectStore(name,{keyPath:'id'});};
 r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error||Error('官方門牌儲存空間無法開啟'));
 r.onblocked=()=>reject(Error('官方門牌儲存空間被其他分頁使用，請關閉舊分頁後重試'));
});}
async function getMany(store,ids){const db=await openDb();return new Promise((resolve,reject)=>{
 const out=new Array(ids.length),tx=db.transaction(store,'readonly');
 ids.forEach((id,i)=>{const r=tx.objectStore(store).get(id);r.onsuccess=()=>{out[i]=r.result||null;};});
 tx.oncomplete=()=>{db.close();resolve(out);};tx.onerror=tx.onabort=()=>{const e=tx.error;db.close();reject(e||Error('官方門牌讀取失敗'));};
});}
const get=async(s,id)=>(await getMany(s,[id]))[0];
async function commit(records=[],metaRecords=[],clear=false){const db=await openDb();return new Promise((resolve,reject)=>{
 const tx=db.transaction(['tiles','meta'],'readwrite');
 if(clear){tx.objectStore('tiles').clear();tx.objectStore('meta').clear();}
 for(const r of records)tx.objectStore('tiles').put(r);
 for(const r of metaRecords)tx.objectStore('meta').put(r);
 tx.oncomplete=()=>{db.close();resolve();};tx.onerror=tx.onabort=()=>{const e=tx.error;db.close();reject(e||Error('官方門牌儲存失敗，請檢查剩餘空間'));};
});}
async function digest(bytes){if(!root.crypto?.subtle)throw Error('官方門牌驗證需要 HTTPS');const b=await root.crypto.subtle.digest('SHA-256',bytes);return [...new Uint8Array(b)].map(x=>x.toString(16).padStart(2,'0')).join('');}
async function fetchVerified(path,expectedBytes,expectedSha,signal,maxBytes){
 checkSignal(signal);
 const u=new URL(path,root.location.origin);
 if(u.origin!==root.location.origin||!u.pathname.startsWith(BASE+'/'))throw Error('官方門牌僅允許同來源固定資料包');
 const ac=new AbortController(),cancel=()=>ac.abort();signal?.addEventListener('abort',cancel,{once:true});
 // An inactivity timeout, reset for each received chunk; not a fixed whole-file deadline.
 let timer;const arm=()=>{clearTimeout(timer);timer=setTimeout(()=>ac.abort(),30000);};arm();
 try{
  const r=await fetch(u.href,{signal:ac.signal,cache:'force-cache',headers:{Accept:'application/json'}});
  if(!r.ok)throw Error(`官方門牌 HTTP ${r.status}`);
  if(Number(r.headers.get('content-length'))>maxBytes)throw Error('官方門牌檔案過大');
  const reader=r.body?.getReader(),parts=[];let bytes=0;
  if(reader){try{while(true){const v=await reader.read();if(v.done)break;arm();bytes+=v.value.length;if(bytes>maxBytes){await reader.cancel();throw Error('官方門牌檔案過大');}parts.push(v.value);}}finally{reader.releaseLock();}}
  else{const b=new Uint8Array(await r.arrayBuffer());bytes=b.length;parts.push(b);}
  if(bytes>maxBytes||(expectedBytes&&bytes!==expectedBytes))throw Error('官方門牌檔案長度不符');
  const buf=new Uint8Array(bytes);let offset=0;for(const part of parts){buf.set(part,offset);offset+=part.length;}
  if(await digest(buf)!==expectedSha)throw Error('官方門牌 SHA-256 不符，未匯入');
  checkSignal(signal);return JSON.parse(new TextDecoder().decode(buf));
 }finally{clearTimeout(timer);signal?.removeEventListener('abort',cancel);}
}
function validateManifest(m){
 if(m?.version!==VERSION||m.addressCount!==TOTAL||m.tileCount!==TILES||m.gridZoom!==15||!Array.isArray(m.files)||Object.keys(m.tiles||{}).length!==TILES)throw Error('官方門牌清單版本／筆數不符');
 const seen=new Set();let rows=0;
 for(const f of m.files){if(!f.path.startsWith(BASE+'/bulk-')||!Array.isArray(f.tiles)||!/^[a-f0-9]{64}$/.test(f.sha256)||f.bytes>5*1024*1024)throw Error('官方門牌檔案清單不符');
  let count=0;for(const t of f.tiles){if(seen.has(t)||!m.tiles[t])throw Error('官方門牌格網重複／缺漏');seen.add(t);count+=m.tiles[t].count;}
  if(count!==f.count)throw Error('官方門牌檔案筆數不符');rows+=count;
 }
 if(seen.size!==TILES||rows!==TOTAL)throw Error('官方門牌清單未完整');return m;
}
async function loadManifest(signal){
 checkSignal(signal);if(manifest)return manifest;
 // No network unless this method is reached through an explicit full-offline install.
 if(manifestPending)return manifestPending;
 manifestPending=(async()=>{
  const saved=await get('meta','manifest').catch(()=>null);checkSignal(signal);
  if(saved?.sha256===MANIFEST_SHA&&saved.value){manifest=validateManifest(saved.value);return manifest;}
  const m=validateManifest(await fetchVerified(`${BASE}/manifest.json`,0,MANIFEST_SHA,signal,512*1024));
  checkSignal(signal);await commit([],[{id:'manifest',sha256:MANIFEST_SHA,value:m}]);manifest=m;return m;
 })().finally(()=>{manifestPending=null;});return manifestPending;
}
function tileKeys(p,radius){
 if(!E.point(p))return [];
 const r=Math.min(1500,Math.max(0,Number(radius)||0)),dlat=r/111320,dlng=dlat/Math.max(.3,Math.cos(p.lat*Math.PI/180)),n=2**15;
 const x=lng=>Math.floor((lng+180)/360*n),y=lat=>Math.floor((1-Math.asinh(Math.tan(lat*Math.PI/180))/Math.PI)/2*n);
 const out=[];for(let i=x(p.lng-dlng);i<=x(p.lng+dlng);i++)for(let j=y(p.lat+dlat);j<=y(p.lat-dlat);j++)out.push(`${i}/${j}`);
 return out.slice(0,25);
}
function validRawTile(tile){
 if(tile?.version!==VERSION||!/^\d+\/\d+$/.test(tile.tile)||!Array.isArray(tile.rows)||tile.rows.length>10000||!tile.rows.length)throw Error('官方門牌分片不符');
 const [x,y]=tile.tile.split('/').map(Number),b=E.gridBounds(x,y);
 for(const r of tile.rows){if(!Array.isArray(r)||r.length!==8||!E.point({lat:r[0],lng:r[1]})||typeof r[2]!=='string'||!r[2].trim()||r[0]>b.north||r[0]<=b.south||r[1]<b.west||r[1]>=b.east)throw Error('官方門牌點位／格網不符');}
 return tile;
}
async function rememberTile(tile,data){
 if(data?.version!==VERSION||data.tile!==tile||!data.official||data.source!=='taichung-official-address'||!Array.isArray(data.rows))return;
 const epoch=generation,old=await get('tiles',key(tile)).catch(()=>null);if(old?.verified||epoch!==generation)return;
 const raw={version:VERSION,tile,rows:data.rows.map(r=>[r.lat,r.lng,r.houseNumber,r.road||'',r.lane||'',r.alley||'',r.area||'',r.district||''])};
 validRawTile(raw);if(epoch!==generation)return;
 await commit([{...raw,id:key(tile),verified:false}]);
}
async function near(p,radius=140){
 if(!E.point(p))return [];
 const records=await getMany('tiles',tileKeys(p,radius).map(key)).catch(()=>[]),out=[];
 for(const rec of records){if(rec?.version!==VERSION||!Array.isArray(rec.rows))continue;
  for(const r of rec.rows){const distance=E.meters(p,{lat:r[0],lng:r[1]});if(distance>radius)continue;
   const row=E.officialRows([r])[0];out.push({...row,distance,containsDestination:distance<=6});}
 }
 return out.sort((a,b)=>a.distance-b.distance).slice(0,16000);
}
async function cachedTiles(names){
 const records=await getMany('tiles',names.slice(0,4).map(key)).catch(()=>[]),out=[];
 for(const rec of records){if(rec?.version!==VERSION)continue;try{validRawTile(rec);out.push({tile:rec.tile,rows:E.officialRows(rec.rows),version:VERSION,official:true});}catch(_){}}
 return out;
}
async function status(){const s=await get('meta','install').catch(()=>null);return {version:VERSION,total:TOTAL,dataDate:'2026-08',complete:s?.version===VERSION&&s?.manifestSha256===MANIFEST_SHA&&s?.count===TOTAL&&s?.complete===true,installedRows:s?.version===VERSION?Number(s.count)||0:0};}
async function install({onProgress=()=>{}}={}){
 if(activeInstall)throw Error('官方門牌下載已在執行');
 const ac=new AbortController(),epoch=generation;activeInstall=ac;
 try{
  const m=await loadManifest(ac.signal);checkSignal(ac.signal);
  let count=0,bytes=0,done=0;
  for(const file of m.files){
   checkSignal(ac.signal);if(epoch!==generation)throw aborted();
   const receipt=await get('meta',`file:${VERSION}:${file.id}`);
   if(receipt?.sha256!==file.sha256||receipt.count!==file.count){
    const obj=await fetchVerified(file.path,file.bytes,file.sha256,ac.signal,5*1024*1024);
    if(obj?.version!==VERSION||!Array.isArray(obj.tiles)||obj.tiles.length!==file.tiles.length)throw Error('官方門牌離線分片不符');
    const expected=new Set(file.tiles),records=[];let fileRows=0;
    for(const tile of obj.tiles){validRawTile(tile);if(!expected.delete(tile.tile)||tile.rows.length!==m.tiles[tile.tile]?.count)throw Error('官方門牌格網筆數不符');
     records.push({...tile,id:key(tile.tile),verified:true});fileRows+=tile.rows.length;}
    if(expected.size||fileRows!==file.count)throw Error('官方門牌下載筆數不符');
    checkSignal(ac.signal);if(epoch!==generation)throw aborted();
    // A receipt is never committed before its entire file has been validated and stored.
    await commit(records,[{id:`file:${VERSION}:${file.id}`,sha256:file.sha256,count:fileRows}]);
   }
   count+=file.count;bytes+=file.bytes;done++;
   await commit([],[{id:'install',version:VERSION,manifestSha256:MANIFEST_SHA,count,complete:false}]);
   onProgress({count,total:TOTAL,bytes,totalBytes:m.totalBulkBytes,files:done,totalFiles:m.files.length});
  }
  if(count!==TOTAL)throw Error('官方門牌離線安裝不完整');checkSignal(ac.signal);
  await commit([],[{id:'install',version:VERSION,manifestSha256:MANIFEST_SHA,count,complete:true,installedAt:Date.now()}]);
  return {count,bytes,files:done};
 }finally{activeInstall=null;}
}
async function clear(){generation++;activeInstall?.abort();manifest=null;await commit([],[],true);}
root.DoorOfficial=Object.freeze({VERSION,TOTAL,near,cachedTiles,rememberTile,install,status,clear});
})(globalThis);
