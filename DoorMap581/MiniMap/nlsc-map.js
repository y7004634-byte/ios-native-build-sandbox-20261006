(() => {
  'use strict';
  const post = v => window.webkit?.messageHandlers?.nlscMini?.postMessage(v);
  let editing=false, paused=true, session='', last=null, applying=false, dragging=false, allow=false, lastError=0;
  const map = new maplibregl.Map({container:'map',center:[120.6736,24.1477],zoom:18,minZoom:12,maxZoom:21,
    pitch:0,maxPitch:0,attributionControl:false,style:{version:8,sources:{nlsc:{type:'raster',tileSize:256,maxzoom:20,
      tiles:['https://wmts.nlsc.gov.tw/wmts/EMAP/default/GoogleMapsCompatible/{z}/{y}/{x}'],attribution:'國土測繪中心'}},
      layers:[{id:'nlsc',type:'raster',source:'nlsc'}]}});
  map.touchZoomRotate.disableRotation();
  const arrow=document.createElement('div');arrow.className='rider';
  const rider=new maplibregl.Marker({element:arrow,rotationAlignment:'map'});
  function updateCoordinate(){const c=map.getCenter();document.getElementById('coordinate').textContent=c.lat.toFixed(6)+','+c.lng.toFixed(6);}
  function paintSnapshot(){
    if(!last||!map.isStyleLoaded())return;
    applying=true;map.jumpTo({center:last.center,bearing:last.bearing,zoom:NLSCContract.zoom(last.metersPerPoint,last.center[1],1)});
    if(last.rider)rider.setLngLat(last.rider).setRotation(last.heading).addTo(map);else rider.remove();
    applying=false;updateCoordinate();
  }
  function begin(raw,token='browser'){
    const value=NLSCContract.parse(raw);if(!value)return false;
    last=value;session=String(token);editing=true;paused=false;paintSnapshot();return true;
  }
  function receive(raw){
    // Continuous main-map updates cannot pull a manually edited draft away.
    const value=NLSCContract.parse(raw);if(!value)return false;
    if(editing||dragging)return true;last=value;paintSnapshot();return true;
  }
  function theme(dark){document.documentElement.dataset.theme=dark?'dark':'light';}
  function allowCorrection(value){allow=!!value;document.getElementById('apply').disabled=!allow;}
  function pause(value){paused=!!value;if(paused)map.stop();}
  function end(){paused=true;editing=false;session='';map.stop();}
  map.on('dragstart',()=>{dragging=true;});
  map.on('dragend',()=>{dragging=false;updateCoordinate();});
  map.on('moveend',updateCoordinate);
  map.on('error',()=>{
    document.getElementById('error').style.display='block';
    if(Date.now()-lastError>30000){lastError=Date.now();post({type:'error'});}
  });
  map.on('sourcedata',e=>{if(e.sourceId==='nlsc'&&e.isSourceLoaded)document.getElementById('error').style.display='none';});
  map.on('load',()=>{post({type:'ready'});paintSnapshot();});
  document.getElementById('recenter').onclick=()=>{if(editing&&!paused)paintSnapshot();};
  document.getElementById('plus').onclick=()=>map.zoomIn();
  document.getElementById('minus').onclick=()=>map.zoomOut();
  document.getElementById('apply').onclick=()=>{
    if(!editing||paused||dragging||!allow)return;
    const c=map.getCenter();
    if(c.lat<20||c.lat>27||c.lng<117||c.lng>123)return;
    post({type:'correct',session,center:[c.lng,c.lat]});
  };
  window.NLSCMini=Object.freeze({begin,receive,theme,allowCorrection,pause,end,resize:()=>map.resize(),
    diagnostics:()=>({editing,paused,session,center:map.getCenter(),zoom:map.getZoom(),
      sourceIds:Object.keys(map.getStyle().sources),layerIds:map.getStyle().layers.map(x=>x.id)})});
})();
