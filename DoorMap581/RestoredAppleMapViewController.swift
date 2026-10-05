import CoreLocation
import Darwin
import MapKit
import UIKit
import WebKit

/// Native Apple map with the complete pinned 0.3.78 interaction/planning surface.
final class RestoredAppleMapViewController: UIViewController, NativeBridgeDelegate, WKScriptMessageHandler, MKMapViewDelegate, UIGestureRecognizerDelegate, WKNavigationDelegate, WKUIDelegate {
    private let map = MKMapView()
    private var webView: NativeControlsWebView!
    private let nativeBridge = NativeBridge()
    private let locationBridge = LocationBridge()
    private let appleSearchBridge = AppleSearchBridge()
    private var server: NativeBundleServer?
    private var initialDeepLink: URL?
    private var preferences = MapPreferences.load()
    private var scene = NativeSceneOverlay()
    private var sceneRenderer: NativeSceneRenderer?
    private var nlscTiles: NativeNLSCTiles?
    private var nlscKey = ""
    private let testStatus = UILabel()
    private let openedAt = Date()
    private var readyMillis = 0.0
    private var sceneMaximumMillis = 0.0
    private var cameraMaximumMillis = 0.0
    private var cameraRequests = 0
    private var earlyGPS: MKPointAnnotation?
    private var contactIdentifiers:[ObjectIdentifier:Int]=[:]
    private var nextContactIdentifier=0
    private var symbols: [NativeSceneAnnotation] = []
    private var sequence = 0
    private var logicalCenter: [String: Double]?
    private var cameraMetrics: [String: Double] = [:]
    private var contacts: NativeContactObserver!
    private var gestureTransforms = Set<String>()
    private var lastContact: CGPoint = .zero
    private var ready = false
    private var lastGestureAt = 0.0
    private var active = true
    private var styleErrors: [String] = []
    private var sceneGeometryDigest = ""
    private var memoryPhase = 0
    private var memoryWebState: [String: Any] = [:]
    private var applePlace: [String: Any]?
    private var appleMapItem: MKMapItem?
    private var appleItemRequest: MKMapItemRequest?
    private var downloads: [ObjectIdentifier: URL] = [:]
    private let simulated = ProcessInfo.processInfo.environment["DOOR_UI_TEST"] == "1" || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init(initialDeepLink: URL?) {
        self.initialDeepLink = initialDeepLink
        super.init(nibName: nil, bundle: nil)
        if ProcessInfo.processInfo.arguments.contains("--reset-ui-test-preferences") {
            UserDefaults.standard.removeObject(forKey:MapPreferences.key);UserDefaults.standard.removeObject(forKey:SavedDestination.key);preferences = .init()
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        writeMemoryProfile(phase: "native-view-load")
        view.backgroundColor = .black
        configureMap(); configureWebView()
        NativeMemoryProfile.register(controller:self,map:map,webView:webView)
        writeMemoryProfile(phase: "native-views-configured")
        if !simulated {
            locationBridge.onLocation={ [weak self] fix in
                guard let self,!self.ready else{return}
                if self.earlyGPS==nil{let pin=MKPointAnnotation();pin.title="GPS 更新中";self.earlyGPS=pin;self.map.addAnnotation(pin)}
                self.earlyGPS?.coordinate=fix.coordinate
                self.map.setCamera(MKMapCamera(lookingAtCenter:fix.coordinate,fromDistance:750,pitch:0,heading:0),animated:false)
            }
            locationBridge.setContinuousLocationEnabled(true);locationBridge.requestOneShot()
        }
        if simulated { testStatus.isAccessibilityElement=true;testStatus.accessibilityIdentifier="native-restoration-status";testStatus.frame=CGRect(x:1,y:1,width:1,height:1);testStatus.textColor = .clear;view.addSubview(testStatus) }
        guard let root = Bundle.main.url(forResource: "Behavior", withExtension: nil) else { showFailure("缺少已核對的 3.78 測試版資源"); return }
        server = NativeBundleServer(bundleRoot: root, simulated: simulated)
        server?.start { [weak self] result in
            switch result {
            case .success(let base): self?.webView.load(URLRequest(url: base))
            case .failure(let error): self?.showFailure("測試版內部資源無法開啟：\(error.localizedDescription)")
            }
        }
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); updateHeadingOrientation();if !ready && earlyGPS == nil{_ = NativeCameraAdapter.apply(["center":["lat":24.1477,"lng":120.6736],"zoom":15.0,"pitch":0.0,"bearing":0.0],to:map)} }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); if ready { emitCamera() } }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.updateHeadingOrientation(); self?.emitCamera() }
    }
    private func configureMap() {
        map.translatesAutoresizingMaskIntoConstraints = false; map.delegate = self
        map.accessibilityIdentifier = "apple-main-map"
        map.showsUserLocation = false; map.showsCompass = false; map.showsScale = false
        map.selectableMapFeatures = [.pointsOfInterest]
        map.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 95, right: 0)
        view.addSubview(map)
        NSLayoutConstraint.activate([map.leadingAnchor.constraint(equalTo: view.leadingAnchor),map.trailingAnchor.constraint(equalTo: view.trailingAnchor),map.topAnchor.constraint(equalTo: view.topAnchor),map.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        map.setRegion(MKCoordinateRegion(center:.init(latitude:24.1477,longitude:120.6736),latitudinalMeters:2000,longitudinalMeters:2000),animated:false)
        map.addOverlay(scene,level:.aboveRoads)
        contacts = NativeContactObserver(target:nil,action:nil)
        contacts.delegate = self; contacts.cancelsTouchesInView = false; contacts.delaysTouchesBegan = false
        contacts.onContact = { [weak self] phase,touch,remaining in
            guard let self else { return }
            let point=touch.location(in:self.map);self.lastContact=point
            self.lastGestureAt=(Date().timeIntervalSince1970*1000).rounded(.down)
            if phase=="begin" && self.gestureTransforms.isEmpty { self.logicalCenter=nil }
            let key=ObjectIdentifier(touch)
            if self.contactIdentifiers[key]==nil{self.nextContactIdentifier += 1;self.contactIdentifiers[key]=self.nextContactIdentifier}
            self.evaluate("__581NativeGesture",["phase":phase,"x":point.x,"y":point.y,"pointerId":self.contactIdentifiers[key]!,"remaining":remaining])
            if phase=="end" || phase=="cancel"{self.contactIdentifiers.removeValue(forKey:key)}
            if (phase=="end"||phase=="cancel") && remaining==0 { self.gestureTransforms.removeAll();self.emitCamera(gesture:true) }
        }
        map.addGestureRecognizer(contacts)
        let tap=UITapGestureRecognizer(target:self,action:#selector(mapTapped(_:)));tap.delegate=self;tap.cancelsTouchesInView=false;map.addGestureRecognizer(tap)
        let hold=UILongPressGestureRecognizer(target:self,action:#selector(mapHeld(_:)));hold.minimumPressDuration=0.6;hold.delegate=self;hold.cancelsTouchesInView=false;map.addGestureRecognizer(hold)
        applyAppearance()
    }
    private func configureWebView() {
        let controller=WKUserContentController();controller.add(nativeBridge,name:AppConfig.nativeBridgeName);controller.add(WeakNativeScriptHandler(self),name:"appleMapEngine")
        controller.addUserScript(NativeBridge.bootstrapScript)
        if NativeMemoryProfile.enabled { controller.addUserScript(WKUserScript(source:"window.__581NativeMemoryProfile=true;",injectionTime:.atDocumentStart,forMainFrameOnly:true)) }
        if simulated && ProcessInfo.processInfo.arguments.contains("--reset-ui-test-preferences") {
            controller.addUserScript(WKUserScript(source:"localStorage.clear();sessionStorage.clear();",injectionTime:.atDocumentStart,forMainFrameOnly:true))
        }
        controller.addUserScript(WKUserScript(source:"window.__581NativeActive=true;Object.defineProperty(document,'hidden',{configurable:true,get:()=>!window.__581NativeActive});",injectionTime:.atDocumentStart,forMainFrameOnly:true))
        controller.addUserScript(NativeBridge.readyScript)
        let configuration=WKWebViewConfiguration();configuration.userContentController=controller;configuration.websiteDataStore = .default();configuration.allowsInlineMediaPlayback=true;configuration.applicationNameForUserAgent="DoorMap581AppleRestored/0.3.1"
        webView=NativeControlsWebView(frame:.zero,configuration:configuration);webView.isOpaque=false;webView.backgroundColor = .clear;webView.scrollView.backgroundColor = .clear;webView.scrollView.bounces=false;webView.scrollView.contentInsetAdjustmentBehavior = .never;webView.navigationDelegate=self;webView.uiDelegate=self;webView.translatesAutoresizingMaskIntoConstraints=false;webView.accessibilityIdentifier="restored-0378-controls"
        view.addSubview(webView);NSLayoutConstraint.activate([webView.leadingAnchor.constraint(equalTo:view.leadingAnchor),webView.trailingAnchor.constraint(equalTo:view.trailingAnchor),webView.topAnchor.constraint(equalTo:view.topAnchor),webView.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
        nativeBridge.delegate=self;locationBridge.webView=webView;appleSearchBridge.webView=webView
    }
    private func showFailure(_ text:String) {
        let label=UILabel();label.text=text;label.textColor = .white;label.numberOfLines=0;label.textAlignment = .center;label.frame=view.bounds.insetBy(dx:24,dy:100);label.autoresizingMask=[.flexibleWidth,.flexibleHeight];view.addSubview(label)
    }
    func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage) {
        guard message.name=="appleMapEngine",message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host=="127.0.0.1",message.frameInfo.securityOrigin.port==Int(NativeBundleServer.port),
              let body=message.body as? [String:Any],let type=body["type"] as? String else{return}
        let payload=body["payload"] as? [String:Any] ?? [:]
        switch type {
        case "camera":
            guard active,contacts.contacts.isEmpty,(payload["issuedAt"] as? Double ?? 0)>=lastGestureAt else{return}
            sequence=(payload["sequence"] as? Int) ?? sequence
            cameraRequests += 1
            logicalCenter=payload["center"] as? [String:Double]
            let began=CFAbsoluteTimeGetCurrent();cameraMetrics=NativeCameraAdapter.apply(payload,to:map);cameraMaximumMillis=max(cameraMaximumMillis,(CFAbsoluteTimeGetCurrent()-began)*1000);emitCamera()
        case "scene":
            let began=CFAbsoluteTimeGetCurrent()
            guard let rows=payload["features"] as? [[String:Any]] else{return}
            let features=rows.compactMap(NativeSceneFeature.init)
            if NativeMemoryProfile.enabled { sceneGeometryDigest=NativeMemoryProfile.digest(rows.map{["layer":$0["layer"] ?? "","source":$0["source"] ?? "","id":$0["id"] ?? "","geometry":$0["geometry"] ?? [:]]}) }
            styleErrors=payload["errors"] as? [String] ?? []
            scene.features=features;sceneRenderer?.setNeedsDisplay()
            updateNLSC(payload["rasterLayers"] as? [[String:Any]] ?? [])
            let old=Dictionary(uniqueKeysWithValues:symbols.map{($0.stableKey,$0)})
            var next:[NativeSceneAnnotation]=[],add:[NativeSceneAnnotation]=[],kept=Set<String>()
            for f in features where f.kind=="symbol"||f.kind=="circle" {
                guard let item=NativeSceneAnnotation(feature:f) else{continue}
                let key=item.stableKey;guard kept.insert(key).inserted else{continue}
                if let prior=old[key]{prior.feature=f;next.append(prior);(map.view(for:prior) as? NativeSceneAnnotationView)?.configure(prior)}else{next.append(item);add.append(item)}
            }
            map.removeAnnotations(symbols.filter{!kept.contains($0.stableKey)});symbols=next;map.addAnnotations(add)
            sceneMaximumMillis=max(sceneMaximumMillis,(CFAbsoluteTimeGetCurrent()-began)*1000);emitCamera()
        case "controls":
            webView.modalOpen=payload["modal"] as? Bool ?? false
            webView.controlRects=(payload["rects"] as? [[String:Double]] ?? []).compactMap{r in guard let x=r["x"],let y=r["y"],let w=r["width"],let h=r["height"] else{return nil};return CGRect(x:x,y:y,width:w,height:h)}
            if preferences.appearance != .system, let theme=payload["theme"] as? String,theme != preferences.appearance.rawValue {preferences.appearance=theme=="light" ? .light:.dark;preferences.save();applyAppearance()}
        case "settings":openSettings(payload["state"] as? [String:Any] ?? [:])
        case "resize":emitCamera()
        case "appleSelection":applePlace=payload
        case "themeSelection":if let theme=payload["theme"] as? String{preferences.appearance=theme=="light" ? .light:.dark;preferences.save();applyAppearance()}
        case "testStatus":if simulated{var result=payload;result["appReadyMillis"]=readyMillis;result["sceneMaximumMillis"]=sceneMaximumMillis;result["cameraMaximumMillis"]=cameraMaximumMillis;result["nativeResidentBytes"]=residentBytes();result["nativeCamera"]=cameraMetrics;result["cameraRequests"]=cameraRequests;result["memoryScope"]="native process only; WKWebContent is separate";if NativeMemoryProfile.enabled{memoryPhase=payload["memoryPhase"] as? Int ?? memoryPhase;memoryWebState=payload;result["memoryProfile"]=memoryProfileFields(phase:"stage-\(memoryPhase)");writeMemoryProfile(phase:"stage-\(memoryPhase)")};if let bytes=try? JSONSerialization.data(withJSONObject:result,options:.sortedKeys){testStatus.accessibilityValue=String(data:bytes,encoding:.utf8)}}
        case "stopCamera":break // JS owns animation. Never cancel a native pinch.
        default:break
        }
    }
    private func residentBytes()->UInt64 {
        var info=mach_task_basic_info(),count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
        let result=withUnsafeMutablePointer(to:&info){p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)}}
        return result==KERN_SUCCESS ? info.resident_size:0
    }
    private func memoryProfileFields(phase:String)->[String:Any] {
        let grouped=Dictionary(grouping:scene.features,by:{$0.layer}).mapValues{$0.count}
        return ["phase":phase,"active":active,"ready":ready,"appReadyMillis":readyMillis,"publicGeometry":scene.features.count,"publicSymbols":symbols.count,"sceneGeometrySHA256":sceneGeometryDigest,"sceneLayerCounts":grouped,"nativeOverlayCount":map.overlays.count,"nativeAnnotationCount":map.annotations.count,"server":server?.memoryCounters.snapshot() ?? [:],"web":memoryWebState,"cameraRequests":cameraRequests]
    }
    private func writeMemoryProfile(phase:String) {
        guard NativeMemoryProfile.enabled else{return}
        NativeMemoryProfile.write(memoryProfileFields(phase:phase))
    }
    private func updateNLSC(_ rows:[[String:Any]]) {
        guard let row=rows.first(where:{($0["id"] as? String)=="nlsc-detail-raster"}),
              let tiles=row["tiles"] as? [String],tiles==["https://wmts.nlsc.gov.tw/wmts/EMAP2/default/GoogleMapsCompatible/{z}/{y}/{x}"] else {
            if let nlscTiles{nlscTiles.suspendRequests();map.removeOverlay(nlscTiles)};nlscTiles=nil;nlscKey="";return
        }
        let brightness=row["brightness"] as? Double ?? 1,saturation=row["saturation"] as? Double ?? 0
        let key="\(brightness):\(saturation)";guard key != nlscKey else{return}
        if let nlscTiles{nlscTiles.suspendRequests();map.removeOverlay(nlscTiles)}
        let overlay=NativeNLSCTiles(brightness:brightness,saturation:saturation);nlscTiles=overlay;nlscKey=key;map.insertOverlay(overlay,below:scene)
    }
    private func evaluate(_ function:String,_ payload:[String:Any]) {
        guard ready,JSONSerialization.isValidJSONObject(payload),let bytes=try? JSONSerialization.data(withJSONObject:payload),let text=String(data:bytes,encoding:.utf8) else{return}
        webView.evaluateJavaScript("window.\(function)&&window.\(function)(\(text));")
    }
    private func emitCamera(gesture:Bool=false) {
        guard ready,map.bounds.width>0 else{return}
        let center=logicalCenter ?? ["lat":map.camera.centerCoordinate.latitude,"lng":map.camera.centerCoordinate.longitude]
        var data:[String:Any]=["sequence":sequence,"gesture":gesture,"camera":["center":center,"zoom":NativeCameraAdapter.measuredZoom(map),"bearing":map.camera.heading,"pitch":Double(map.camera.pitch)],"diagnostics":["mainRenderer":"MKMapView","publicGeometryFeatures":scene.features.count,"publicSymbols":symbols.count,"actualVisibleSymbolViews":symbols.filter{map.view(for:$0)?.isHidden==false}.count,"styleErrors":styleErrors,"camera":cameraMetrics,"extrusion":"original footprints and highlights; Apple 3D not individually recolored","simulatedSensors":simulated]]
        if let h=NativeCameraAdapter.homography(map){data["homography"]=h}
        evaluate("__581NativeMapUpdate",data)
    }
    private func applyAppearance() {
        overrideUserInterfaceStyle=preferences.appearance == .system ? .unspecified:preferences.appearance == .light ? .light:.dark
        // Accepted Mercator navigation has no terrain mesh; Apple 3D buildings remain enabled.
        let configuration=MKStandardMapConfiguration(elevationStyle:.flat,emphasisStyle:preferences.muted ? .muted:.default)
        configuration.pointOfInterestFilter=preferences.filter;configuration.showsTraffic=preferences.traffic;map.preferredConfiguration=configuration
        map.showsBuildings=preferences.buildings;map.isZoomEnabled=preferences.zoomGestures;map.isRotateEnabled=preferences.rotateGestures;map.isPitchEnabled=preferences.pitchGestures
    }
    private func openSettings(_ value:[String:Any]) {
        guard presentedViewController==nil else{return}
        preferences.followHeading=value["followHeading"] as? Bool ?? preferences.followHeading;preferences.routeVisible=value["routeVisible"] as? Bool ?? preferences.routeVisible;preferences.stations=value["stations"] as? Bool ?? preferences.stations
        if let mode=value["miniMode"] as? String,let selected=MiniMapMode(rawValue:mode){preferences.miniMode=selected}
        presentNativeSettings()
    }
    private func presentNativeSettings() {
        guard presentedViewController==nil else{return}
        preferences.pitch=Double(map.camera.pitch);preferences.heading=map.camera.heading;preferences.distance=map.camera.centerCoordinateDistance
        let settings=MapSettingsViewController(preferences);settings.hasApplePlace=applePlace != nil || appleMapItem != nil
        settings.cameraStatus={ [weak self] in guard let self else{return ""};return "Apple 實際傾角 \(Int(self.map.camera.pitch))° · 原版相機規則" }
        settings.onChange={ [weak self] value in
            guard let self else{return};let old=self.preferences;self.preferences=value;self.applyAppearance()
            var data:[String:Any]=["appearance":value.appearance.rawValue,"effectiveTheme":self.traitCollection.userInterfaceStyle == .light ? "light":"dark"]
            if old.miniMode != value.miniMode{data["miniMode"]=value.miniMode.rawValue}
            if old.routeVisible != value.routeVisible{data["routeVisible"]=value.routeVisible}
            if old.followHeading != value.followHeading{data["followHeading"]=value.followHeading}
            if old.pitch != value.pitch || old.heading != value.heading || old.distance != value.distance {
                let scale=value.distance/max(1,self.map.camera.centerCoordinateDistance)
                data["manualCamera"]=true;data["pitch"]=value.pitch;data["heading"]=value.heading;data["zoom"]=NativeCameraAdapter.measuredZoom(self.map)-log2(scale)
            }
            self.evaluate("__581NativeSettings",data)
            if old.stations != value.stations {self.webView.evaluateJavaScript("const b=document.getElementById('gogoroToggle');if(b&&b.checked!==\(value.stations)){b.checked=\(value.stations);b.dispatchEvent(new Event('change'));}")}
        }
        settings.onAction={ [weak self] action in
            guard let self else{return}
            if action=="open-production" {UIApplication.shared.open(AppConfig.liveBaseURL)}
            else if action=="refresh-stations" {self.webView.evaluateJavaScript("document.getElementById('gogoroRefreshBtn')?.click();")}
            else if action=="clear-destination" {self.webView.evaluateJavaScript("window.__581NativeClearDestination&&window.__581NativeClearDestination();")}
            else if action=="place-details" {self.showAppleDetails()}
        }
        present(UINavigationController(rootViewController:settings),animated:true)
    }
    private func showAppleDetails() {
        let name=appleMapItem?.name ?? applePlace?["name"] as? String ?? "Apple 商家",address=applePlace?["address"] as? String ?? ""
        let alert=UIAlertController(title:name,message:address,preferredStyle:.alert);alert.addAction(UIAlertAction(title:"完成",style:.cancel));present(alert,animated:true)
    }
    @objc private func mapTapped(_ recognizer:UITapGestureRecognizer){if recognizer.state == .ended{sendClick(recognizer.location(in:map))}}
    @objc private func mapHeld(_ recognizer:UILongPressGestureRecognizer){if recognizer.state == .began{sendClick(recognizer.location(in:map),longPress:true)}}
    private func sendClick(_ point:CGPoint,longPress:Bool=false){let c=map.convert(point,toCoordinateFrom:map);evaluate("__581NativeClick",["x":point.x,"y":point.y,"lngLat":["lng":c.longitude,"lat":c.latitude],"longPress":longPress])}
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer:UIGestureRecognizer)->Bool{true}
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive touch:UITouch)->Bool {
        if gestureRecognizer===contacts{return true}
        var target=touch.view
        while let item=target{if item is MKAnnotationView || item is UIControl{return false};target=item.superview}
        return true
    }
    private func transforms(in view:UIView)->[UIGestureRecognizer]{(view.gestureRecognizers ?? [])+view.subviews.flatMap{transforms(in:$0)}}
    func mapView(_ mapView:MKMapView,regionWillChangeAnimated animated:Bool){
        guard !contacts.contacts.isEmpty else{return}
        let candidates=transforms(in:map).filter{$0 !== contacts && ($0.state == .began || $0.state == .changed)}
        let names=candidates.map{r in r is UIPinchGestureRecognizer ? "zoomstart":r is UIRotationGestureRecognizer ? "rotatestart":"dragstart"}
        for name in Set(names) where !gestureTransforms.contains(name){gestureTransforms.insert(name);evaluate("__581NativeGesture",["phase":"move","x":lastContact.x,"y":lastContact.y,"transform":name])}
    }
    func mapViewDidChangeVisibleRegion(_ mapView:MKMapView){if !contacts.contacts.isEmpty{emitCamera(gesture:true)}}
    func mapView(_ mapView:MKMapView,regionDidChangeAnimated animated:Bool){emitCamera(gesture:!contacts.contacts.isEmpty)}
    func mapView(_ mapView:MKMapView,rendererFor overlay:MKOverlay)->MKOverlayRenderer{if overlay===scene{let r=NativeSceneRenderer(overlay:overlay);sceneRenderer=r;return r};if let tile=overlay as? NativeNLSCTiles{let r=MKTileOverlayRenderer(tileOverlay:tile);r.alpha=0.88;return r};return MKOverlayRenderer(overlay:overlay)}
    func mapView(_ mapView:MKMapView,viewFor annotation:MKAnnotation)->MKAnnotationView?{
        if let item=annotation as? NativeSceneAnnotation{let id="public-scene";let v=map.dequeueReusableAnnotationView(withIdentifier:id) as? NativeSceneAnnotationView ?? NativeSceneAnnotationView(annotation:item,reuseIdentifier:id);v.annotation=item;v.configure(item);return v}
        if let cluster=annotation as? MKClusterAnnotation{let v=MKMarkerAnnotationView(annotation:cluster,reuseIdentifier:"public-cluster");v.markerTintColor = .systemMint;v.glyphText=String(cluster.memberAnnotations.count);v.canShowCallout=false;return v}
        return nil
    }
    func mapView(_ mapView:MKMapView,didSelect view:MKAnnotationView){
        if let cluster=view.annotation as? MKClusterAnnotation{let p=map.convert(cluster.coordinate,toPointTo:map);evaluate("__581NativeCluster",["lng":cluster.coordinate.longitude,"lat":cluster.coordinate.latitude,"zoom":min(19,NativeCameraAdapter.measuredZoom(map)+2),"x":p.x,"y":p.y]);map.deselectAnnotation(cluster,animated:false);return}
        if let item=view.annotation as? NativeSceneAnnotation{sendClick(map.convert(item.coordinate,toPointTo:map));map.deselectAnnotation(item,animated:false);return}
        if #available(iOS 16.0,*),let feature=view.annotation as? MKMapFeatureAnnotation{
            appleItemRequest?.cancel();let request=MKMapItemRequest(mapFeatureAnnotation:feature);appleItemRequest=request
            request.getMapItem{ [weak self] item,error in DispatchQueue.main.async {guard let self,let item,error==nil,self.active else{return};self.appleMapItem=item;let alert=UIAlertController(title:item.name,message:item.placemark.title,preferredStyle:.alert);alert.addAction(UIAlertAction(title:"設為目的地",style:.default){_ in let c=item.placemark.coordinate;self.evaluate("__581NativeHandoff",["coordinate":["lat":c.latitude,"lng":c.longitude],"meta":["source":"apple-native-mapkit","placeName":item.name ?? "","addressText":item.placemark.title ?? ""]])});alert.addAction(UIAlertAction(title:"取消",style:.cancel));self.present(alert,animated:true)}}
        }
    }
    func notifyLifecycle(_ state:String){
        active=state=="foreground"||state=="willForeground";locationBridge.setAppActive(active)
        if active{updateHeadingOrientation()}else{appleItemRequest?.cancel();appleSearchBridge.cancel()}
        if state == "background" { server?.discardDisposableCaches(); nlscTiles?.suspendRequests() }
        if state == "willForeground" || state == "foreground", nlscTiles?.resumeRequests() == true {
            (map.renderer(for:nlscTiles!) as? MKTileOverlayRenderer)?.reloadData()
        }
        writeMemoryProfile(phase:"stage-\(memoryPhase)-\(state)")
        guard ready else{return}
        webView.evaluateJavaScript("window.__581NativeActive=\(active);document.dispatchEvent(new Event('visibilitychange'));window.dispatchEvent(new CustomEvent('door581:nativeLifecycle',{detail:{state:'\(state)'}}));")
    }
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        server?.discardDisposableCaches(); NativeNLSCTiles.clearImageCaches()
        if ready { webView.evaluateJavaScript("window.DoorNativeBundle?.releaseDisposableCaches();") }
    }
    func prepareForSceneDisconnect() {
        active=false;ready=false;locationBridge.setAppActive(false);locationBridge.setContinuousLocationEnabled(false)
        appleItemRequest?.cancel();appleSearchBridge.cancel();nlscTiles?.suspendRequests()
        contacts?.onContact=nil;map.delegate=nil;nativeBridge.delegate=nil
        if let webView { webView.stopLoading();webView.navigationDelegate=nil;webView.uiDelegate=nil;webView.configuration.userContentController.removeScriptMessageHandler(forName:"appleMapEngine");webView.configuration.userContentController.removeScriptMessageHandler(forName:AppConfig.nativeBridgeName) }
        server?.stop();server=nil
    }
    deinit { server?.stop(); nlscTiles?.suspendRequests() }
    private func updateHeadingOrientation(){guard let orientation=view.window?.windowScene?.interfaceOrientation else{return};let value:CLDeviceOrientation;switch orientation{case .landscapeLeft:value = .landscapeLeft;case .landscapeRight:value = .landscapeRight;case .portraitUpsideDown:value = .portraitUpsideDown;default:value = .portrait};locationBridge.setHeadingOrientation(value)}
    func requestNativeLocation(){if !simulated{locationBridge.requestOneShot()}}
    func setNativeLocationStreaming(_ enabled:Bool){if !simulated{locationBridge.setContinuousLocationEnabled(enabled)}}
    func searchApple(requestID:String,query:String,latitude:Double?,longitude:Double?,radiusM:Double){if !simulated{appleSearchBridge.search(requestID:requestID,query:query,latitude:latitude,longitude:longitude,radiusM:radiusM)}}
    func openExternalURL(_ url:URL){if ["http","https"].contains(url.scheme?.lowercased() ?? ""){UIApplication.shared.open(url)}}
    func webContentReady(){
        readyMillis=Date().timeIntervalSince(openedAt)*1000
        ready=true;notifyLifecycle(UIApplication.shared.applicationState == .active ? "foreground":"background")
        if simulated{webView.evaluateJavaScript("DoorNativeBundle.installUITestTools();")}
        else{if let earlyGPS{map.removeAnnotation(earlyGPS);self.earlyGPS=nil};locationBridge.replayFreshSamples();locationBridge.requestOneShot()}
        if let initialDeepLink{self.initialDeepLink=nil;handleIncomingURL(initialDeepLink)}
        if let stored=SavedDestination.load(){webView.evaluateJavaScript("if(!localStorage.getItem('581-door-dest'))window.__581NativeHandoff({coordinate:{lat:\(stored.latitude),lng:\(stored.longitude)},meta:{source:'manual-build6-migration'}});")}
        evaluate("__581NativeSettings",["appearance":preferences.appearance.rawValue,"effectiveTheme":traitCollection.userInterfaceStyle == .light ? "light":"dark","miniMode":preferences.miniMode.rawValue])
        emitCamera()
    }
    func handleIncomingURL(_ url:URL){guard ready else{initialDeepLink=url;return};switch DeepLinkRouter.payload(from:url){case .destination(let text):evaluate("__581NativeHandoff",["destination":text]);case .googleShare(let url):evaluate("__581NativeHandoff",["url":url]);case .home:break}}
    func webViewWebContentProcessDidTerminate(_ webView:WKWebView){ready=false;webView.reload()}
    override func traitCollectionDidChange(_ previousTraitCollection:UITraitCollection?){super.traitCollectionDidChange(previousTraitCollection);if ready,preferences.appearance == .system{evaluate("__581NativeSettings",["appearance":"system","effectiveTheme":traitCollection.userInterfaceStyle == .light ? "light":"dark"])}}
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){
        guard let url=navigationAction.request.url,navigationAction.targetFrame?.isMainFrame != false else{decisionHandler(.allow);return}
        if navigationAction.shouldPerformDownload{decisionHandler(.download);return}
        if url.host=="127.0.0.1" && url.port==Int(NativeBundleServer.port){decisionHandler(.allow);return}
        if ["blob","about","data"].contains(url.scheme ?? ""){decisionHandler(.allow);return}
        if ["http","https"].contains(url.scheme ?? ""){UIApplication.shared.open(url)};decisionHandler(.cancel)
    }
    func webView(_ webView:WKWebView,requestDeviceOrientationAndMotionPermissionFor origin:WKSecurityOrigin,initiatedByFrame frame:WKFrameInfo,decisionHandler:@escaping(WKPermissionDecision)->Void){decisionHandler(.deny)}
    func webView(_ webView:WKWebView,createWebViewWith configuration:WKWebViewConfiguration,for navigationAction:WKNavigationAction,windowFeatures:WKWindowFeatures)->WKWebView?{if let url=navigationAction.request.url{UIApplication.shared.open(url)};return nil}
    func webView(_ webView:WKWebView,runJavaScriptAlertPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping()->Void){
        let alert=UIAlertController(title:"581 Apple 測試",message:message,preferredStyle:.alert);alert.addAction(UIAlertAction(title:"完成",style:.default){_ in completionHandler()});presentScriptDialog(alert)
    }
    func webView(_ webView:WKWebView,runJavaScriptConfirmPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping(Bool)->Void){
        let alert=UIAlertController(title:"581 Apple 測試",message:message,preferredStyle:.alert);alert.addAction(UIAlertAction(title:"取消",style:.cancel){_ in completionHandler(false)});alert.addAction(UIAlertAction(title:"確認",style:.default){_ in completionHandler(true)});presentScriptDialog(alert)
    }
    private func presentScriptDialog(_ alert:UIAlertController){var host:UIViewController=self;while let presented=host.presentedViewController{host=presented};host.present(alert,animated:true)}
}

extension RestoredAppleMapViewController:WKDownloadDelegate{
    func webView(_ webView:WKWebView,navigationAction:WKNavigationAction,didBecome download:WKDownload){download.delegate=self}
    func webView(_ webView:WKWebView,navigationResponse:WKNavigationResponse,didBecome download:WKDownload){download.delegate=self}
    func download(_ download:WKDownload,decideDestinationUsing response:URLResponse,suggestedFilename:String,completionHandler:@escaping(URL?)->Void){
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("581-personal-export-"+UUID().uuidString,isDirectory:true)
        do{try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);let name=suggestedFilename.replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:":",with:"_");let url=directory.appendingPathComponent(name.isEmpty ? "581-personal-backup.json":name);downloads[ObjectIdentifier(download)]=url;completionHandler(url)}catch{completionHandler(nil)}
    }
    func downloadDidFinish(_ download:WKDownload){guard let url=downloads.removeValue(forKey:ObjectIdentifier(download))else{return};let sheet=UIActivityViewController(activityItems:[url],applicationActivities:nil);present(sheet,animated:true)}
    func download(_ download:WKDownload,didFailWithError error:Error,resumeData:Data?){downloads.removeValue(forKey:ObjectIdentifier(download))}
    func download(_ download:WKDownload,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void){completionHandler(.performDefaultHandling,nil)}
}
