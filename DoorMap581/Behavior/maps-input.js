/* 581 Maps input parser v0.3.56 — shared by browser and Worker. No network or eval. */
(() => {
  'use strict';
  const hosts=new Set(['maps.app.goo.gl','maps.google.com','www.google.com','google.com',
    'maps.google.com.tw','www.google.com.tw','google.com.tw','goo.gl','consent.google.com']);
  function decode(value) {
    let s=String(value||'');
    s=s.replace(/\\u00([0-9a-f]{2})/gi,(_,h)=>String.fromCharCode(parseInt(h,16)))
      .replace(/\\x([0-9a-f]{2})/gi,(_,h)=>String.fromCharCode(parseInt(h,16)))
      .replace(/\\\//g,'/').replace(/&amp;|&#38;|&#x26;/gi,'&').replace(/&quot;|&#34;/gi,'"');
    for(let i=0;i<2;i++) {try{const d=decodeURIComponent(s);if(d===s)break;s=d;}catch(_){break;}}
    return s;
  }
  function valid(p) {return p && Number.isFinite(p.lat)&&Number.isFinite(p.lng)&&p.lat>=20&&p.lat<=27&&p.lng>=117&&p.lng<=123;}
  function coordinate(text) {
    const s=decode(text).trim().replace(/[′’]/g,"'").replace(/[″”]/g,'"');
    let m=s.match(/^\s*\(?\s*(-?\d{1,2}(?:\.\d+)?)\s*[,，]\s*(-?\d{2,3}(?:\.\d+)?)\s*\)?\s*$/);
    if(m){const p={lat:Number(m[1]),lng:Number(m[2])};return valid(p)?p:null;}
    m=s.match(/^(\d{1,2})\s*°\s*(\d{1,2})\s*'\s*(\d+(?:\.\d+)?)\s*"?\s*([NS])[\s,]+(\d{1,3})\s*°\s*(\d{1,2})\s*'\s*(\d+(?:\.\d+)?)\s*"?\s*([EW])$/i);
    if(!m || Number(m[2])>=60||Number(m[3])>=60||Number(m[6])>=60||Number(m[7])>=60)return null;
    const p={lat:(+m[1]+m[2]/60+m[3]/3600)*(m[4].toUpperCase()==='S'?-1:1),lng:(+m[5]+m[6]/60+m[7]/3600)*(m[8].toUpperCase()==='W'?-1:1)};
    return valid(p)?p:null;
  }
  function allowed(raw) {
    try {
      const u=new URL(raw);
      if(u.protocol!=='https:' || u.username || u.password || (u.port && u.port!=='443') || !hosts.has(u.hostname.toLowerCase()))return false;
      if(u.hostname==='goo.gl')return /^\/maps(?:\/|$)/.test(u.pathname);
      if(/^(?:www\.)?google\.com(?:\.tw)?$/.test(u.hostname))return /^\/(?:maps(?:\/|$)|url$)/.test(u.pathname);
      return true;
    }catch(_){return false;}
  }
  function extract(value) {
    const s=String(value||'').trim();
    let raw=(s.match(/https?:\/\/[^\s<>"'，。]+/i)||[])[0] || (/^(?:maps\.|(?:www\.)?google\.|goo\.gl\/maps)/i.test(s)?'https://'+s:null);
    if(!raw)return null;
    raw=raw.replace(/[）)\]】。]+$/,'');
    try {
      const u=new URL(raw);
      // Legacy http Maps links are normalized to https before any request.
      if(u.protocol==='http:')u.protocol='https:';
      return allowed(u.href)?u.href:null;
    }catch(_){return null;}
  }
  function nested(raw,depth=0) {
    if(depth>6)return null;
    const text=String(raw||'').trim();
    // Android intent URLs can carry the real web URL directly in the intent
    // authority/path instead of a link= query parameter. Reconstruct only an
    // https candidate and still require the ordinary Google Maps allowlist.
    if(/^intent:\/\//i.test(text)) {
      const head=text.split(/#Intent;/i)[0].replace(/^intent:\/\//i,'');
      const scheme=(text.match(/(?:^|;)scheme=([^;]+)/i)||[])[1]||'https';
      if(/^https?$/i.test(scheme)) {
        const candidate=`https://${head}`;
        if(allowed(candidate)){const inner=nested(candidate,depth+1);return inner||candidate;}
      }
    }
    // Google's iOS custom scheme often wraps an otherwise normal google.com/maps
    // URL. Never fetch the custom scheme; locally reconstruct the https target.
    const ios=text.match(/^(?:comgooglemapsurl|googlemaps):\/\/(.+)$/i);
    if(ios){
      const candidate='https://'+ios[1];
      if(allowed(candidate)){const inner=nested(candidate,depth+1);return inner||candidate;}
    }
    try {
      const u=new URL(text);
      for(const k of ['link','deep_link_id','continue','url','q','redirect','redirect_url','target','destination','fallback_url','browser_fallback_url']) {
        const value=u.searchParams.get(k);if(!value)continue;
        const candidate=decode(value);
        if(allowed(candidate))return candidate;
        const inner=nested(candidate,depth+1);if(inner)return inner;
      }
      // Android Firebase Dynamic Links can redirect to an intent:// wrapper. The
      // real web target is often carried in S.browser_fallback_url or S.link.
      const hash=String(u.hash||'');
      for(const key of ['S.browser_fallback_url','S.link','S.url']) {
        const re=new RegExp(`(?:^|;)${key.replace('.','\\.')}=([^;]+)`,'i'),m=hash.match(re);
        if(!m)continue;const candidate=decode(m[1]);if(allowed(candidate))return candidate;const inner=nested(candidate,depth+1);if(inner)return inner;
      }
    }catch(_){}
    return null;
  }
  function shortVariants(raw) {
    try {
      const u=new URL(raw);if(u.hostname.toLowerCase()!=='maps.app.goo.gl')return [];
      const base=new URL(u.href);for(const k of [...base.searchParams.keys()])if(k==='g_st'||k.startsWith('utm_'))base.searchParams.delete(k);
      const clean=base.href,debug=new URL(clean);debug.searchParams.set('d','1');
      return [...new Set([clean,debug.href])].filter(x=>x!==raw);
    }catch(_){return [];}
  }
  function placeIdentity(raw) {
    if(!allowed(raw))return null;
    try {
      const u=new URL(raw),text=decode(raw),ftid=u.searchParams.get('ftid')||
        (text.match(/!1s(0x[0-9a-f]{1,16}:0x[0-9a-f]{1,16})/i)||[])[1];
      if(ftid && /^0x[0-9a-f]{1,16}:0x[0-9a-f]{1,16}$/i.test(ftid))
        return {featureId:ftid.toLowerCase(),cid:BigInt(ftid.split(':')[1]).toString()};
      const cid=u.searchParams.get('cid');if(cid&&/^\d{1,20}$/.test(cid)&&BigInt(cid)>0n)return {featureId:'',cid:BigInt(cid).toString()};
    }catch(_){}
    return null;
  }
  function cidUrl(raw) {
    const id=placeIdentity(raw);return id?`https://maps.google.com/?cid=${id.cid}`:null;
  }
  function samePlaceIdentity(a,b) {return !!a&&!!b&&a.cid===b.cid;}
  function isPlacePreview(raw) {
    try{return allowed(raw)&&/^\/maps\/preview\/place(?:\/|$)/.test(new URL(raw).pathname);}catch(_){return false;}
  }
  function pointFromPlaceResponse(text,requestUrl) {
    // Google changes the nesting of preview/place payloads. Do NOT bind the
    // resolver to one brittle array index. Recursively locate a place record
    // that contains the SAME feature-id/CID as the requested place plus a
    // valid [..,lat,lng] location tuple. Viewport/camera tuples are rejected
    // because they are not attached to the verified place identity.
    const expected=placeIdentity(requestUrl);if(!expected)return null;
    const raw=String(text||'').slice(0,3000000).trim().replace(/^\)\]\}'\s*/, '');
    if(!raw.startsWith('['))return null;
    let data;try{data=JSON.parse(raw);}catch(_){return null;}
    const fidRe=/^0x[0-9a-f]{1,16}:0x[0-9a-f]{1,16}$/i,clean=v=>typeof v==='string'?v.replace(/[\u0000-\u001f<>]/g,' ').trim().slice(0,600):'';
    let found=null,budget=120000;
    function walk(node,depth=0){
      if(found||budget--<=0||depth>18||!Array.isArray(node))return;
      let fid='';for(const v of node){if(typeof v==='string'&&fidRe.test(v)){const id={cid:BigInt(v.split(':')[1]).toString()};if(samePlaceIdentity(expected,id)){fid=v;break;}}}
      if(fid){
        const tuples=[];for(const v of node){if(Array.isArray(v)&&v.length>=4&&typeof v[2]==='number'&&typeof v[3]==='number'&&valid({lat:v[2],lng:v[3]}))tuples.push(v);}
        // Prefer the compact place-location tuple [null,null,lat,lng]. A large
        // viewport tuple such as [distance,lng,lat] never satisfies this shape.
        const c=tuples.find(v=>v[0]==null&&v[1]==null)||tuples[0];
        if(c){
          const strings=node.filter(v=>typeof v==='string'&&!fidRe.test(v)).map(clean).filter(Boolean);
          const target=strings.find(v=>/[市縣區鄉鎮路街大道段巷弄號]/.test(v))||strings.find(v=>v.length>3)||'';
          const fi=node.indexOf(fid),candidate=clean(node[fi+1]),placeName=candidate&&!/^https?:|^[A-Za-z_]+\//.test(candidate)&&candidate.length<=120?candidate:'';
          const addressText=strings.find(v=>/[市縣].{1,8}[區鄉鎮].*(?:路|街|大道).*\d+(?:之\d+)?號/.test(v))||target;
          found={lat:c[2],lng:c[3],source:'google-place-record',placeId:fid,placeName,targetText:addressText};return;
        }
      }
      for(const v of node)if(Array.isArray(v))walk(v,depth+1);
    }
    walk(data);return found;
  }
  function pointFromHtml(html,base='https://www.google.com/maps/') {
    const s=decode(String(html||'').slice(0,3000000));
    // Place-specific OpenGraph/meta coordinates are terminal-place evidence, not
    // a camera center. Attribute order is intentionally ignored.
    const lats=[],lngs=[];
    for(const tag of s.match(/<meta\b[^>]{0,8192}>/gi)||[]) {
      const attrs={};for(const m of tag.matchAll(/([\w:-]+)\s*=\s*(["'])(.*?)\2/gs))attrs[m[1].toLowerCase()]=m[3];
      const key=String(attrs.property||attrs.name||attrs.itemprop||'').toLowerCase(),value=Number(attrs.content);
      if(!Number.isFinite(value))continue;
      if(key==='place:location:latitude'||key==='latitude')lats.push(value);
      if(key==='place:location:longitude'||key==='longitude'||key==='lng')lngs.push(value);
    }
    const lat=[...new Set(lats)],lng=[...new Set(lngs)];
    if(lat.length===1&&lng.length===1&&valid({lat:lat[0],lng:lng[0]}))return {lat:lat[0],lng:lng[0],source:'place-meta'};

    // Google app-share pages commonly embed a place-specific preview URL whose
    // @lat,lng is the place anchor. This is deliberately narrower than generic
    // /maps/@lat,lng, which remains rejected because it can be only viewport center.
    const points=[];
    for(const m of s.matchAll(/https:\/\/(?:maps\.|www\.)?google\.com(?:\.tw)?\/maps\/preview\/place\/[^\s"'<>\\]{1,8192}/gi)) {
      let u=m[0];try{u=new URL(u,base).href}catch(_){}
      const p=pointFromUrl(u);if(p)points.push(p);
    }
    const uniq=new Map(points.map(p=>[`${p.lat.toFixed(7)},${p.lng.toFixed(7)}`,p]));
    return uniq.size===1?[...uniq.values()][0]:null;
  }
  function pointFromUrl(raw,depth=0) {
    if(depth>5 || !allowed(raw))return null;
    const inner=nested(raw);if(inner && inner!==raw)return pointFromUrl(inner,depth+1);
    const u=new URL(raw),decoded=decode(raw),directions=/\/maps\/dir\//.test(u.pathname)||u.searchParams.has('destination');
    const preview=/\/maps\/preview\/place\//.test(u.pathname);
    if(preview) {
      const m=decoded.match(/\/maps\/preview\/place\/[^?#]*?\/@(-?\d{1,2}(?:\.\d+)?),(-?\d{2,3}(?:\.\d+)?)(?:,|\/|$)/i);
      if(m){const p={lat:Number(m[1]),lng:Number(m[2])};if(valid(p))return {...p,source:'preview-place-anchor'};}
    }
    // Never accept origin=, ll=, center= or @lat,lng as the destination.
    // Google's official Maps URL definition explicitly distinguishes center from destination.
    for(const key of ['destination','daddr','query','q']) {
      if(key==='query' && u.searchParams.has('query_place_id'))continue;
      if(key==='destination' && u.searchParams.has('destination_place_id'))continue;
      const p=coordinate(u.searchParams.get(key));if(p)return {...p,source:'query:'+key};
    }
    const matches=[...decoded.matchAll(/!3d(-?\d{1,2}(?:\.\d+)?)!4d(-?\d{2,3}(?:\.\d+)?)/g)]
      .map(m=>({lat:+m[1],lng:+m[2]})).filter(valid);
    if(matches.length===1)return {...matches[0],source:'place-data'};
    if(matches.length>1 && directions)return {...matches[matches.length-1],source:'direction-destination-data'};
    if(matches.length>1) {
      const keys=new Set(matches.map(p=>`${p.lat},${p.lng}`));
      if(keys.size===1)return {...matches[0],source:'place-data'};
      return null; // Ambiguous multi-place page is not a trustworthy destination.
    }
    const segments=u.pathname.split('/').filter(Boolean),place=segments.indexOf('place'),dir=segments.indexOf('dir');
    if(place>=0 && segments[place+1]) {
      const p=coordinate(decode(segments[place+1]).replace(/\+/g,' '));if(p)return {...p,source:'place-path'};
    }
    if(dir>=0) {
      const destinations=segments.slice(dir+1).filter(x=>!x.startsWith('@')&&!x.startsWith('data='));
      const p=coordinate(destinations.at(-1));if(p)return {...p,source:'direction-path'};
    }
    return null;
  }
  function targetText(raw) {
    try {
      const u=new URL(raw);
      for(const key of ['destination','daddr','query','q']) {
        const v=decode(u.searchParams.get(key)||'').replace(/\+/g,' ').trim();
        if(v && !coordinate(v) && !/https?:\/\//i.test(v))return v;
      }
      const parts=u.pathname.split('/'),i=parts.indexOf('place');
      if(i>=0){const s=decode(parts[i+1]||'').replace(/\+/g,' ');if(s&&!coordinate(s))return s;}
    }catch(_){}
    return '';
  }
  function htmlLinks(html,base) {
    const s=decode(String(html||'').slice(0,3000000)),priority=[],others=[];
    // Real Google place shells can put the authoritative /maps/preview/place?pb=...
    // preload in a single <link> tag well over 8 KiB. Extract that href directly
    // before the generic bounded tag parser; still require the normal Maps allowlist.
    for(const m of s.matchAll(/\bhref\s*=\s*(["'])(\/maps\/preview\/place\?[^"']{1,80000})\1/gi)){
      try{const u=new URL(m[2].replace(/&amp;/g,'&'),base).href;if(allowed(u))priority.push(u);}catch(_){}
    }
    // Attribute order is irrelevant; canonical/OG and mobile deep-links can put content first.
    for(const tag of s.match(/<(?:meta|link|a)\b[^>]{0,8192}>/gi)||[]) {
      const attrs={};for(const m of tag.matchAll(/([\w:-]+)\s*=\s*(["'])(.*?)\2/gs))attrs[m[1].toLowerCase()]=m[3];
      const special=/canonical|og:url|al:ios:url|al:android:url/i.test((attrs.rel||'')+' '+(attrs.property||''));
      let value=attrs.href||attrs.content;
      if(attrs['http-equiv']?.toLowerCase()==='refresh')value=(attrs.content||'').replace(/^.*?url\s*=\s*/i,'');
      if(!value)continue;
      try {const u=new URL(value,base).href;if(allowed(u))(special?priority:others).push(u);}catch(_){}
    }
    // Firebase/dynamic-link interstitials embed the real link in escaped JavaScript strings.
    for(const m of s.matchAll(/https:\/\/(?:maps\.app\.goo\.gl|(?:maps\.|www\.)?google\.com(?:\.tw)?|goo\.gl)\/[^\s"'<>\\]+/g)) {
      if(allowed(m[0]))others.push(m[0]);
    }
    // The d=1 Firebase preview may contain the deep link percent-encoded in
    // diagnostic markup rather than as an href. Extract only named URL fields,
    // decode locally, and keep the same allowlist boundary.
    for(const m of s.matchAll(/(?:link|deep_link_id|continue|url|redirect(?:_url)?)\s*[=:]\s*["']?([^"'<>\s&]{12,4096})/gi)) {
      const candidate=decode(m[1]);if(allowed(candidate))others.push(candidate);else {const inner=nested(candidate);if(inner)others.push(inner);}
    }
    return [...new Set([...priority,...others])].slice(0,40);
  }
  globalThis.DoorMapLinks=Object.freeze({decode,valid,coordinate,allowed,extract,nested,shortVariants,cidUrl,placeIdentity,samePlaceIdentity,isPlacePreview,pointFromPlaceResponse,pointFromUrl,pointFromHtml,targetText,htmlLinks});
})();
