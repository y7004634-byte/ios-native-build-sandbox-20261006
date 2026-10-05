/* Fixed-size destination card. No proximity-based name inference. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;root.DoorDestinationCard=api;})(globalThis,function(){
'use strict';
const clean=x=>String(x||'').replace(/[\u0000-\u001f<>]/g,' ').trim().slice(0,180);
function data(info={},meta={},hasDestination=true){
 const explicit=clean(meta.placeName||meta.stationName);
 const pinIdentity=clean(info.parentName||info.placeName);
 const name=explicit||pinIdentity||clean(info.trustedPlaceName||info.trustedParentName);
 const house=clean(info.houseLabel),road=clean(info.road).replace(/^.*?[市縣].*?[區鄉鎮]/,'');
 const address=clean(meta.addressText).replace(/^(?:台|臺)中市.{1,5}區/,'')||[road,house].filter(Boolean).join('');
 return {name:name||'終點門牌',detail:name?(address||house||'地址待查')+(meta.floor?' · '+clean(meta.floor):''):(house||(hasDestination?'待查門牌':'未設定')),named:!!name,notice:clean(meta.notice)};
}
function fit(el,max,min){if(!el)return;el.style.fontSize=max+'px';for(let n=max;n>min&&el.scrollWidth>el.clientWidth+1;n--)el.style.fontSize=(n-1)+'px';}
function render(caption,detail,view){if(!caption||!detail)return;const key=JSON.stringify(view)+'|'+caption.clientWidth+'|'+detail.clientWidth;if(detail.dataset.identity===key)return;detail.dataset.identity=key;caption.textContent=view.name;detail.textContent=view.detail;caption.title=view.name;detail.title=[view.name,view.detail,view.notice].filter(Boolean).join(' · ');caption.classList.toggle('named',view.named);fit(caption,view.named?16:12,10);fit(detail,view.named?21:28,11);}
return Object.freeze({data,render,fit});
});
