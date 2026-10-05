import CoreLocation
import MapKit
import UIKit

final class NativeAppleMapViewController: UIViewController, MKMapViewDelegate, UITextFieldDelegate {
    private let map = MKMapView(), mini = NLSCMiniMapView(frame: .zero), location = LocationBridge(), stations = BatteryStationStore()
    private let searchPanel = GlassPanel(), miniPanel = GlassPanel(), controls = UIView()
    private let field = UITextField(), icon = UIImageView(image: UIImage(systemName: "magnifyingglass")), status = UILabel()
    private let paste = UIButton(type: .system), searchButton = UIButton(type: .system), capsule = UIButton(type: .system)
    private let closeMini = UIButton(type: .system), info = UIButton(type: .system), overview = UIButton(type: .system)
    private let follow = UIButton(type: .system), direction = UIButton(type: .system), plan = UIButton(type: .system), more = UIButton(type: .system)
    private var prefs = MapPreferences.load(), coordinate: CLLocation?, heading = 0.0, active = true, following = false, gesture = false
    private var lastSave = Date.distantPast, lastFollow = Date.distantPast, lastMini: MiniMapMode?
    private var selected: MKMapItem?, destination: CLLocationCoordinate2D?, titleText = "未設定", corrected = false
    private var pin: MKPointAnnotation?, line: MKPolyline?, route: NativeRoute?, progress: NativeRouteProgress?
    private var routeTask: URLSessionDataTask?, routeToken = UUID(), search: MKLocalSearch?, searchToken = UUID()
    private var featureRequest: MKMapItemRequest?, featureToken = UUID(), stationOn = false, stationMessage = ""
    private var stationPins: [BatteryStationAnnotation] = []
    private let initialURL: URL?
    init(initialDeepLink: URL?) { initialURL = initialDeepLink; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--reset-ui-test-preferences") {
            UserDefaults.standard.removeObject(forKey: MapPreferences.key)
            UserDefaults.standard.removeObject(forKey: SavedDestination.key); prefs = .init()
        }
        #endif
        map.frame = view.bounds; map.delegate = self; map.accessibilityIdentifier = "apple-main-map"
        map.showsCompass = false; map.showsScale = false; map.selectableMapFeatures = [.pointsOfInterest]
        view.backgroundColor = .systemBackground
        [map, searchPanel, miniPanel, controls, status].forEach(view.addSubview)
        var center = CLLocationCoordinate2D(latitude: 24.1477, longitude: 120.6736)
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOOR_UI_TEST"] == "1" { center = .init(latitude: 24.133708, longitude: 120.668796) }
        #endif
        map.setCamera(MKMapCamera(lookingAtCenter: center, fromDistance: prefs.distance, pitch: CGFloat(prefs.pitch), heading: prefs.heading), animated: false)
        buildUI()
        mini.onCorrection = { [weak self] in self?.applyCorrection($0) }
        mini.onError = { [weak self] _ in self?.announce("門牌圖磚暫不可用") }
        location.onLocation = { [weak self] in self?.receivedLocation($0) }
        location.onHeading = { [weak self] h in self?.heading = h; self?.followCamera() }
        location.onError = { [weak self] in self?.announce($0) }
        stations.onChange = { [weak self] snapshot, message in
            guard let self, self.prefs.stations else { return }
            self.stationMessage = message; self.map.removeAnnotations(self.stationPins)
            self.stationPins = (snapshot?.stations ?? []).map(BatteryStationAnnotation.init); self.map.addAnnotations(self.stationPins)
        }
        applyPreferences()
        if let saved = SavedDestination.load() {
            choose(nil, point: saved.coordinate, title: saved.title, persist: true, move: false)
            corrected = saved.manuallyCorrected; updateCapsule()
        }
        if let initialURL { handleIncomingURL(initialURL) }
        announce("等待定位")
    }
    private func buildUI() {
        searchPanel.layer.cornerRadius = 18; miniPanel.layer.cornerRadius = 18
        field.placeholder = "搜尋地址、店家、地標或座標"; field.font = .systemFont(ofSize: 13)
        field.returnKeyType = .search; field.clearButtonMode = .whileEditing
        field.autocorrectionType = .no; field.autocapitalizationType = .none; field.delegate = self; field.accessibilityIdentifier = "destination-search"
        icon.tintColor = .label
        [icon, field, paste, searchButton].forEach(searchPanel.contentView.addSubview)
        for (button, text, id, action) in [(paste,"貼上","paste",#selector(pasteDestination)), (searchButton,"搜尋","destination-submit",#selector(submitSearch))] {
            button.setTitle(text, for: .normal); button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            button.layer.cornerRadius = 12; button.layer.borderWidth = 1; button.accessibilityIdentifier = id
            button.addTarget(self, action: action, for: .touchUpInside)
        }
        [mini, capsule, info, closeMini].forEach(miniPanel.contentView.addSubview)
        capsule.titleLabel?.font = .systemFont(ofSize: 23, weight: .bold)
        capsule.titleLabel?.adjustsFontSizeToFitWidth = true; capsule.titleLabel?.minimumScaleFactor = 0.7
        capsule.titleLabel?.lineBreakMode = .byTruncatingTail; capsule.contentHorizontalAlignment = .left
        capsule.contentEdgeInsets = .init(top: 0, left: 12, bottom: 0, right: 12)
        capsule.titleEdgeInsets = .init(top: 0, left: 10, bottom: 0, right: 0)
        capsule.accessibilityIdentifier = "destination-capsule"; capsule.addTarget(self, action: #selector(toggleMini), for: .touchUpInside)
        makeRound(info, symbol: "info.circle", label: "商家資訊", id: "destination-info", action: #selector(showDetails))
        makeRound(closeMini, symbol: "xmark", label: "關閉門牌小圖", id: "close-mini", action: #selector(hideMini))
        makeRound(follow, symbol: "location", label: "定位並跟隨", id: "follow", action: #selector(locate))
        makeRound(direction, symbol: "arrow.up", label: "前行或固定方向", id: "heading", action: #selector(toggleHeading))
        makeRound(plan, symbol: "point.topleft.down.curvedto.point.bottomright.up", label: "規劃機車路線", id: "plan-route", action: #selector(planRoute))
        makeRound(more, symbol: "ellipsis", label: "更多設定", id: "more", action: #selector(showSettings))
        overview.layer.cornerRadius = 18; overview.layer.borderWidth = 1
        overview.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        overview.titleLabel?.numberOfLines = 3; overview.titleLabel?.textAlignment = .center
        overview.setTitle("全程\n-- km\n-- 分", for: .normal); overview.accessibilityIdentifier = "overview"
        overview.addTarget(self, action: #selector(showRoute), for: .touchUpInside)
        [overview, follow, direction, plan, more].forEach(controls.addSubview)
        status.font = .systemFont(ofSize: 11, weight: .medium); status.textColor = .secondaryLabel
        status.backgroundColor = .secondarySystemBackground; status.layer.cornerRadius = 10
        status.clipsToBounds = true; status.textAlignment = .center; status.accessibilityIdentifier = "map-status"
        map.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(selectCoordinate(_:))))
        updateCapsule()
    }
    private func makeRound(_ b: UIButton, symbol: String, label: String, id: String, action: Selector) {
        b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)), for: .normal)
        b.layer.cornerRadius = 23; b.layer.borderWidth = 1; b.accessibilityIdentifier = id; b.accessibilityLabel = label
        b.addTarget(self, action: action, for: .touchUpInside)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); map.frame = view.bounds
        let s = view.bounds.inset(by: view.safeAreaInsets)
        searchPanel.frame = .init(x: s.minX + 10, y: s.minY + 8, width: s.width - 20, height: 52)
        let w = searchPanel.bounds.width
        icon.frame = .init(x: 13, y: 17, width: 18, height: 18); field.frame = .init(x: 36, y: 4, width: max(50,w-152), height: 44)
        paste.frame = .init(x: w-113,y: 7,width: 52,height: 38); searchButton.frame = .init(x: w-55,y: 7,width: 48,height: 38)
        status.frame = .init(x: s.minX+13,y: searchPanel.frame.maxY+7,width: min(s.width-104,max(90,status.intrinsicContentSize.width+20)),height: 24)
        let d: CGFloat = s.height < 500 ? 42 : 46, h: CGFloat = s.height < 500 ? 54 : 68
        controls.frame = .init(x: s.maxX-76,y: s.maxY-42-h-4*d-24,width: 66,height: h+4*d+24)
        overview.frame = .init(x: 0,y: 0,width: 66,height: h)
        for (i,b) in [follow,direction,plan,more].enumerated() {
            b.frame = .init(x: (66-d)/2,y: h+6+CGFloat(i)*(d+6),width: d,height: d); b.layer.cornerRadius = d/2
        }
        let expanded = prefs.miniMode == .expanded
        let mw = expanded ? s.width-20 : s.width-92
        let mh: CGFloat = expanded ? min(max(220,view.bounds.height*0.58),min(560,s.height-80)) : 58
        miniPanel.frame = .init(x: s.minX+10,y: s.maxY-28-mh,width: mw,height: mh)
        mini.frame = .init(x: 0,y: 0,width: mw,height: max(0,mh-56))
        capsule.frame = .init(x: 0,y: mh-56,width: mw-(selected == nil ? 0 : 40),height: 56)
        info.frame = .init(x: mw-44,y: mh-50,width: 40,height: 40); closeMini.frame = .init(x: 8,y: 8,width: 34,height: 34)
        controls.isHidden = expanded; miniPanel.isHidden = prefs.miniMode == .hidden
        mini.isHidden = !expanded; closeMini.isHidden = !expanded; info.isHidden = selected == nil
        map.layoutMargins = .init(top: view.safeAreaInsets.top+70,left: view.safeAreaInsets.left+8,bottom: view.safeAreaInsets.bottom+8,right: view.safeAreaInsets.right+82)
        if lastMini != prefs.miniMode {
            if expanded { mini.beginEditing(map: map, rider: coordinate, heading: heading, dark: isDark) } else { mini.endEditing() }
            lastMini = prefs.miniMode
        }
        mini.resize()
    }
    private var isDark: Bool { traitCollection.userInterfaceStyle == .dark }
    private func applyPreferences() {
        overrideUserInterfaceStyle = prefs.appearance == .system ? .unspecified : (prefs.appearance == .dark ? .dark : .light)
        let camera = map.camera.copy() as! MKMapCamera
        let config = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: prefs.muted ? .muted : .default)
        config.pointOfInterestFilter = prefs.filter; config.showsTraffic = prefs.traffic
        map.preferredConfiguration = config; map.showsBuildings = prefs.buildings
        map.isZoomEnabled = prefs.zoomGestures; map.isRotateEnabled = prefs.rotateGestures; map.isPitchEnabled = prefs.pitchGestures
        if !prefs.showsPOI {
            featureToken = UUID(); featureRequest?.cancel(); featureRequest = nil
            for a in map.selectedAnnotations where a is MKMapFeatureAnnotation { map.deselectAnnotation(a, animated: false) }
        }
        map.setCamera(camera, animated: false); chrome(); updateCapsule()
        if prefs.stations && !stationOn { stationOn = true; stations.load() }
        else if !prefs.stations && stationOn { stationOn = false; stations.cancel(); map.removeAnnotations(stationPins); stationPins = [] }
        if let line {
            let has = map.overlays.contains { ($0 as AnyObject) === line }
            if prefs.routeVisible && !has { map.addOverlay(line, level: .aboveRoads) }
            if !prefs.routeVisible && has { map.removeOverlay(line) }
        }
        mini.setTheme(dark: isDark); view.setNeedsLayout()
    }
    private func chrome() {
        let bg = isDark ? UIColor(red: 0.065,green: 0.085,blue: 0.11,alpha: 0.94) : UIColor(white: 0.98,alpha: 0.95)
        for b in [paste,searchButton,overview,follow,direction,plan,more,closeMini] {
            b.backgroundColor = bg; b.tintColor = .label; b.setTitleColor(.label, for: .normal); b.layer.borderColor = UIColor.separator.cgColor
        }
        capsule.tintColor = .label; capsule.setTitleColor(.label, for: .normal)
        info.tintColor = .label; info.layer.borderWidth = 0
        follow.tintColor = following ? .systemCyan : .label; direction.tintColor = prefs.followHeading ? .systemCyan : .label
        plan.tintColor = route != nil ? .systemCyan : .label; searchPanel.refresh(); miniPanel.refresh()
    }
    override func traitCollectionDidChange(_ old: UITraitCollection?) { super.traitCollectionDidChange(old); if isViewLoaded { chrome(); mini.setTheme(dark: isDark) } }
    private func change(_ value: MapPreferences) {
        let old = prefs; prefs = value; prefs.sanitize(); prefs.save(); applyPreferences()
        if old.pitch != prefs.pitch || old.heading != prefs.heading || old.distance != prefs.distance {
            following = false; let c = map.camera.copy() as! MKMapCamera
            c.pitch = CGFloat(prefs.pitch); c.heading = prefs.heading; c.centerCoordinateDistance = prefs.distance
            map.setCamera(c, animated: false); chrome()
        }
    }
    private func updateCapsule() {
        capsule.setTitle(corrected ? "已修正 · "+titleText : titleText, for: .normal)
        capsule.setImage(UIImage(systemName: prefs.miniMode == .expanded ? "chevron.down" : "chevron.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20,weight: .bold)), for: .normal)
        capsule.accessibilityLabel = prefs.miniMode == .expanded ? "收合門牌小圖" : "展開門牌小圖"
        capsule.accessibilityValue = destination.map { String(format: "%.6f,%.6f",$0.latitude,$0.longitude) } ?? "未設定"
        mini.setCorrectionEnabled(destination != nil)
    }
    @objc private func toggleMini() { prefs.miniMode = prefs.miniMode == .expanded ? .collapsed : .expanded; prefs.save(); updateCapsule(); view.setNeedsLayout() }
    @objc private func hideMini() { prefs.miniMode = .hidden; prefs.save(); updateCapsule(); view.setNeedsLayout() }
    private func applyCorrection(_ point: CLLocationCoordinate2D) {
        guard prefs.miniMode == .expanded, destination != nil, CLLocationCoordinate2DIsValid(point), (20...27).contains(point.latitude), (117...123).contains(point.longitude) else { return }
        let hadRoute = route != nil || routeTask != nil, name = titleText
        choose(nil, point: point, title: name, move: false); corrected = true
        SavedDestination(latitude: point.latitude,longitude: point.longitude,title: "修正終點",manuallyCorrected: true).save()
        prefs.miniMode = .collapsed; prefs.save(); updateCapsule(); view.setNeedsLayout(); announce("終點定位已修正")
        if hadRoute { requestRoute(overview: false) }
    }
    @objc private func locate() { following = true; location.setContinuousLocationEnabled(true); location.requestOneShot(); followCamera(force: true); chrome(); announce("取得目前位置") }
    @objc private func toggleHeading() { prefs.followHeading.toggle(); prefs.save(); if following { followCamera(force: true) }; chrome(); announce(prefs.followHeading ? "跟隨時朝向前方" : "保留旋轉方向") }
    private func receivedLocation(_ fix: CLLocation) {
        guard active, fix.horizontalAccuracy >= 0, abs(fix.timestamp.timeIntervalSinceNow)<30 else { return }
        coordinate = fix; map.showsUserLocation = true; if fix.course>=0 && fix.speed>2 { heading = fix.course }; followCamera()
        if var cursor = progress, let route {
            if let remaining = cursor.update(fix.coordinate, accuracy: fix.horizontalAccuracy) {
                progress = cursor; drawRoute(cursor.remaining)
                summary(remaining, cursor.total>0 ? route.duration*remaining/cursor.total : 0)
                if remaining<20 { announce("接近終點，請核對門牌") }
            } else { announce("定位不準或偏離，請重新規劃") }
        } else { announce(fix.horizontalAccuracy<=60 ? "定位已就緒" : "定位精度較低") }
    }
    private func followCamera(force: Bool = false) {
        guard following, active, !gesture, let coordinate, force || Date().timeIntervalSince(lastFollow)>=0.5 else { return }
        lastFollow = Date(); let c = map.camera.copy() as! MKMapCamera; c.centerCoordinate = coordinate.coordinate
        c.pitch = CGFloat(prefs.pitch); c.heading = prefs.followHeading ? heading : prefs.heading
        if force { c.centerCoordinateDistance = prefs.distance }; map.setCamera(c, animated: true)
    }
    @objc private func selectCoordinate(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { choose(nil,point: map.convert(g.location(in: map),toCoordinateFrom: map),title: "地圖選點",persist: true,move: false) }
    }
    private func choose(_ item: MKMapItem?, point: CLLocationCoordinate2D, title: String, persist: Bool = false, move: Bool = true) {
        guard CLLocationCoordinate2DIsValid(point) else { return }
        searchToken = UUID(); search?.cancel(); search = nil; featureToken = UUID(); featureRequest?.cancel(); featureRequest = nil
        cancelRoute(); following = false; selected = item; destination = point; titleText = title; corrected = false
        if let pin { map.removeAnnotation(pin) }; let p = MKPointAnnotation(); p.coordinate = point; p.title = title; pin = p; map.addAnnotation(p)
        if persist { SavedDestination(latitude: point.latitude,longitude: point.longitude,title: title,manuallyCorrected: false).save() }
        else { UserDefaults.standard.removeObject(forKey: SavedDestination.key) }
        if move {
            let c = map.camera.copy() as! MKMapCamera; c.centerCoordinate = point; c.pitch = CGFloat(prefs.pitch); c.heading = prefs.heading
            c.centerCoordinateDistance = min(1200,max(350,prefs.distance)); map.setCamera(c, animated: true)
        }
        updateCapsule(); chrome(); view.setNeedsLayout(); announce("已選目的地")
    }
    private func clear() {
        cancelRoute(); selected = nil; destination = nil; corrected = false; titleText = "未設定"
        searchToken = UUID(); search?.cancel(); featureToken = UUID(); featureRequest?.cancel()
        if let pin { map.removeAnnotation(pin) }; pin = nil; UserDefaults.standard.removeObject(forKey: SavedDestination.key)
        updateCapsule(); view.setNeedsLayout(); announce("目的地已清除")
    }
    private func cancelRoute() {
        routeToken = UUID(); routeTask?.cancel(); routeTask = nil; route = nil; progress = nil
        if let line { map.removeOverlay(line) }; line = nil; overview.setTitle("全程\n-- km\n-- 分", for: .normal); plan.tintColor = .label
    }
    @objc private func planRoute() { requestRoute(overview: true) }
    private func requestRoute(overview: Bool) {
        guard let destination else { announce("先搜尋或長按選擇目的地"); return }
        guard let coordinate, coordinate.horizontalAccuracy>=0, coordinate.horizontalAccuracy<=60, abs(coordinate.timestamp.timeIntervalSinceNow)<30 else { announce("請先定位取得準確位置"); return }
        cancelRoute(); let token = routeToken; announce("規劃機車路線…")
        do {
            let request = try NativeRoute.request(from: coordinate.coordinate,to: destination)
            routeTask = URLSession.shared.dataTask(with: request) { [weak self] data,response,error in
                let result: Result<NativeRoute,Error> = Result {
                    if let error { throw error }; let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else { throw NativeRoute.RouteError.http(status) }
                    guard let data, data.count<=8_000_000 else { throw NativeRoute.RouteError.invalidResponse }
                    let r = try JSONDecoder().decode(NativeRoute.self,from: data); try r.validate(); return r
                }
                DispatchQueue.main.async {
                    self?.receiveRoute(result, token: token, overview: overview)
                }
            }; routeTask?.resume()
        } catch { announce("無法建立路由請求") }
    }
    private func receiveRoute(_ result: Result<NativeRoute,Error>, token: UUID, overview: Bool) {
        guard routeToken == token else { return }; routeTask = nil
        switch result {
        case .success(let r):
            route = r; progress = NativeRouteProgress(path: r.coordinates); drawRoute(r.coordinates)
            summary(r.distance,r.duration); plan.tintColor = .systemCyan; announce("機車路線已就緒")
            if overview { showRoute() }
        case .failure: announce("路線暫不可用，請稍後重試")
        }
    }
    private func drawRoute(_ points: [CLLocationCoordinate2D]) {
        guard points.count>=2 else { return }; if let line { map.removeOverlay(line) }
        let p = MKPolyline(coordinates: points,count: points.count); line = p; if prefs.routeVisible { map.addOverlay(p,level: .aboveRoads) }
    }
    private func summary(_ distance: Double,_ duration: Double) {
        let d = distance<1000 ? String(format: "%.0f m",distance) : String(format: "%.1f km",distance/1000)
        overview.setTitle("全程\n\(d)\n\(max(1,Int(ceil(duration/60)))) 分", for: .normal)
    }
    @objc private func showRoute() {
        following = false
        if let line {
            let s = view.safeAreaInsets, bottom = prefs.miniMode == .hidden ? view.safeAreaInsets.bottom+35 : view.safeAreaInsets.bottom+miniPanel.bounds.height+35
            map.setVisibleMapRect(line.boundingMapRect,edgePadding: .init(top: s.top+90,left: s.left+30,bottom: bottom,right: s.right+92),animated: false)
        } else if let destination { map.setRegion(.init(center: destination,latitudinalMeters: 650,longitudinalMeters: 650),animated: false) }
        else { announce("先設定目的地"); return }
        let c = map.camera.copy() as! MKMapCamera; c.pitch = CGFloat(prefs.pitch); c.heading = prefs.heading; map.setCamera(c,animated: false); chrome()
    }
    @objc private func showSettings() {
        view.endEditing(true); let settings = MapSettingsViewController(prefs); settings.stationStatus = stationMessage; settings.hasApplePlace = selected != nil
        settings.cameraStatus = { [weak self] in guard let self else { return "" }; return String(format: "實際傾角 %.0f° · 方向 %.0f°",self.map.camera.pitch,self.map.camera.heading) }
        settings.onChange = { [weak self] value in
            self?.change(value)
            self?.presentedViewController?.overrideUserInterfaceStyle = self?.overrideUserInterfaceStyle ?? .unspecified
        }
        settings.onAction = { [weak self] action in
            switch action {
            case "place-details": self?.showDetails()
            case "clear-destination": self?.clear()
            case "refresh-stations": self?.stations.load(force: true)
            case "open-production": UIApplication.shared.open(AppConfig.liveBaseURL)
            default: break
            }
        }
        let n = UINavigationController(rootViewController: settings); n.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        n.modalPresentationStyle = .pageSheet
        if let s = n.sheetPresentationController { s.detents = [.medium(),.large()]; s.prefersGrabberVisible = true; s.preferredCornerRadius = 20 }
        present(n,animated: true)
    }
    @objc private func showDetails() {
        guard let item = selected else { return }
        let text = [item.placemark.title,item.phoneNumber,item.url?.absoluteString,"Apple 商家位置不代表入口"].compactMap { $0 }.joined(separator: "\n")
        let alert = UIAlertController(title: item.name,message: text,preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "規劃到目的地",style: .default) { [weak self] _ in self?.planRoute() })
        if let url = item.url { alert.addAction(UIAlertAction(title: "網站",style: .default) { _ in UIApplication.shared.open(url) }) }
        alert.addAction(UIAlertAction(title: "關閉",style: .cancel)); present(alert,animated: true)
    }
    private func showStation(_ station: BatteryStation) {
        let alert = UIAlertController(title: station.name,message: [station.address ?? "",stationMessage].filter { !$0.isEmpty }.joined(separator: "\n\n"),preferredStyle: .alert)
        if station.unavailable != true {
            alert.addAction(UIAlertAction(title: "規劃到這站",style: .default) { [weak self] _ in self?.choose(nil,point: station.coordinate,title: station.name,persist: true); self?.planRoute() })
        }
        alert.addAction(UIAlertAction(title: "關閉",style: .cancel)); present(alert,animated: true)
    }
    @objc private func pasteDestination() { field.text = UIPasteboard.general.string; if Self.parseCoordinate(field.text ?? "") != nil { submitSearch() } }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { submitSearch(); return true }
    @objc private func submitSearch() {
        let text = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { field.becomeFirstResponder(); return }; view.endEditing(true)
        if let p = Self.parseCoordinate(text) { choose(nil,point: p,title: "輸入座標",persist: true); return }
        search?.cancel(); searchToken = UUID(); let token = searchToken
        let r = MKLocalSearch.Request(); r.naturalLanguageQuery = text; r.region = map.region; r.resultTypes = [.pointOfInterest,.address]; r.pointOfInterestFilter = prefs.filter
        let search = MKLocalSearch(request: r); self.search = search; announce("搜尋中…")
        search.start { [weak self] response,error in
            guard let self, self.searchToken == token else { return }; self.search = nil
            guard let items = response?.mapItems, !items.isEmpty else { self.announce("找不到結果，請調整關鍵字"); return }
            let results = NativePlaceResultsController(items: items) { [weak self] item in self?.choose(item,point: item.placemark.coordinate,title: item.name ?? "Apple 地點") }
            let n = UINavigationController(rootViewController: results); n.overrideUserInterfaceStyle = self.overrideUserInterfaceStyle
            n.sheetPresentationController?.detents = [.medium(),.large()]; self.present(n,animated: true)
        }
    }
    nonisolated static func parseCoordinate(_ text: String) -> CLLocationCoordinate2D? {
        let a = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard a.count == 2, let lat = Double(a[0]), let lng = Double(a[1]), lat.isFinite,lng.isFinite else { return nil }
        let p = CLLocationCoordinate2D(latitude: lat,longitude: lng); return CLLocationCoordinate2DIsValid(p) ? p : nil
    }
    func handleIncomingURL(_ url: URL) {
        guard let c = URLComponents(url: url,resolvingAgainstBaseURL: false), let text = c.queryItems?.first(where: { $0.name == "dest" })?.value, let p = Self.parseCoordinate(text) else { return }
        choose(nil,point: p,title: "傳入座標",persist: true)
    }
    private func announce(_ text: String) { status.text = "  "+text+"  "; view.setNeedsLayout() }
    func notifyLifecycle(_ state: String) {
        active = state == "foreground" || state == "willForeground"
        location.setAppActive(active)
        location.setContinuousLocationEnabled(active && following); mini.setActive(active && prefs.miniMode == .expanded)
        if !active { prefs.save(); stations.cancel() }
        else { location.setHeadingOrientation(deviceOrientation); if prefs.stations { stations.load() }; followCamera(force: true) }
    }
    private var deviceOrientation: CLDeviceOrientation {
        switch view.window?.windowScene?.interfaceOrientation { case .landscapeLeft: return .landscapeLeft; case .landscapeRight: return .landscapeRight; case .portraitUpsideDown: return .portraitUpsideDown; default: return .portrait }
    }
    override func viewWillTransition(to size: CGSize,with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size,with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in guard let self else { return }; self.location.setHeadingOrientation(self.deviceOrientation); self.view.setNeedsLayout() }
    }
    private func hasGesture(_ v: UIView) -> Bool { (v.gestureRecognizers ?? []).contains { $0.state == .began || $0.state == .changed } || v.subviews.contains { hasGesture($0) } }
    func mapView(_ m: MKMapView,regionWillChangeAnimated animated: Bool) { if hasGesture(m) { gesture = true; following = false; chrome() } }
    func mapViewDidChangeVisibleRegion(_ m: MKMapView) { if gesture && Date().timeIntervalSince(lastSave)>0.25 { saveCamera() } }
    func mapView(_ m: MKMapView,regionDidChangeAnimated animated: Bool) { if gesture { saveCamera(); if !hasGesture(m) { gesture = false } } }
    private func saveCamera() { prefs.pitch = Double(map.camera.pitch); prefs.heading = map.camera.heading; prefs.distance = map.camera.centerCoordinateDistance; prefs.sanitize(); prefs.save(); lastSave = Date() }
    func mapView(_ m: MKMapView,rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let p = overlay as? MKPolyline { let r = MKPolylineRenderer(polyline: p); r.strokeColor = .systemCyan; r.lineWidth = 6; return r }; return MKOverlayRenderer(overlay: overlay)
    }
    func mapView(_ m: MKMapView,viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if let a = annotation as? MKClusterAnnotation {
            let v = MKMarkerAnnotationView(annotation: a,reuseIdentifier: "station-cluster"); v.markerTintColor = .systemGreen; v.glyphText = "\(a.memberAnnotations.count)"; v.accessibilityLabel = "\(a.memberAnnotations.count) 個交換站"; return v
        }
        if let a = annotation as? BatteryStationAnnotation {
            let v = MKMarkerAnnotationView(annotation: a,reuseIdentifier: "battery-station")
            v.markerTintColor = a.station.unavailable == true ? .systemGray : .systemGreen; v.glyphImage = UIImage(systemName: "battery.100")
            v.clusteringIdentifier = "battery-stations"; v.titleVisibility = .adaptive; v.displayPriority = .defaultHigh
            v.accessibilityIdentifier = "battery-"+a.station.id; v.accessibilityLabel = a.station.name; v.isAccessibilityElement = true; return v
        }
        guard annotation is MKPointAnnotation else { return nil }
        let v = MKMarkerAnnotationView(annotation: annotation,reuseIdentifier: "destination")
        v.markerTintColor = .systemRed; v.canShowCallout = false; v.displayPriority = .required; v.accessibilityIdentifier = "destination-pin"; return v
    }
    func mapView(_ m: MKMapView,didSelect annotation: MKAnnotation) {
        if let a = annotation as? BatteryStationAnnotation { following = false; showStation(a.station); return }
        if let a = annotation as? MKClusterAnnotation {
            following = false; let c = map.camera.copy() as! MKMapCamera; c.centerCoordinate = a.coordinate; c.centerCoordinateDistance = max(150,c.centerCoordinateDistance/2); map.setCamera(c,animated: true); return
        }
        guard prefs.showsPOI, let a = annotation as? MKMapFeatureAnnotation else { return }
        following = false; featureRequest?.cancel(); featureToken = UUID(); let token = featureToken
        let r = MKMapItemRequest(mapFeatureAnnotation: a); featureRequest = r
        r.getMapItem { [weak self] item,error in
            guard let self, self.featureToken == token else { return }; self.featureRequest = nil
            guard let item else { self.announce("商家資訊暫不可用"); return }
            self.choose(item,point: item.placemark.coordinate,title: item.name ?? "Apple 地點",move: false)
        }
    }
    #if DEBUG
    // XCTest hooks exercise the real controller without a location or route network call.
    func testChoose(_ point: CLLocationCoordinate2D) { choose(nil,point: point,title: "test",move: false) }
    func testFix(_ fix: CLLocation) { receivedLocation(fix) }
    func testPreferences(_ value: MapPreferences) { change(value); view.layoutIfNeeded() }
    func testCorrect(_ point: CLLocationCoordinate2D) { applyCorrection(point) }
    func testOverview() { showRoute() }
    func testFollow() { following = true; followCamera(force: true) }
    func testSaveCamera(_ camera: MKMapCamera) { map.setCamera(camera,animated: false); saveCamera() }
    func testReceiveRoute(_ value: NativeRoute, token: UUID) { receiveRoute(.success(value),token: token,overview: false) }
    var testRouteToken: UUID { routeToken }
    var testRoute: NativeRoute? { route }
    var testGPS: CLLocationCoordinate2D? { coordinate?.coordinate }
    var testPin: CLLocationCoordinate2D? { pin?.coordinate }
    var testCamera: MKMapCamera { map.camera }
    var testSettings: MapPreferences { prefs }
    #endif
}
private final class GlassPanel: UIVisualEffectView {
    init() { super.init(effect: UIBlurEffect(style: .systemUltraThinMaterial)); layer.borderWidth = 1; clipsToBounds = true }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func refresh() { layer.borderColor = UIColor.separator.cgColor }
}
private final class NativePlaceResultsController: UITableViewController {
    private let items: [MKMapItem], choose: (MKMapItem)->Void
    init(items: [MKMapItem],choose: @escaping (MKMapItem)->Void) { self.items = items; self.choose = choose; super.init(style: .insetGrouped) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); title = "搜尋結果"; navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel,target: self,action: #selector(close)) }
    @objc private func close() { dismiss(animated: true) }
    override func tableView(_ t: UITableView,numberOfRowsInSection s: Int)->Int { items.count }
    override func tableView(_ t: UITableView,cellForRowAt i: IndexPath)->UITableViewCell {
        let item = items[i.row], c = UITableViewCell(style: .subtitle,reuseIdentifier: nil); c.textLabel?.text = item.name; c.detailTextLabel?.text = item.placemark.title; c.detailTextLabel?.numberOfLines = 2; return c
    }
    override func tableView(_ t: UITableView,didSelectRowAt i: IndexPath) { let item = items[i.row]; dismiss(animated: true) { [choose] in choose(item) } }
}
