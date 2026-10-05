/* Door Map 0.3.74 — supplemental named-place index.
 * Supplements OSM-derived POIs; coordinates resolve through the existing official Taichung address lookup.
 * No GPS history and no background location use.
 */
(function(root){'use strict';
const SOURCES=[{id:'fatdaddy-directory',label:'胖老爹門市補充資料',rows:[
['胖老爹美式炸雞 學府店','台中市南區學府路125號','胖老爹|胖老爹炸雞|學府店'],
['胖老爹美式炸雞 北屯青島店','台中市北屯區青島路三段131號','胖老爹|胖老爹炸雞|青島店'],
['胖老爹美式炸雞 大雅店','台中市大雅區雅環路二段108號','胖老爹|胖老爹炸雞|大雅店'],
['胖老爹美式炸雞 中清店','台中市北屯區中清路二段936號','胖老爹|胖老爹炸雞|中清店'],
['胖老爹美式炸雞 忠勇店','台中市南屯區忠勇路62之4號','胖老爹|胖老爹炸雞|忠勇店'],
['胖老爹 河南店','台中市西屯區河南路二段193號','胖老爹|胖老爹炸雞|河南店|逢大'],
['胖老爹美式炸雞 大智店','台中市東區大智路50號','胖老爹|胖老爹炸雞|大智店'],
['胖老爹美式炸雞 工學店','台中市南區工學路98號','胖老爹|胖老爹炸雞|工學店'],
['胖老爹 烏日中山店','台中市烏日區中山路一段526號','胖老爹|胖老爹炸雞|烏日中山店'],
['胖老爹美式炸雞 博館店','台中市北區民權路440號','胖老爹|胖老爹炸雞|博館店'],
['胖老爹 漢口店','台中市西屯區漢口路二段237號','胖老爹|胖老爹炸雞|漢口店'],
['胖老爹美式炸雞 精武店','台中市東區精武路37之6號','胖老爹|胖老爹炸雞|精武店'],
['胖老爹美式炸雞 台中中華店','台中市中區中華路一段59號','胖老爹|胖老爹炸雞|中華店'],
['胖老爹美式炸雞 松竹店','台中市北屯區松竹路二段451號','胖老爹|胖老爹炸雞|松竹店'],
['胖老爹美式炸雞 樹孝店','台中市太平區樹孝路168之6號','胖老爹|胖老爹炸雞|樹孝店'],
['胖老爹美式炸雞 美術園道店','台中市西區五權五街57號','胖老爹|胖老爹炸雞|美術園道店|美村'],
['胖老爹 潭子復興店','台中市潭子區復興路一段31號','胖老爹|胖老爹炸雞|潭子復興店'],
['胖老爹 公益店','台中市南屯區公益路二段539號','胖老爹|胖老爹炸雞|公益店'],
['胖老爹 大里中興店','台中市大里區中興路一段167之2號','胖老爹|胖老爹炸雞|大里中興店'],
['胖老爹 進化店','台中市北區進化路659號','胖老爹|胖老爹炸雞|進化店'],
['胖老爹 大連店','台中市北屯區大連路三段173號','胖老爹|胖老爹炸雞|大連店']
]}];const norm=s=>String(s||'').normalize('NFKC').replace(/臺/g,'台').replace(/[\s,，。．·・_\-()（）\[\]【】]/g,'').toLowerCase();
const toks=s=>String(s||'').normalize('NFKC').replace(/臺/g,'台').toLowerCase().split(/[\s,，。．·・_\-()（）\[\]【】]+/).map(norm).filter(Boolean);
const files=new Map(),located=new Map();
function meters(a,b){if(!a||!b)return Infinity;const lat=(Number(a.lat)+Number(b.lat))*Math.PI/360;return Math.hypot((Number(a.lng)-Number(b.lng))*111320*Math.cos(lat),(Number(a.lat)-Number(b.lat))*111320);}
async function load(path){if(!files.has(path))files.set(path,fetch(path,{headers:{Accept:'application/json'},cache:'force-cache'}).then(r=>{if(!r.ok)throw Error('補充資料定位 HTTP '+r.status);return r.json();}));return files.get(path);}
function houseMain(value){const m=String(value||'').match(/\d+/);return m?Number(m[0]):null;}
async function addressPoint(text){
 if(!root.DoorGoogleAddress?.resolve)return null;
 const exact=await root.DoorGoogleAddress.resolve(text,load).catch(()=>null);if(exact)return {...exact,approximate:false};
 try{
  const catalog=await load('/official-lookup/roads.json'),parsed=root.DoorGoogleAddress.parse(text,catalog);if(!parsed)return null;
  const shard=await load('/official-lookup/'+String(parsed.bucket).padStart(3,'0')+'.json'),rows=shard?.[parsed.key]||[],target=houseMain(parsed.house);if(!Number.isFinite(target))return null;
  const lane=norm(parsed.lane),alley=norm(parsed.alley),parity=Math.abs(target)%2;
  const candidates=rows.map(r=>({r,n:houseMain(r[2])})).filter(x=>Number.isFinite(x.n)&&Math.abs(x.n)%2===parity&&norm(x.r[0])===lane&&norm(x.r[1])===alley&&Number.isFinite(Number(x.r[3]))&&Number.isFinite(Number(x.r[4]))).map(x=>({...x,gap:Math.abs(x.n-target)})).filter(x=>x.gap<=30).sort((a,b)=>a.gap-b.gap);
  const best=candidates[0];if(!best)return null;return {lat:Number(best.r[3]),lng:Number(best.r[4]),approximate:true,notice:'同一路同側門牌約略位置'};
 }catch(_){return null;}
}
async function locate(src,row){const key=src.id+'|'+row[1];if(located.has(key))return located.get(key);const p=(async()=>{const x=await addressPoint(row[1]);return x?{displayName:row[0],name:row[0],address:row[1],aliases:row[2],lat:Number(x.lat),lng:Number(x.lng),category:'commercial',feature:'fast_food',source:'supplemental-place',sourceLabel:src.label,verifiedAddress:!x.approximate,approximate:!!x.approximate,notice:x.notice||''}:null;})();located.set(key,p);return p;}
async function search(query,center=null,limit=12){const q=toks(query);if(!q.length)return [];const wanted=[];for(const src of SOURCES)for(const row of src.rows){const hay=[row[0],row[1],row[2]].map(norm);if(q.every(t=>hay.some(h=>h.includes(t))))wanted.push([src,row]);}const out=(await Promise.all(wanted.slice(0,30).map(([s,r])=>locate(s,r)))).filter(Boolean);for(const r of out)r.distanceM=center?meters(center,r):null;out.sort((a,b)=>(a.distanceM??Infinity)-(b.distanceM??Infinity));return out.slice(0,Math.max(1,Math.min(30,Number(limit)||12)));}
root.DoorSupplementalPoi={SOURCES,search,diagnostics:()=>({sources:SOURCES.length,rows:SOURCES.reduce((n,s)=>n+s.rows.length,0),located:located.size})};
})(globalThis);
