/* 581 v0.3.60: exact-address fallback. Never infer a shop Pin or nearest address. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;root.DoorGoogleAddress=api;})(globalThis,function(){
'use strict';
const norm=s=>String(s||'').normalize('NFKC').replace(/臺/g,'台').replace(/\s+/g,'').replace(/-/g,'之');
function parse(text,catalog){
 const raw=String(text||'').normalize('NFKC').trim(),s=norm(raw);
 const start=s.match(/^(?:\d{3,6})?(?:台灣)?台中市/);if(!start)return null;
 let rest=s.slice(start[0].length),district=Object.keys(catalog?.districts||{}).find(d=>rest.startsWith(d));if(!district)return null;
 rest=rest.slice(district.length);
 const roads=Object.keys(catalog.districts[district]).sort((a,b)=>b.length-a.length);let road='',after='';
 for(const r of roads){let at=rest.indexOf(r);if(at<0||at>12)continue;let prefix=rest.slice(0,at);if(prefix&&!/^.{1,8}[里村](?:\d+鄰)?$/.test(prefix))continue;road=r;after=rest.slice(at+r.length);break;}
 if(!road)return null;
 const m=after.match(/^(?:(\d+(?:之\d+)?巷))?(?:(\d+(?:之\d+)?弄))?(\d+(?:之\d+)?號)/);if(!m)return null;
 const lane=m[1]||'',alley=m[2]||'',house=m[3],tail=after.slice(m[0].length);
 // Keep supplied place text in its human-readable spelling, not nearest POI.
 const rawHouse=raw.match(/\d+(?:[之-]\d+)?\s*號/);let name=rawHouse?raw.slice(rawHouse.index+rawHouse[0].length).trim():'';
 const floor=(name.match(/(?:^|[\s,，])(?:地下\s*\d+\s*樓|B?\d{1,2}\s*[Ff樓](?:之\d+)?)(?:\s*\d+室)?\s*$/)||[])[0]||'';
 name=name.slice(0,Math.max(0,name.length-floor.length)).trim().replace(/^[,，·\s]+/,'');
 if(name.length>120||!/[A-Za-z\u3400-\u9fff]/.test(name))name='';
 return {district,road,lane,alley,house,bucket:catalog.districts[district][road],key:district+'|'+road,placeName:name,floor:floor.trim(),targetText:raw,addressText:'台中市'+district+road+lane+alley+house,tail};
}
function match(parsed,shard){if(!parsed)return [];const rows=shard?.[parsed.key]||[],out=new Map();
 for(const r of rows){if(norm(r[0])!==parsed.lane||norm(r[1])!==parsed.alley||norm(r[2])!==parsed.house)continue;
 const lat=Number(r[3]),lng=Number(r[4]);if(!Number.isFinite(lat)||!Number.isFinite(lng)||lat<20||lat>27||lng<117||lng>123)continue;
 out.set(lat.toFixed(7)+','+lng.toFixed(7),{lat,lng,source:'official-address-fallback',coordinateAuthority:'official-address',placeName:parsed.placeName,addressText:parsed.addressText,floor:parsed.floor,targetText:parsed.targetText,notice:'官方門牌定位（不是 Google 店家 Pin）',verifiedAddress:true});}
 return [...out.values()];}
async function resolve(text,load){const catalog=await load('/official-lookup/roads.json'),a=parse(text,catalog);if(!a)return null;const rows=match(a,await load('/official-lookup/'+String(a.bucket).padStart(3,'0')+'.json'));
 if(rows.length!==1)return null;return rows[0];}
return Object.freeze({norm,parse,match,resolve});
});
