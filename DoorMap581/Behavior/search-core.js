/* Shared query matching and truthful identity for list, local index and map PINs. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.DoorSearchCore=api;})(globalThis,function(){
 'use strict';
 const VERSION='0.3.78',RADIUS_M=3000;
 const variants={'臺':'台','湾':'灣','锅':'鍋','气':'氣','麦':'麥','当':'當','劳':'勞','岚':'嵐','妈':'媽','鸡':'雞','门':'門','号':'號','区':'區'};
 function normalize(v){return String(v||'').normalize('NFKC').replace(/[臺湾锅气麦当劳岚妈鸡门号区]/g,c=>variants[c]).toLowerCase().replace(/[\s\p{P}\p{S}]+/gu,'');}
 function tokens(v){return String(v||'').normalize('NFKC').replace(/(\d)[-－](?=\d)/g,'$1').split(/[\s,，。．·・_()（）\[\]【】]+/).map(normalize).filter(Boolean);}
 const ALIASES=[['711','7eleven','7-Eleven','7-11','統一超商'],['全家','全家便利商店','FamilyMart','Family Mart']];
 const CATEGORIES=[
  {words:['火鍋','鍋物','hotpot','hot_pot','shabu_shabu','涮涮鍋','臭臭鍋'],tag:'cuisine',values:['hotpot','hot_pot','shabu_shabu']},
  {words:['加油站','油站','fuel','gasstation','petrolstation'],tag:'amenity',values:['fuel']},
  {words:['咖啡','咖啡店','cafe','coffee_shop'],tag:'amenity',values:['cafe']},
  {words:['藥局','藥房','pharmacy'],tag:'amenity',values:['pharmacy']},
  {words:['超市','超級市場','supermarket'],tag:'shop',values:['supermarket']},
  {words:['便利商店','超商','convenience'],tag:'shop',values:['convenience']},
  {words:['餐廳','餐館','restaurant'],tag:'amenity',values:['restaurant']},
  {words:['銀行','bank'],tag:'amenity',values:['bank']},
  {words:['醫院','hospital'],tag:'amenity',values:['hospital']},
  {words:['診所','clinic'],tag:'amenity',values:['clinic']}
 ];
 function expand(t){const out=[t];for(const a of ALIASES)if(a.some(x=>normalize(x)===t))out.push(...a.map(normalize));for(const c of CATEGORIES)if(c.words.some(x=>normalize(x)===t))out.push(...c.words.map(normalize));return [...new Set(out)];}
 function meters(a,b){if(!a||!b)return Infinity;return Math.hypot((Number(a.lng)-Number(b.lng))*111320*Math.cos((Number(a.lat)+Number(b.lat))*Math.PI/360),(Number(a.lat)-Number(b.lat))*111320);}
 function oneEdit(a,b){if(Math.abs(a.length-b.length)>1)return false;if(a===b)return true;let i=0,j=0,n=0;while(i<a.length&&j<b.length){if(a[i]===b[j]){i++;j++;continue;}if(++n>1){return a.length===b.length&&i>0&&a[i]===b[i-1]&&a[i-1]===b[i]&&a.slice(i+1)===b.slice(i+1);}if(a.length>=b.length)i++;if(b.length>=a.length)j++;}return n+(i<a.length||j<b.length?1:0)<=1;}
 function fuzzyContains(field,t){if(t.length<4||(/^\d+$/.test(t)))return false;for(const len of [t.length,t.length-1,t.length+1]){if(len<3||len>field.length)continue;for(let i=0;i<=field.length-len;i++)if(oneEdit(t,field.slice(i,i+len)))return true;}return false;}
 function metadata(tags={}){return [tags.shop,tags.amenity,tags.cuisine,tags.office,tags.tourism,tags.leisure,...Object.entries(tags).filter(([k])=>/^(name:|brand:|operator:)/.test(k)).map(([,v])=>v)].filter(Boolean).join('|');}
 function fromTags(tags,point,osmKey,source='overpass'){
  const displayName=String(tags.name||tags['name:zh-Hant']||tags['name:zh']||tags.brand||'').trim();if(!displayName)return null;
  const road=tags['addr:street']||tags['addr:place']||'',house=tags['addr:housenumber']||'';
  return {...point,displayName,branch:String(tags.branch||''),address:String(tags['addr:full']||[tags['addr:city'],tags['addr:district'],road+(house?String(house).replace(/號$/,'')+'號':'')].filter(Boolean).join('')),aliases:[tags['name:zh-Hant'],tags['name:zh'],tags.alt_name,tags.short_name,tags.official_name,tags.brand,tags.operator].filter(Boolean).join('|'),searchMetadata:metadata(tags),feature:tags.amenity||tags.shop||tags.tourism||'',osmKey,source};
 }
 function fromRow(r){return {displayName:r[1],aliases:r[2],lat:Number(r[3]),lng:Number(r[4]),address:r[5],category:r[6],feature:r[7],osmKey:r[8],branch:r[9]||'',locationHint:r[10]||'',searchMetadata:r[11]||'',source:'offline-index'};}
 function locationText(r){return [r.branch&&!normalize(r.displayName).includes(normalize(r.branch))?r.branch:'',r.address||r.locationHint||`座標 ${Number(r.lat).toFixed(5)}, ${Number(r.lng).toFixed(5)}`,r.source==='official-community'?'官方社區地址點（非入口）':''].filter(Boolean).join(' · ');}
 const fieldCache=new WeakMap();
 function fields(r){if(fieldCache.has(r))return fieldCache.get(r);const f={name:normalize(r.displayName||r.name),branch:normalize(r.branch),names:[r.displayName||r.name,...String(r.aliases||'').split('|'),r.branch].map(normalize).filter(Boolean),location:[r.address,String(r.locationHint||'').split('座標')[0]].map(normalize).filter(Boolean),meta:[r.category,r.feature,...String(r.searchMetadata||'').split(/[|;]/)].map(normalize).filter(Boolean)};f.combined=normalize((r.displayName||r.name||'')+(r.branch||''));fieldCache.set(r,f);return f;}
 function compile(query){const ts=tokens(query);return {ts,q:normalize(query),parts:ts.map(t=>({token:t,vs:expand(t),identityOnly:ALIASES.some(a=>a.some(w=>normalize(w)===t))||CATEGORIES.some(c=>c.words.some(w=>normalize(w)===t))}))};}
 function matchFields(r,plan){const {ts}=plan;if(!ts.length)return null;const f=fields(r);let fuzzy=false;
  for(const {token,vs,identityOnly} of plan.parts){const hay=[...f.names,...f.meta,f.combined,...(identityOnly?[]:f.location)];if(vs.some(t=>hay.some(v=>v.includes(t))))continue;
   if(f.names.some(v=>fuzzyContains(v,token))){fuzzy=true;continue;}return null;
  }
  const q=plan.q,specific=ts.length>1||q.length>=5||!!(f.branch&&f.branch===q),exact=!!(f.branch&&f.branch===q)||(specific&&(f.name===q||f.combined===q));
  return {fuzzy,exact,specific};
 }
 function match(r,query){const plan=typeof query==='string'?compile(query):query;let best=matchFields(r,plan);if(r.communityId)for(const source of r.identitySources||[]){if(!(r.osmAliases||[]).includes(source.osmKey))continue;const found=matchFields(source,plan);if(found&&(!best||Number(found.exact)>Number(best.exact)||(found.exact===best.exact&&best.fuzzy&&!found.fuzzy)))best=found;}return best;}
 function key(r){if(r.communityId)return 'official-community:'+r.communityId;const pair=r.osmKey?String(r.osmKey).split(/[/:]/):[r.osmType,r.osmId];if(pair[0]&&pair[1]){const type=String(pair[0]).toLowerCase();return (({n:'node',w:'way',r:'relation'})[type]||type)+':'+pair[1];}return `${Number(r.lat).toFixed(5)}:${Number(r.lng).toFixed(5)}:${r.displayName||r.name||''}`;}
 function rankResults(groups,query,center){const seen=new Set(),out=[],plan=compile(query),officialOsm=new Set();for(const group of groups||[])for(const r of group||[])if(r.communityId&&match(r,plan))for(const id of r.osmAliases||[])officialOsm.add(key({osmKey:id}));for(const group of groups||[])for(const r of group||[]){if(!Number.isFinite(Number(r.lat))||!Number.isFinite(Number(r.lng)))continue;const m=match(r,plan);if(!m)continue;const k=key(r);if(!r.communityId&&officialOsm.has(k))continue;if(seen.has(k))continue;seen.add(k);out.push({...r,distanceM:center?meters(center,r):null,matchKind:m.fuzzy?'typo-tolerant':'direct',matchPriority:m.exact?0:(m.specific&&m.fuzzy?2:1)});}
  if(out.filter(r=>r.matchPriority===0).length>2)for(const r of out)if(r.matchPriority===0)r.matchPriority=1;
  out.sort((a,b)=>a.matchPriority-b.matchPriority||(a.distanceM??Infinity)-(b.distanceM??Infinity)||String(a.displayName).localeCompare(String(b.displayName),'zh-Hant'));return out;
 }
 function nearby(rows,center){return center?(rows||[]).filter(r=>meters(center,r)<=RADIUS_M):[];}
 function remotePlan(query){const ts=tokens(query),terms=[String(query).trim(),...ts.flatMap(expand)];for(const t of ts)for(const a of ALIASES)if(a.some(w=>normalize(w)===t))terms.push(...a);return {tokens:ts,terms:[...new Set(terms)],categories:CATEGORIES.filter(c=>ts.some(t=>c.words.some(w=>normalize(w)===t)))};}
 return {VERSION,RADIUS_M,normalize,tokens,meters,oneEdit,match,metadata,fromTags,fromRow,locationText,key,rankResults,nearby,remotePlan};
});
