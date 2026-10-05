import CoreLocation
import MapKit
import UIKit
import UniformTypeIdentifiers

/// Development-only native surface until the entire 26-family port is accepted.
/// No WebKit object, JS evaluator, localhost server or IndexedDB is created.
@MainActor final class NativePortViewController: UIViewController, UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate, MKMapViewDelegate, UIGestureRecognizerDelegate, UIDocumentPickerDelegate {
    private let map = MKMapView()
    private let searchPanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let searchStack = UIStackView(), queryField = UITextField()
    private let results = UITableView(frame: .zero, style: .plain)
    private let searchStatus = UILabel(), areaButton = UIButton(type: .system), moreButton = UIButton(type: .system)
    private let destinationLabel = UILabel(), phaseLabel = UILabel(), diagnostic = UILabel()
    private let navigationHUD = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let maneuverLabel = UILabel(), maneuverDistanceLabel = UILabel(), routeSummaryLabel = UILabel()
    private var navigationHUDTop: NSLayoutConstraint!
    private let morePanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let loadMore = UIButton(type: .system), clearQueryButton = UIButton(type: .system)
    private var resultsHeight: NSLayoutConstraint!
    private var resources: NativePublicResources?
    private var repository: NativeSearchRepository?
    private var search: NativeSearchCoordinator?
    private var navigationState = DoorNavigationState()
    private var mapResultsMode = false, active = true
    private lazy var searchMap = NativeSearchMapPresenter(map: map)
    private var destinationPin: MKPointAnnotation?
    private var lastMapSize = CGSize.zero
    private var publicCounts: (local: Int, community: Int)?
    private var initialURL: URL?
    private let testMode: Bool
    private var inputObservation: NSObjectProtocol?
    private var mapSelectionRequest: MKMapItemRequest?
    private let googleResolver = NativeGoogleResolver()
    private let destinationSync = NativeDestinationSync()
    private var handoffTask: Task<Void, Never>?
    private var handoffGeneration: UInt64 = 0
    private lazy var ridingCamera = NativeRidingCamera(map: map)
    private lazy var nativeSensors = NativeSensors(simulated: testMode)
    private var fitControl: UIButton?, followControl: UIButton?, headingControl: UIButton?, routeControl: UIButton?
    private var cameraControls: [UIButton] = []
    private let routePlanner = NativeRoutePlanner()
    private var routeTask: Task<Void, Never>?
    private var routeGeneration: UInt64 = 0
    private var routePlanning = false
    private var reroutePolicy = DoorReroutePolicy()
    private var autoRerouteCount = 0
    private var lastRerouteReason = ""
    private var plannedRoutes: [DoorPlannedRoute] = []
    private var selectedRouteIndex = 0
    private var viaPoints: [DoorCoordinate] = []
    private var avoidAreas: [DoorAvoidArea] = []
    private var routeEditor = DoorRouteEditor()
    private var routeEditorTask: Task<Void, Never>?
    private var routePreviewLine: MKPolyline?
    private var routeViaAnnotations: [NativeViaAnnotation] = []
    private var avoidOverlays: [MKCircle] = []
    private var avoidOverlayStatus: [ObjectIdentifier: String] = [:]
    private var avoidBoundaryTimer: Timer?
    private var nativePreferences = MapPreferences()
    private var personalStore: NativePersonalStore?
    private var routeMemories: [DoorRouteMemory] = []
    private let stationStore = BatteryStationStore()
    private var stationAnnotations: [BatteryStationAnnotation] = []
    private var stationStatus = ""
    private let powerDiagnostic = NativePowerDiagnostic()
    private var powerCameraApplications = 0, powerFitEvaluations = 0, powerLayerRefreshes = 0
    private var publicLayers: NativePublicLayerPresenter?
    private let centerPickerReticle = UILabel(), centerPickerPanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let centerPickerLabel = UILabel(), centerPickerNavigate = UIButton(type: .system), centerPickerCopy = UIButton(type: .system)
    private var centerPickerEnabled = false
    private var destinationMini: NativeDestinationMini?
    private var destinationMiniHeight: NSLayoutConstraint!

    init(initialURL: URL?, testMode: Bool = false) {
        self.initialURL = initialURL; self.testMode = testMode
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); applyNativeAppearance(); view.backgroundColor = .black
        view.accessibilityIdentifier = "native-port-root"
        configureMap(); configureSearch(); configureControls(); configureNavigationHUD(); configureDestinationMini(); configureCenterPicker(); configureMore(); configureNativeSensors(); configureStations(); configurePowerDiagnostic(); configureDestinationSync()
        do {
            let store = try NativePersonalStore.makeForTestApp(); personalStore = store
            Task { [weak self] in
                do { let snapshot = try await store.load(defaultPreferences: MapPreferences.load()); self?.applyPersonalSnapshot(snapshot) }
                catch { self?.phaseLabel.text = "個人資料驗證失敗；未覆蓋原資料：\(error.localizedDescription)" }
            }
        } catch { phaseLabel.text = "個人資料儲存區無法開啟：\(error.localizedDescription)" }
        do {
            let resources = try NativePublicResources.makeForTestApp()
            self.resources = resources
            let repository = NativeSearchRepository(resources: resources); self.repository = repository
            let layers = NativePublicLayerPresenter(map: map, resources: resources); self.publicLayers = layers
            layers.onChange = { [weak self] in
                guard let self else { return }
                let refreshes = layers.stats.refreshes
                if refreshes > self.powerLayerRefreshes { self.powerDiagnostic.mark(.layerRefresh, Int64(refreshes - self.powerLayerRefreshes)); self.powerLayerRefreshes = refreshes }
                self.updateDiagnostic()
            }
            let search = NativeSearchCoordinator(repository: repository, appleEnabled: !testMode); self.search = search
            search.onChange = { [weak self] in self?.powerDiagnostic.mark(.searchRefresh); self?.renderSearch() }
            Task { [weak self] in
                do {
                    let counts = try await repository.counts()
                    guard let self else { return }; self.publicCounts = counts; self.refreshPublicLayers(); self.updateDiagnostic()
                    if let url = self.initialURL { self.initialURL = nil; self.handleIncomingURL(url) }
                } catch { self?.phaseLabel.text = "原生資料未就緒：\(error.localizedDescription)"; self?.updateDiagnostic() }
            }
        } catch { phaseLabel.text = "原生資料初始化失敗：\(error.localizedDescription)" }
        inputObservation = NotificationCenter.default.addObserver(forName: UITextField.textDidChangeNotification, object: queryField, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.queryChanged() }
        }
        updateDiagnostic()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if lastMapSize != map.bounds.size { lastMapSize=map.bounds.size; searchMap.refresh(); refreshPublicLayers() }
        updateTableHeight(); updateNativeCameraLayout(); updateDiagnostic()
    }
    private func configureMap() {
        map.translatesAutoresizingMaskIntoConstraints = false; map.delegate = self
        map.accessibilityIdentifier = "native-port-apple-map"
        map.showsUserLocation = false; map.showsCompass = false
        map.selectableMapFeatures = testMode ? [] : [.pointsOfInterest]
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        view.addSubview(map)
        NSLayoutConstraint.activate([map.leadingAnchor.constraint(equalTo: view.leadingAnchor), map.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            map.topAnchor.constraint(equalTo: view.topAnchor), map.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        let center = testMode ? CLLocationCoordinate2D(latitude: 24.135, longitude: 120.688) : CLLocationCoordinate2D(latitude: 24.1477, longitude: 120.6736)
        map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: 1600, longitudinalMeters: 1600), animated: false)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(userPanned(_:)))
        pan.cancelsTouchesInView = false; pan.delegate = self; map.addGestureRecognizer(pan)
        let editHold = UILongPressGestureRecognizer(target: self, action: #selector(routeEditLongPress(_:)))
        editHold.minimumPressDuration = 0.45; editHold.cancelsTouchesInView = false; editHold.delegate = self; map.addGestureRecognizer(editHold)
    }
    private func configureSearch() {
        searchPanel.translatesAutoresizingMaskIntoConstraints = false; searchPanel.layer.cornerRadius = 18; searchPanel.clipsToBounds = true
        searchPanel.layer.borderWidth = 1; searchPanel.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        view.addSubview(searchPanel)
        NSLayoutConstraint.activate([searchPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            searchPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            searchPanel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10)])
        searchStack.axis = .vertical; searchStack.spacing = 4; searchStack.translatesAutoresizingMaskIntoConstraints = false
        searchPanel.contentView.addSubview(searchStack)
        NSLayoutConstraint.activate([searchStack.leadingAnchor.constraint(equalTo: searchPanel.contentView.leadingAnchor, constant: 8),
            searchStack.trailingAnchor.constraint(equalTo: searchPanel.contentView.trailingAnchor, constant: -8),
            searchStack.topAnchor.constraint(equalTo: searchPanel.contentView.topAnchor, constant: 4),
            searchStack.bottomAnchor.constraint(equalTo: searchPanel.contentView.bottomAnchor, constant: -4)])
        let icon = UIImageView(image: UIImage(systemName: "magnifyingglass")); icon.tintColor = .white; icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        queryField.placeholder = "搜尋地址、店家、地標或座標"; queryField.font = .systemFont(ofSize: 14)
        queryField.textColor = .white; queryField.autocorrectionType = .no; queryField.autocapitalizationType = .none
        queryField.returnKeyType = .search; queryField.clearButtonMode = .never; queryField.delegate = self
        queryField.accessibilityIdentifier = "native-planner-query"
        queryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        queryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        let paste = smallButton("貼上", id: "native-planner-paste", action: #selector(pasteQuery))
        let go = smallButton("搜尋", id: "native-planner-go", action: #selector(submitSearch))
        clearQueryButton.setTitle("×", for: .normal); clearQueryButton.tintColor = .secondaryLabel
        clearQueryButton.accessibilityIdentifier = "native-planner-clear"; clearQueryButton.accessibilityLabel = "清除搜尋"
        clearQueryButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        clearQueryButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        clearQueryButton.addTarget(self, action: #selector(clearQuery), for: .touchUpInside); clearQueryButton.isHidden = true
        let row = UIStackView(arrangedSubviews: [icon, queryField, clearQueryButton, paste, go]); row.axis = .horizontal; row.spacing = 5; row.alignment = .center
        row.heightAnchor.constraint(equalToConstant: 46).isActive = true
        searchStack.addArrangedSubview(row)
        areaButton.setTitle("搜尋這個區域", for: .normal); areaButton.accessibilityIdentifier = "native-search-area"
        areaButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold); areaButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        areaButton.addTarget(self, action: #selector(researchArea), for: .touchUpInside); areaButton.isHidden = true
        searchStack.addArrangedSubview(areaButton)
        results.backgroundColor = .clear; results.separatorColor = UIColor.white.withAlphaComponent(0.14)
        results.dataSource = self; results.delegate = self; results.keyboardDismissMode = .interactive
        results.rowHeight = UITableView.automaticDimension; results.estimatedRowHeight = 66
        results.accessibilityIdentifier = "native-search-results"; results.isHidden = true
        resultsHeight = results.heightAnchor.constraint(equalToConstant: 0); resultsHeight.isActive = true
        searchStack.addArrangedSubview(results)
        loadMore.setTitle("顯示更多", for: .normal); loadMore.accessibilityIdentifier = "native-search-load-more"
        loadMore.addTarget(self, action: #selector(loadNextPage), for: .touchUpInside); loadMore.frame = CGRect(x: 0, y: 0, width: 240, height: 44)
        searchStatus.font = .systemFont(ofSize: 12); searchStatus.textColor = .secondaryLabel; searchStatus.numberOfLines = 0
        searchStatus.accessibilityIdentifier = "native-search-status"; searchStatus.isHidden = true
        searchStack.addArrangedSubview(searchStatus)
    }
    private func smallButton(_ title: String, id: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system); b.setTitle(title, for: .normal); b.tintColor = .white
        b.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold); b.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        b.layer.cornerRadius = 11; b.layer.borderWidth = 1; b.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        b.widthAnchor.constraint(equalToConstant: 48).isActive = true; b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        b.accessibilityIdentifier = id; b.addTarget(self, action: action, for: .touchUpInside); return b
    }
    private func configureControls() {
        let stack = UIStackView(); stack.axis = .vertical; stack.alignment = .center; stack.spacing = 6; stack.translatesAutoresizingMaskIntoConstraints = false
        let fit = control("FIT\n-- km\n-- 分", id: "native-fit")
        fit.titleLabel?.numberOfLines = 3; fit.titleLabel?.textAlignment = .center; fit.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
        fit.widthAnchor.constraint(equalToConstant: 66).isActive = true; fit.heightAnchor.constraint(equalToConstant: 69).isActive = true; fit.layer.cornerRadius = 18
        let follow = control("⌖", id: "native-follow"), heading = control("↑", id: "native-heading"), route = control("↗", id: "native-route")
        route.isEnabled = false; route.alpha = 0.55; route.accessibilityHint = "機車路線與備選"
        fitControl = fit; followControl = follow; headingControl = heading; routeControl = route
        fit.addTarget(self, action: #selector(toggleNativeFit), for: .touchUpInside)
        follow.addTarget(self, action: #selector(nativeFollow), for: .touchUpInside)
        heading.addTarget(self, action: #selector(nativeHeading), for: .touchUpInside)
        route.addTarget(self, action: #selector(showNativeRoutes), for: .touchUpInside)
        cameraControls = [fit, follow, heading, route, moreButton]
        for b in [follow, heading, route] { b.widthAnchor.constraint(equalToConstant: 46).isActive = true; b.heightAnchor.constraint(equalToConstant: 46).isActive = true }
        moreButton.setTitle("⋯", for: .normal); moreButton.tintColor = .white; moreButton.backgroundColor = UIColor(white: 0.08, alpha: 0.94)
        moreButton.layer.cornerRadius = 23; moreButton.titleLabel?.font = .boldSystemFont(ofSize: 28); moreButton.accessibilityIdentifier = "native-more"
        moreButton.widthAnchor.constraint(equalToConstant: 46).isActive = true; moreButton.heightAnchor.constraint(equalToConstant: 46).isActive = true
        moreButton.addTarget(self, action: #selector(toggleMore), for: .touchUpInside)
        [fit, follow, heading, route, moreButton].forEach(stack.addArrangedSubview)
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -42)])
        destinationLabel.text = "未設定目的地"; destinationLabel.numberOfLines = 2
        destinationLabel.font = .systemFont(ofSize: 16, weight: .bold); destinationLabel.textColor = .white
        destinationLabel.backgroundColor = UIColor(white: 0.07, alpha: 0.95); destinationLabel.layer.cornerRadius = 14; destinationLabel.clipsToBounds = true
        destinationLabel.accessibilityIdentifier = "native-destination-title"; destinationLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(destinationLabel)
        NSLayoutConstraint.activate([destinationLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            destinationLabel.trailingAnchor.constraint(lessThanOrEqualTo: stack.leadingAnchor, constant: -10),
            destinationLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -42),
            destinationLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 240), destinationLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 38)])
        phaseLabel.text = "581 全原生測試 · 搜尋／離線／導航／FIT／NLSC／公共圖層已接線 · iOS 最終驗證待完成"; phaseLabel.textColor = .white
        phaseLabel.font = .systemFont(ofSize: 10); phaseLabel.numberOfLines = 2; phaseLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(phaseLabel)
        NSLayoutConstraint.activate([phaseLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            phaseLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            phaseLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6)])
        destinationLabel.isHidden = true
        if testMode { diagnostic.isAccessibilityElement = true; diagnostic.accessibilityIdentifier = "native-s2-state"; diagnostic.frame = CGRect(x: 1, y: 1, width: 1, height: 1); diagnostic.textColor = .clear; view.addSubview(diagnostic) }
    }
    private func configureNavigationHUD() {
        navigationHUD.translatesAutoresizingMaskIntoConstraints = false; navigationHUD.layer.cornerRadius = 18; navigationHUD.clipsToBounds = true
        navigationHUD.layer.borderWidth = 1; navigationHUD.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        navigationHUD.accessibilityIdentifier = "native-navigation-hud"; navigationHUD.isHidden = true
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 2; stack.translatesAutoresizingMaskIntoConstraints = false
        maneuverDistanceLabel.font = .systemFont(ofSize: 22, weight: .heavy); maneuverDistanceLabel.textColor = .white
        maneuverDistanceLabel.accessibilityIdentifier = "native-maneuver-distance"
        maneuverLabel.font = .systemFont(ofSize: 17, weight: .bold); maneuverLabel.textColor = .white; maneuverLabel.numberOfLines = 2
        maneuverLabel.accessibilityIdentifier = "native-maneuver-name"
        routeSummaryLabel.font = .systemFont(ofSize: 12, weight: .semibold); routeSummaryLabel.textColor = .secondaryLabel
        routeSummaryLabel.accessibilityIdentifier = "native-route-summary"
        [maneuverDistanceLabel, maneuverLabel, routeSummaryLabel].forEach(stack.addArrangedSubview)
        navigationHUD.contentView.addSubview(stack); view.addSubview(navigationHUD)
        NSLayoutConstraint.activate([
            navigationHUD.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            navigationHUD.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -82),
            navigationHUD.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            stack.leadingAnchor.constraint(equalTo: navigationHUD.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: navigationHUD.contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: navigationHUD.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: navigationHUD.contentView.bottomAnchor, constant: -10)
        ])
        navigationHUDTop = navigationHUD.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10)
        navigationHUDTop.isActive = true
    }
    private func configureDestinationMini() {
        let mini = NativeDestinationMini(simulated: testMode); destinationMini = mini
        mini.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(mini)
        destinationMiniHeight = mini.heightAnchor.constraint(equalToConstant: 56)
        NSLayoutConstraint.activate([mini.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            mini.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -78),
            mini.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -42), destinationMiniHeight])
        mini.onExpansion = { [weak self, weak mini] expanded in
            guard let self, let mini else { return }
            if expanded && self.centerPickerEnabled { self.setCenterPicker(false) }
            self.destinationMiniHeight.constant = expanded ? min(370, max(260, self.view.bounds.height * 0.48)) : 56
            self.view.bringSubviewToFront(mini); self.view.layoutIfNeeded(); self.updateCameraSuspension(); self.updateNativeCameraLayout(); self.updateDiagnostic()
        }
        mini.onCorrectionMode = { [weak self] _ in self?.updateCameraSuspension(); self?.updateDiagnostic() }
        mini.onApply = { [weak self] point, revision in
            guard let self, self.navigationState.destinationRevision == revision else { return false }
            self.navigationState.beginCorrection(); self.navigationState.moveCorrection(point)
            guard self.navigationState.applyCorrection(expectedRevision: revision) else { return false }
            self.syncDestinationUI(centerMap: false)
            return true
        }
        mini.onChange = { [weak self] in self?.updateDiagnostic() }
        mini.setTarget(navigationState.destination, revision: navigationState.destinationRevision, viewportCenter: currentCenter)
    }
    private func configureCenterPicker() {
        centerPickerReticle.text = "+"; centerPickerReticle.font = .systemFont(ofSize: 44, weight: .light)
        centerPickerReticle.textColor = .systemRed; centerPickerReticle.textAlignment = .center
        centerPickerReticle.isUserInteractionEnabled = false; centerPickerReticle.accessibilityIdentifier = "native-center-reticle"
        centerPickerReticle.translatesAutoresizingMaskIntoConstraints = false; centerPickerReticle.isHidden = true
        view.addSubview(centerPickerReticle)

        centerPickerPanel.layer.cornerRadius = 14; centerPickerPanel.clipsToBounds = true
        centerPickerPanel.translatesAutoresizingMaskIntoConstraints = false; centerPickerPanel.isHidden = true
        centerPickerPanel.accessibilityIdentifier = "native-center-panel"
        centerPickerLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        centerPickerLabel.textColor = .white; centerPickerLabel.numberOfLines = 2
        centerPickerLabel.accessibilityIdentifier = "native-center-coordinate"
        centerPickerCopy.setTitle("複製座標", for: .normal); centerPickerCopy.accessibilityIdentifier = "native-center-copy"
        centerPickerNavigate.setTitle("導航這裡", for: .normal); centerPickerNavigate.accessibilityIdentifier = "native-center-navigate"
        centerPickerCopy.addTarget(self, action: #selector(copyCenterCoordinate), for: .touchUpInside)
        centerPickerNavigate.addTarget(self, action: #selector(navigateMapCenter), for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [centerPickerCopy, centerPickerNavigate]); actions.axis = .horizontal
        actions.distribution = .fillEqually; actions.spacing = 8
        let stack = UIStackView(arrangedSubviews: [centerPickerLabel, actions]); stack.axis = .vertical; stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false; centerPickerPanel.contentView.addSubview(stack); view.addSubview(centerPickerPanel)
        NSLayoutConstraint.activate([
            centerPickerReticle.centerXAnchor.constraint(equalTo: map.centerXAnchor),
            centerPickerReticle.centerYAnchor.constraint(equalTo: map.centerYAnchor),
            centerPickerReticle.widthAnchor.constraint(equalToConstant: 54), centerPickerReticle.heightAnchor.constraint(equalToConstant: 54),
            centerPickerPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            centerPickerPanel.bottomAnchor.constraint(equalTo: destinationMini!.topAnchor, constant: -8),
            centerPickerPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 250),
            stack.leadingAnchor.constraint(equalTo: centerPickerPanel.contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: centerPickerPanel.contentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: centerPickerPanel.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: centerPickerPanel.contentView.bottomAnchor, constant: -10)
        ])
    }

    private func setCenterPicker(_ value: Bool) {
        guard centerPickerEnabled != value else { if value { updateCenterPickerLabel() }; return }
        centerPickerEnabled = value
        if value {
            destinationMini?.setExpanded(false)
            queryField.resignFirstResponder(); morePanel.isHidden = true
            ridingCamera.setMode(.free)
        }
        centerPickerReticle.isHidden = !value; centerPickerPanel.isHidden = !value
        if value { updateCenterPickerLabel(); view.bringSubviewToFront(centerPickerReticle); view.bringSubviewToFront(centerPickerPanel) }
        updateCameraSuspension(); updateDiagnostic()
    }

    @objc private func toggleCenterPicker() { setCenterPicker(!centerPickerEnabled) }

    private func updateCenterPickerLabel() {
        guard centerPickerEnabled else { return }
        let p = currentCenter
        centerPickerLabel.text = String(format: "地圖中心\n%.7f, %.7f", locale: Locale(identifier: "en_US_POSIX"), p.lat, p.lng)
    }

    @objc private func copyCenterCoordinate() {
        guard centerPickerEnabled else { return }
        let p = currentCenter
        UIPasteboard.general.string = String(format: "%.7f, %.7f", locale: Locale(identifier: "en_US_POSIX"), p.lat, p.lng)
        phaseLabel.text = "地圖中心座標已複製"
    }

    @objc private func navigateMapCenter() {
        guard centerPickerEnabled else { return }
        let p = currentCenter
        guard (20...27).contains(p.lat), (117...123).contains(p.lng) else { phaseLabel.text = "地圖中心不在台灣範圍"; return }
        setCenterPicker(false)
        select(.init(displayName: "地圖中心", lat: p.lat, lng: p.lng, source: "manual-map-center"))
        phaseLabel.text = "已將地圖中心設為新目的地"
    }

    private func control(_ title: String, id: String) -> UIButton {
        let b = UIButton(type: .system); b.setTitle(title, for: .normal); b.accessibilityIdentifier = id
        b.tintColor = .white; b.backgroundColor = UIColor(white: 0.08, alpha: 0.94); b.layer.cornerRadius = 23
        b.layer.borderWidth = 1; b.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        b.titleLabel?.font = .systemFont(ofSize: 22, weight: .bold); return b
    }
    private func configureMore() {
        morePanel.layer.cornerRadius = 18; morePanel.clipsToBounds = true; morePanel.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
        let title = UILabel(); title.text = "更多功能"; title.font = .boldSystemFont(ofSize: 16); title.textColor = .white
        stack.addArrangedSubview(title)
        for item in [("搜尋地址", "native-more-search", #selector(openSearch)),
                     ("路線／途經／避讓", "native-more-route-tools", #selector(showRouteTools)),
                     ("離線資料", "native-more-offline", #selector(openOffline)),
                     ("PiP 避讓", "native-more-pip", #selector(toggleNativePiP)),
                     ("地圖設定", "native-more-settings", #selector(showMapSettings)),
                     ("地圖中心選點", "native-more-center-picker", #selector(toggleCenterPicker)),
                     ("5 分鐘運算／耗電診斷", "native-more-power", #selector(showPowerDiagnostic)),
                     ("個人備份", "native-more-backup", #selector(showBackupTools)),
                     ("移植進度／資料來源", "native-more-progress", #selector(showPortStatus))] {
            let b = UIButton(type: .system); b.setTitle(item.0, for: .normal); b.accessibilityIdentifier = item.1
            b.contentHorizontalAlignment = .left; b.tintColor = .white; b.titleLabel?.font = .systemFont(ofSize: 15)
            b.heightAnchor.constraint(equalToConstant: 44).isActive = true; b.addTarget(self, action: item.2, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
        morePanel.contentView.addSubview(stack); view.addSubview(morePanel)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: morePanel.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: morePanel.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: morePanel.contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: morePanel.contentView.bottomAnchor, constant: -14),
            morePanel.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -10),
            morePanel.bottomAnchor.constraint(equalTo: moreButton.bottomAnchor), morePanel.widthAnchor.constraint(equalToConstant: 220)])
        morePanel.isHidden = true
    }
    private func configureNativeSensors() {
        ridingCamera.onChange = { [weak self] in
            guard let self else { return }
            let diag = self.ridingCamera.diagnostics()
            let cameras = diag["cameraApplications"] as? Int ?? self.powerCameraApplications
            let fits = diag["fitEvaluations"] as? Int ?? self.powerFitEvaluations
            if cameras > self.powerCameraApplications { self.powerDiagnostic.mark(.cameraApply, Int64(cameras - self.powerCameraApplications)); self.powerCameraApplications = cameras }
            if fits > self.powerFitEvaluations { self.powerDiagnostic.mark(.fitEvaluate, Int64(fits - self.powerFitEvaluations)); self.powerFitEvaluations = fits }
            self.updateNativeCameraControls(); self.updateDiagnostic()
        }
        ridingCamera.onMessage = { [weak self] text in self?.phaseLabel.text = text }
        nativeSensors.onStatus = { [weak self] text in self?.phaseLabel.text = "原生 S3 測試 · " + text }
        nativeSensors.onFix = { [weak self] fix in
            guard let self else { return }
            if !fix.warm { self.powerDiagnostic.mark(.gps) }
            if !fix.warm { self.navigationState.acceptRawPosition(fix.coordinate) }
            self.ridingCamera.accept(fix); self.refreshPublicLayers(); self.maybeAutoReroute(fix)
        }
        nativeSensors.onHeading = { [weak self] sample in self?.powerDiagnostic.mark(.heading); self?.ridingCamera.acceptHeading(sample) }
        updateNativeCameraControls()
        #if DEBUG
        if testMode && ProcessInfo.processInfo.environment["DOOR_NATIVE_CAMERA_FIXTURE"] == "1" {
            let fix = CLLocation(coordinate: .init(latitude: 24.135, longitude: 120.688), altitude: 0,
                horizontalAccuracy: 5, verticalAccuracy: 5, course: 45, courseAccuracy: 5, speed: 6, speedAccuracy: 1, timestamp: Date())
            nativeSensors.acceptLocations([fix])
            nativeSensors.acceptHeading(trueHeading: 45, magnetic: 44, accuracy: 5, timestamp: Date())
            let end = DoorCoordinate(lat: 24.143, lng: 120.693)
            select(.init(displayName: "模擬路線終點", lat: end.lat, lng: end.lng, source: "explicit-ui-fixture"))
            let mainPath: [DoorCoordinate] = [.init(lat: 24.135, lng: 120.688), .init(lat: 24.137, lng: 120.689), .init(lat: 24.137, lng: 120.693), end]
            let altPath: [DoorCoordinate] = [.init(lat: 24.135, lng: 120.688), .init(lat: 24.136, lng: 120.691), .init(lat: 24.140, lng: 120.692), end]
            let main = DoorPlannedRoute(coordinates: mainPath, distance: 1320, duration: 330,
                maneuvers: [.init(type: "turn", modifier: "right", name: "測試路", distance: 80, location: mainPath[1], routeIndex: 1)], label: "推薦")
            let alt = DoorPlannedRoute(coordinates: altPath, distance: 1410, duration: 350,
                maneuvers: [.init(type: "turn", modifier: "left", name: "備選路", distance: 100, location: altPath[1], routeIndex: 1)], label: "備選 2")
            plannedRoutes = [main, alt]; selectedRouteIndex = 0
            ridingCamera.setRoute(main.coordinates, destination: end, maneuvers: NativeRoutePlanner.ridingManeuvers(main))
            navigationState.setMode(.navigating); ridingCamera.setMode(.navigation)
            updateNativeCameraControls(); updateNativeCameraLayout(); updateDiagnostic()
        }
        #endif
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); updateNativeOrientation(); nativeSensors.start(); updateCameraSuspension(); updateNativeCameraLayout()
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.updateNativeOrientation(); self?.updateNativeCameraLayout() }
    }
    private func updateNativeOrientation() {
        guard let orientation = view.window?.windowScene?.interfaceOrientation else { return }
        let value: CLDeviceOrientation
        switch orientation { case .landscapeLeft: value = .landscapeLeft; case .landscapeRight: value = .landscapeRight
        case .portraitUpsideDown: value = .portraitUpsideDown; default: value = .portrait }
        nativeSensors.setOrientation(value)
    }
    private func updateNativeCameraControls() {
        fitControl?.isEnabled = ridingCamera.canFit
        fitControl?.alpha = ridingCamera.canFit ? 1 : 0.55
        fitControl?.isSelected = ridingCamera.mode == .fit
        routeControl?.isSelected = ridingCamera.mode == .navigation
        fitControl?.accessibilityValue = ridingCamera.mode.rawValue
        if let meters = ridingCamera.remainingMeters {
            fitControl?.setTitle(String(format: "%@\n%.2f km\n-- 分", ridingCamera.mode == .fit ? "FIT 已鎖" : "FIT", meters / 1000), for: .normal)
        }
        followControl?.isSelected = ridingCamera.mode == .north || ridingCamera.mode == .heading
        headingControl?.isSelected = ridingCamera.mode == .heading
        let canPlan = navigationState.rawPosition != nil && navigationState.destination != nil
        routeControl?.isEnabled = routePlanning || canPlan || !plannedRoutes.isEmpty
        routeControl?.alpha = routeControl?.isEnabled == true ? 1 : 0.55
        if routePlanning { routeControl?.setTitle("…", for: .normal) }
        else if plannedRoutes.count > 1 { routeControl?.setTitle("↗\(plannedRoutes.count)", for: .normal) }
        else { routeControl?.setTitle("↗", for: .normal) }
        let hide = (ridingCamera.mode == .fit || ridingCamera.mode == .navigation) && !navigationState.searchRequested
        if searchPanel.isHidden != hide { searchPanel.isHidden = hide; view.setNeedsLayout() }
        updateNavigationHUD()
    }
    private func updateNavigationHUD() {
        let navigating = ridingCamera.mode == .navigation
        navigationHUD.isHidden = !navigating
        guard navigating else { return }
        let maneuver = ridingCamera.nextManeuver
        let meters = ridingCamera.nextManeuverMeters
        if let meters {
            maneuverDistanceLabel.text = meters <= 12 ? "現在" : (meters < 1000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters / 1000))
        } else { maneuverDistanceLabel.text = "前進" }
        let modifier = maneuver?.modifier.lowercased() ?? ""
        let arrow = modifier.contains("right") ? "↱" : modifier.contains("left") ? "↰" : modifier.contains("uturn") ? "↶" : "↑"
        let name = maneuver?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        maneuverLabel.text = name.isEmpty ? "\(arrow) 沿目前路線" : "\(arrow) \(name)"
        let remaining = ridingCamera.remainingMeters ?? 0
        var minutes: Double?
        if plannedRoutes.indices.contains(selectedRouteIndex) {
            let route = plannedRoutes[selectedRouteIndex]
            if route.distance > 0 { minutes = route.duration * max(0, min(1, remaining / route.distance)) / 60 }
        }
        routeSummaryLabel.text = String(format: "%.1f km%@ · 3D 導航", remaining / 1000,
                                        minutes.map { String(format: " · %.0f 分", $0) } ?? "")
        navigationHUD.accessibilityValue = "\(maneuverDistanceLabel.text ?? "")|\(maneuverLabel.text ?? "")|\(routeSummaryLabel.text ?? "")"
    }
    private func updateNativeCameraLayout() {
        guard isViewLoaded else { return }
        var views: [UIView] = cameraControls.map { $0 as UIView }
        if let mini = destinationMini, !mini.expanded { views.append(mini) }
        ridingCamera.controlRects = views.filter { !$0.isHidden && $0.bounds.width > 0 }.map {
            let r = $0.convert($0.bounds, to: map).insetBy(dx: -4, dy: -4)
            return .init(left: Double(r.minX), top: Double(r.minY), right: Double(r.maxX), bottom: Double(r.maxY))
        }
        ridingCamera.hudHeight = max(50, Double(navigationHUD.bounds.height))
        ridingCamera.collapsedInsetHeight = 56
        if ridingCamera.mode == .navigation, ridingCamera.pip {
            let bottom = DoorCameraViewport.pipBottom(width: Double(view.bounds.width), height: Double(view.bounds.height))
            navigationHUDTop.constant = max(10, bottom - Double(view.safeAreaInsets.top) + 8)
        } else { navigationHUDTop.constant = 10 }
        ridingCamera.updateLayout()
    }
    private func updateCameraSuspension() {
        ridingCamera.setSuspended(centerPickerEnabled || !morePanel.isHidden || queryField.isFirstResponder || presentedViewController != nil || destinationMini?.expanded == true || routeEditor.active)
    }
    @objc private func toggleNativeFit() { queryField.resignFirstResponder(); navigationState.dismissSearch(); morePanel.isHidden = true; updateCameraSuspension(); ridingCamera.toggleFit() }
    @objc private func nativeFollow() { nativeSensors.start(); ridingCamera.setMode(ridingCamera.mode == .free ? .north : .free) }
    @objc private func nativeHeading() { nativeSensors.start(); ridingCamera.setMode(ridingCamera.mode == .heading ? .north : .heading) }
    @objc private func toggleNativePiP() { morePanel.isHidden = true; updateCameraSuspension(); ridingCamera.setPiP(!ridingCamera.pip); updateNativeCameraLayout(); updateNativeCameraControls(); updateDiagnostic() }
    @objc private func showNativeRoutes() {
        if routePlanning { phaseLabel.text = "正在規劃機車路線…"; return }
        guard !plannedRoutes.isEmpty else { replanCommittedDestination(); return }
        let sheet = UIAlertController(title: "機車路線", message: "Valhalla motor_scooter · 最多 3 條", preferredStyle: .actionSheet)
        if ridingCamera.mode == .navigation {
            sheet.addAction(UIAlertAction(title: "結束導航（保留目的地與路線）", style: .default) { [weak self] _ in
                guard let self else { return }
                self.ridingCamera.setMode(.heading); self.navigationState.setMode(.routePlanning)
                self.updateNativeCameraControls(); self.updateNativeCameraLayout(); self.updateDiagnostic()
            })
        } else {
            sheet.addAction(UIAlertAction(title: "開始 3D 導航", style: .default) { [weak self] _ in
                guard let self else { return }
                self.navigationState.setMode(.navigating); self.navigationState.dismissSearch()
                self.ridingCamera.setMode(.navigation); self.updateNativeCameraControls(); self.updateNativeCameraLayout(); self.updateDiagnostic()
            })
        }
        for (index, route) in plannedRoutes.enumerated() {
            let turns = route.maneuvers.filter { !["depart","arrive","continue","new name","notification"].contains($0.type) && !$0.modifier.lowercased().contains("straight") }.count
            let title = String(format: "%@ · %.1f km · %.0f 分 · %d 轉彎", route.label.isEmpty ? (index == 0 ? "推薦" : "備選 \(index+1)") : route.label, route.distance / 1000, route.duration / 60, turns)
            sheet.addAction(UIAlertAction(title: (index == selectedRouteIndex ? "✓ " : "") + title, style: .default) { [weak self] _ in self?.selectPlannedRoute(index) })
        }
        sheet.addAction(UIAlertAction(title: "重新規劃", style: .default) { [weak self] _ in self?.replanCommittedDestination() })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = sheet.popoverPresentationController { pop.sourceView = routeControl; pop.sourceRect = routeControl?.bounds ?? .zero }
        present(sheet, animated: true)
    }
    @objc private func showRouteTools() {
        morePanel.isHidden = true; updateCameraSuspension()
        let title = routeEditor.active ? "編輯路線" : "路線工具"
        let message = "途經 \(routeEditor.current?.via.count ?? viaPoints.count) · 避讓 \(avoidAreas.count)"
        let sheet = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
        if routeEditor.active {
            sheet.addAction(UIAlertAction(title: "＋ 目前地圖中心加入途經", style: .default) { [weak self] _ in self?.addEditorViaAtCenter() })
            sheet.addAction(UIAlertAction(title: "撤銷上一步", style: .default) { [weak self] _ in self?.undoRouteEdit() })
            sheet.addAction(UIAlertAction(title: "清空途經", style: .destructive) { [weak self] _ in self?.clearRouteEdit() })
            sheet.addAction(UIAlertAction(title: "完成編輯", style: .default) { [weak self] _ in self?.finishRouteEditing() })
            sheet.addAction(UIAlertAction(title: "取消編輯", style: .destructive) { [weak self] _ in self?.cancelRouteEditing() })
        } else {
            sheet.addAction(UIAlertAction(title: "開始編輯路線", style: .default) { [weak self] _ in self?.beginRouteEditing() })
        }
        sheet.addAction(UIAlertAction(title: "＋ 目前地圖中心新增避讓區 80m", style: .default) { [weak self] _ in self?.addAvoidAreaAtCenter() })
        if !avoidAreas.isEmpty { sheet.addAction(UIAlertAction(title: "管理避讓區", style: .default) { [weak self] _ in self?.showAvoidAreas() }) }
        sheet.addAction(UIAlertAction(title: "關閉", style: .cancel))
        if let pop = sheet.popoverPresentationController { pop.sourceView = moreButton; pop.sourceRect = moreButton.bounds }
        present(sheet, animated: true)
    }
    private var currentCenter: DoorCoordinate { .init(lat: map.centerCoordinate.latitude, lng: map.centerCoordinate.longitude) }
    private func queryChanged() {
        guard queryField.markedTextRange == nil else { return }
        mapResultsMode = false; areaButton.isHidden = true
        search?.begin(queryField.text ?? "", center: currentCenter, submitted: false)
    }
    @objc private func submitSearch() {
        queryField.resignFirstResponder(); morePanel.isHidden = true; mapResultsMode = true; areaButton.isHidden = true
        search?.begin(queryField.text ?? "", center: currentCenter, submitted: true)
    }
    @objc private func pasteQuery() {
        // Explicit user gesture only, never background clipboard observation.
        guard let text = UIPasteboard.general.string else { return }
        queryField.text = text; queryChanged()
    }
    @objc private func clearQuery() {
        queryField.text = ""; mapResultsMode = false; areaButton.isHidden = true; search?.clear(); renderSearch()
    }
    @objc private func researchArea() { submitSearch() }
    @objc private func loadNextPage() { search?.loadMore() }
    @objc private func toggleMore() { queryField.resignFirstResponder(); morePanel.isHidden.toggle(); updateCameraSuspension() }
    @objc private func openSearch() {
        morePanel.isHidden = true; navigationState.requestSearch(); mapResultsMode = false
        renderSearch(); queryField.becomeFirstResponder(); updateCameraSuspension()
    }
    @objc private func openOffline() {
        guard let resources, presentedViewController == nil else { return }
        morePanel.isHidden = true; queryField.resignFirstResponder()
        ridingCamera.setSuspended(true)
        present(UINavigationController(rootViewController: NativeOfflineViewController(resources: resources)), animated: true)
    }
    @objc private func toggleTheme() {
        nativePreferences.appearance = nativePreferences.appearance == .dark ? .light : nativePreferences.appearance == .light ? .system : .dark
        applyNativePreferences(); nativePreferences.save(); persistPersonal(); morePanel.isHidden = true
    }
    private func applyNativeAppearance() {
        switch nativePreferences.appearance { case .dark: overrideUserInterfaceStyle = .dark; case .light: overrideUserInterfaceStyle = .light; case .system: overrideUserInterfaceStyle = .unspecified }
    }
    private func applyNativePreferences() {
        nativePreferences.sanitize(); applyNativeAppearance()
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: nativePreferences.muted ? .muted : .default)
        configuration.pointOfInterestFilter = nativePreferences.filter
        configuration.showsTraffic = nativePreferences.traffic
        map.preferredConfiguration = configuration
        map.showsBuildings = nativePreferences.buildings
        map.isZoomEnabled = nativePreferences.zoomGestures
        map.isRotateEnabled = nativePreferences.rotateGestures
        map.isPitchEnabled = nativePreferences.pitchGestures
        ridingCamera.setRouteVisible(nativePreferences.routeVisible)
        ridingCamera.setAvatarMode(nativePreferences.avatar)
        if let mini = destinationMini {
            mini.isHidden = nativePreferences.miniMode == .hidden
            mini.setExpanded(nativePreferences.miniMode == .expanded)
        }
        if nativePreferences.stations { stationStore.load() } else { stationStore.cancel(); replaceStations(nil, message: "") }
        updateNativeCameraLayout(); updateDiagnostic()
    }
    @objc private func showMapSettings() {
        morePanel.isHidden = true; ridingCamera.setSuspended(true)
        let settings = MapSettingsViewController(nativePreferences)
        settings.stationStatus = stationStatus
        settings.cameraStatus = { [weak self] in
            guard let self else { return "" }
            return String(format: "Apple 實際傾角 %.0f° · %@ · 縮放 %.2f", self.map.camera.pitch, self.ridingCamera.mode.rawValue, NativeCameraAdapter.measuredZoom(self.map))
        }
        settings.onChange = { [weak self] value in
            guard let self else { return }
            self.nativePreferences = value; self.nativePreferences.save(); self.applyNativePreferences(); self.persistPersonal()
        }
        settings.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case "refresh-stations": self.powerDiagnostic.mark(.stationRefresh); self.powerDiagnostic.mark(.networkRequest); self.stationStore.load(force: true)
            case "clear-destination":
                self.navigationState = DoorNavigationState(); self.plannedRoutes.removeAll(); self.viaPoints.removeAll()
                self.ridingCamera.setDestination(nil); self.syncDestinationUI(centerMap: false); self.updateNativeCameraControls()
            case "open-production": UIApplication.shared.open(AppConfig.liveBaseURL)
            default: break
            }
        }
        present(UINavigationController(rootViewController: settings), animated: true)
    }
    private func configureDestinationSync() {
        destinationSync.onRequest = { [weak self] in self?.powerDiagnostic.mark(.networkRequest) }
        destinationSync.onDestination = { [weak self] point, _, silent in
            guard let self else { return }
            let record = DoorSearchRecord(displayName: "OCR 目的地", lat: point.lat, lng: point.lng,
                                          category: "handoff", feature: "ocr-sync", source: "ocr-sync")
            self.select(record)
            if !silent { self.phaseLabel.text = "OCR 目的地已同步" }
            self.updateDiagnostic()
        }
        destinationSync.scheduleBurst()
    }
    private func configurePowerDiagnostic() {
        powerDiagnostic.onChange = { [weak self] report in
            guard let self else { return }
            if !report.running && report.reason == "complete" { self.phaseLabel.text = "5 分鐘診斷完成" }
            self.updateDiagnostic()
        }
    }
    @objc private func showPowerDiagnostic() {
        morePanel.isHidden = true; updateCameraSuspension()
        let current = powerDiagnostic.snapshot()
        let title = powerDiagnostic.active ? "5 分鐘診斷進行中" : "5 分鐘運算／耗電診斷"
        let message = current?.reportText ?? "只統計 Door Map 工作量，不記 GPS 座標、不上傳，也不假裝量到 iPhone 溫度或瓦數。"
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        if powerDiagnostic.active {
            alert.addAction(UIAlertAction(title: "停止並保留報告", style: .destructive) { [weak self] _ in _ = self?.powerDiagnostic.stop(reason: "manual") })
        } else {
            alert.addAction(UIAlertAction(title: "開始 5 分鐘", style: .default) { [weak self] _ in self?.powerDiagnostic.start(foreground: self?.active ?? true) })
        }
        alert.addAction(UIAlertAction(title: "完成", style: .cancel))
        present(alert, animated: true)
    }
    private func configureStations() {
        stationStore.onChange = { [weak self] snapshot, message in
            guard let self else { return }
            self.stationStatus = message; self.replaceStations(snapshot, message: message); self.updateDiagnostic()
        }
    }
    private func replaceStations(_ snapshot: BatteryStationSnapshot?, message: String) {
        map.removeAnnotations(stationAnnotations); stationAnnotations.removeAll()
        guard nativePreferences.stations, let snapshot else { return }
        stationAnnotations = snapshot.stations.map(BatteryStationAnnotation.init); map.addAnnotations(stationAnnotations)
        if !message.isEmpty { phaseLabel.text = message }
    }
    private func showStationActions(_ station: BatteryStation) {
        let address = station.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sheet = UIAlertController(title: station.name, message: address.isEmpty ? "Gogoro 交換站位置" : address, preferredStyle: .actionSheet)
        if navigationState.destination != nil {
            sheet.addAction(UIAlertAction(title: "加入目前行程", style: .default) { [weak self] _ in self?.planStationVia(station) })
        }
        sheet.addAction(UIAlertAction(title: "直接導航到此站", style: .default) { [weak self] _ in
            guard let self else { return }
            self.select(.init(displayName: station.name, lat: station.lat, lng: station.lng,
                              address: address, category: "Gogoro", feature: "battery_swap",
                              osmKey: station.id, source: "gogoro-station"))
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }
    private func planStationVia(_ station: BatteryStation) {
        guard !routePlanning, let origin = navigationState.rawPosition, let destination = navigationState.destination else {
            phaseLabel.text = "取得有效 GPS 與原目的地後才能先規劃交換站途經"; return
        }
        let point = DoorCoordinate(lat: station.lat, lng: station.lng)
        guard point.isValid, viaPoints.count < DoorDeliveryCore.maxViaPoints else {
            phaseLabel.text = "交換站無法加入目前行程"; return
        }
        routeGeneration &+= 1; let ticket = routeGeneration
        routeTask?.cancel(); routePlanning = true; updateNativeCameraControls(); updateDiagnostic()
        let proposedVia = viaPoints + [point], areas = avoidAreas, committedDestination = destination
        phaseLabel.text = "先驗證交換站途經路線…"
        routeTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.powerDiagnostic.mark(.routeRequest); self.powerDiagnostic.mark(.networkRequest)
                let routes = try await self.routePlanner.plan(origin: origin, destination: committedDestination.coordinate,
                                                              via: proposedVia, areas: areas, alternatives: 2)
                guard !Task.isCancelled, self.routeGeneration == ticket, let first = routes.first else { return }
                self.routePlanning = false; self.viaPoints = proposedVia; self.plannedRoutes = routes; self.selectedRouteIndex = 0
                self.ridingCamera.setRoute(first.coordinates, destination: committedDestination.coordinate,
                                           maneuvers: NativeRoutePlanner.ridingManeuvers(first))
                self.ridingCamera.setMode(.navigation); self.navigationState.setMode(.navigating)
                self.syncViaAnnotations(); self.phaseLabel.text = "交換站已加入行程 · 原目的地保留"
                self.updateNativeCameraControls(); self.updateNativeCameraLayout(); self.updateDiagnostic()
            } catch {
                guard !Task.isCancelled, self.routeGeneration == ticket else { return }
                self.routePlanning = false
                self.phaseLabel.text = "交換站途經規劃失敗，原行程未改：\(error.localizedDescription)"
                self.updateNativeCameraControls(); self.updateDiagnostic()
            }
        }
    }
    private func applyPersonalSnapshot(_ snapshot: NativePersonalSnapshot) {
        nativePreferences = snapshot.preferences; avoidAreas = snapshot.avoidAreas; routeMemories = snapshot.routeMemories
        nativePreferences.save(); applyNativePreferences(); refreshAvoidOverlays(); updateDiagnostic()
    }
    private func personalSnapshot() -> NativePersonalSnapshot {
        .init(preferences: nativePreferences, avoidAreas: avoidAreas, routeMemories: routeMemories)
    }
    private func persistPersonal() {
        guard let personalStore else { return }; let snapshot = personalSnapshot()
        Task { do { _ = try await personalStore.save(snapshot) } catch { self.phaseLabel.text = "個人資料未儲存；原資料保留：\(error.localizedDescription)" } }
    }
    private func mergeRouteMemories(_ additions: [DoorRouteMemory]) {
        guard !additions.isEmpty else { return }
        var byID = Dictionary(uniqueKeysWithValues: routeMemories.map { ($0.id, $0) })
        for row in additions {
            if var old = byID[row.id] { old.count = min(1000, old.count + 1); old.updatedAt = max(old.updatedAt, row.updatedAt); old.source = row.source; byID[row.id] = old }
            else { byID[row.id] = row }
        }
        routeMemories = Array(byID.values).sorted { $0.updatedAt > $1.updatedAt }
        if routeMemories.count > DoorPlannedMemory.maxMemories { routeMemories = Array(routeMemories.prefix(DoorPlannedMemory.maxMemories)) }
        persistPersonal()
    }
    @objc private func showBackupTools() {
        morePanel.isHidden = true
        let sheet = UIAlertController(title: "個人備份", message: "只包含此測試 App 的設定、避讓區與明確路線記憶", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "路線記憶：\(nativePreferences.memoryEnabled ? "開" : "關")", style: .default) { [weak self] _ in
            guard let self else { return }
            self.nativePreferences.routeMemoryEnabled = !self.nativePreferences.memoryEnabled
            self.nativePreferences.save(); self.persistPersonal(); self.updateDiagnostic()
        })
        if !routeMemories.isEmpty {
            sheet.addAction(UIAlertAction(title: "管理路線記憶（\(routeMemories.count)）", style: .default) { [weak self] _ in self?.showRouteMemories() })
        }
        sheet.addAction(UIAlertAction(title: "匯出備份", style: .default) { [weak self] _ in self?.exportPersonalBackup() })
        sheet.addAction(UIAlertAction(title: "匯入備份", style: .default) { [weak self] _ in self?.importPersonalBackup() })
        sheet.addAction(UIAlertAction(title: "回復上一版個人資料", style: .destructive) { [weak self] _ in self?.rollbackPersonalBackup() })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel)); present(sheet, animated: true)
    }
    private func showRouteMemories() {
        let sheet = UIAlertController(title: "路線記憶", message: "只來自你明確選備選或編輯路線；不學 GPS 行駛軌跡。", preferredStyle: .actionSheet)
        for (index, row) in routeMemories.prefix(20).enumerated() {
            let title = "\(row.source == .edit ? "手動編輯" : "備選路線") · 使用 \(row.count) 次 · \(Int(DoorPlannedMemory.length(row.points)))m"
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self, self.routeMemories.indices.contains(index) else { return }
                let item = self.routeMemories[index]
                let coordinates = item.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
                guard let first = coordinates.first else { return }
                var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 1, height: 1))
                for c in coordinates.dropFirst() { rect = rect.union(MKMapRect(origin: MKMapPoint(c), size: MKMapSize(width: 1, height: 1))) }
                self.map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 120, left: 55, bottom: 140, right: 85), animated: true)
            })
        }
        sheet.addAction(UIAlertAction(title: "清除全部路線記憶", style: .destructive) { [weak self] _ in
            self?.routeMemories.removeAll(); self?.persistPersonal(); self?.updateDiagnostic()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }
    private func exportPersonalBackup() {
        guard let personalStore else { return }; let snapshot = personalSnapshot()
        Task {
            do {
                let data = try await personalStore.exportData(snapshot)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("581-DoorMap-personal-backup.json")
                try data.write(to: url, options: .atomic)
                let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil); self.present(activity, animated: true)
            } catch { self.phaseLabel.text = "備份匯出失敗：\(error.localizedDescription)" }
        }
    }
    private func importPersonalBackup() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true); picker.delegate = self; picker.allowsMultipleSelection = false; present(picker, animated: true)
    }
    private func rollbackPersonalBackup() {
        guard let personalStore else { return }
        Task {
            do {
                if let snapshot = try await personalStore.rollback() { self.applyPersonalSnapshot(snapshot); self.phaseLabel.text = "已回復上一版個人資料" }
                else { self.phaseLabel.text = "沒有可回復的上一版個人資料" }
            } catch { self.phaseLabel.text = "回復失敗；現有資料未改：\(error.localizedDescription)" }
        }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let personalStore else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            Task {
                do { let snapshot = try await personalStore.importData(data); self.applyPersonalSnapshot(snapshot); self.phaseLabel.text = "個人備份匯入完成" }
                catch { self.phaseLabel.text = "備份驗證失敗；原資料未變：\(error.localizedDescription)" }
            }
        } catch { phaseLabel.text = "無法讀取備份：\(error.localizedDescription)" }
    }
    @objc private func showPortStatus() {
        morePanel.isHidden = true
        let alert = UIAlertController(title: "581 全原生工程候選", message: "已接線：原生搜尋／離線資料、Apple 商家、Google／OCR 目的地、定位與方向、FIT／PiP／3D 導航、偏航重算、NLSC 門牌修正、社區／OSM／門牌圖層、途經／避讓／路線編輯、Gogoro、備份／路線記憶與功耗診斷。\n\n仍待驗收：最新 source 的 Apple SDK／Simulator 全套驗證與實體 iPhone GPS／指南針／騎乘／熱／耗電／簽署隔離；自製建物立體效果受 MapKit SDK 限制，不能宣稱與舊自繪 extrusion 完全相同。\n\n資料沿用已核對 OSM／臺中官方資料；Apple 即時資料不寫入離線包。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "完成", style: .cancel)); present(alert, animated: true)
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { submitSearch(); return false }
    func textFieldDidBeginEditing(_ textField: UITextField) { mapResultsMode = false; renderSearch(); updateCameraSuspension() }
    func textFieldDidEndEditing(_ textField: UITextField) { updateCameraSuspension() }
    func textFieldShouldClear(_ textField: UITextField) -> Bool { search?.clear(); mapResultsMode = false; areaButton.isHidden = true; renderSearch(); return true }
    private func renderSearch() {
        guard let search else { return }
        results.reloadData(); results.tableFooterView = search.hasMore ? loadMore : nil
        searchStatus.text = search.message
        clearQueryButton.isHidden = search.query.isEmpty
        results.isHidden = mapResultsMode || search.query.isEmpty || search.page.isEmpty
        searchStatus.isHidden = mapResultsMode || search.message.isEmpty
        searchMap.setResults(search.presentation.pins)
        updateTableHeight(); updateDiagnostic()
    }
    private func updateTableHeight() {
        guard resultsHeight != nil else { return }
        let rows = search?.page.count ?? 0
        let height = results.isHidden ? 0 : min(360, min(view.bounds.height * 0.46, CGFloat(rows * 72 + ((search?.hasMore == true) ? 44 : 0))))
        if abs(resultsHeight.constant - height) > 0.5 { resultsHeight.constant = height }
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { search?.page.count ?? 0 }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "native-candidate") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "native-candidate")
        guard let values = search?.page, values.indices.contains(indexPath.row) else { return cell }
        let result = values[indexPath.row], record = result.record
        cell.backgroundColor = .clear; cell.textLabel?.textColor = .white; cell.textLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        cell.textLabel?.text = record.displayName; cell.textLabel?.numberOfLines = 0
        let distance = result.distanceM.map { $0 < 1000 ? "\(Int($0.rounded())) m" : String(format: "%.1f km", $0 / 1000) } ?? "距離未確認"
        cell.detailTextLabel?.text = DoorSearchCore.locationText(record) + " · " + distance + (record.source.hasPrefix("apple") ? " · Apple 地圖" : "")
        cell.detailTextLabel?.textColor = .secondaryLabel; cell.detailTextLabel?.font = .systemFont(ofSize: 12); cell.detailTextLabel?.numberOfLines = 0
        cell.accessibilityIdentifier = "native-candidate-\(indexPath.row)"
        cell.accessibilityValue = result.id; cell.accessoryType = .disclosureIndicator
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let values = search?.page, values.indices.contains(indexPath.row) else { return }
        select(values[indexPath.row].record)
    }
    private func select(_ record: DoorSearchRecord) {
        guard record.coordinate.isValid else { return }
        reroutePolicy = DoorReroutePolicy(); lastRerouteReason = ""
        search?.cancelPendingPreservingResults(); queryField.resignFirstResponder(); mapResultsMode = true; morePanel.isHidden = true
        if testMode {
            navigationState.selectDestination(.init(coordinate: record.coordinate, title: record.displayName, source: record.source))
            plannedRoutes.removeAll(); selectedRouteIndex = 0; syncDestinationUI(centerMap: true); renderSearch(); updateDiagnostic(); return
        }
        guard let origin = navigationState.rawPosition else {
            navigationState.selectDestination(.init(coordinate: record.coordinate, title: record.displayName, source: record.source))
            plannedRoutes.removeAll(); selectedRouteIndex = 0; syncDestinationUI(centerMap: true)
            phaseLabel.text = "已設定目的地；取得有效 GPS 後規劃機車路線"; renderSearch(); updateDiagnostic(); return
        }
        planDestination(record, origin: origin)
    }
    private func preferredRoutesIfAvailable(_ baseline: [DoorPlannedRoute], origin: DoorCoordinate,
                                            destination: DoorCoordinate, areas: [DoorAvoidArea],
                                            ticket: UInt64) async -> [DoorPlannedRoute] {
        guard nativePreferences.memoryEnabled, viaPoints.isEmpty, !routeEditor.active,
              let main = baseline.first,
              let memory = DoorPlannedMemory.candidates(routeMemories, route: main).first else { return baseline }
        do {
            powerDiagnostic.mark(.routeRequest); powerDiagnostic.mark(.networkRequest)
            let candidates = try await routePlanner.plan(origin: origin, destination: destination,
                                                         via: memory.row.points, areas: areas,
                                                         alternatives: 0)
            guard !Task.isCancelled, routeGeneration == ticket, var preferred = candidates.first,
                  DoorPlannedMemory.reasonable(baseline: main, candidate: preferred) else { return baseline }
            preferred.label = "個人路線"
            var output = [preferred]
            for route in baseline where output.count < 3 {
                if route.coordinates != preferred.coordinates { output.append(route) }
            }
            return output
        } catch { return baseline }
    }
    private func planDestination(_ record: DoorSearchRecord, origin: DoorCoordinate) {
        guard origin.isValid, record.coordinate.isValid else { return }
        routeGeneration &+= 1; let ticket = routeGeneration; routeTask?.cancel(); routePlanning = true
        reroutePolicy.requested(at: ProcessInfo.processInfo.systemUptime * 1000, reason: .missingRoute)
        updateNativeCameraControls(); updateDiagnostic()
        let destination = record.coordinate, vias = viaPoints, areas = avoidAreas
        phaseLabel.text = "正在規劃機車路線…"
        routeTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.powerDiagnostic.mark(.routeRequest); self.powerDiagnostic.mark(.networkRequest)
                let baseline = try await self.routePlanner.plan(origin: origin, destination: destination, via: vias, areas: areas, alternatives: 2)
                guard !Task.isCancelled, self.routeGeneration == ticket, !baseline.isEmpty else { return }
                let routes = await self.preferredRoutesIfAvailable(baseline, origin: origin, destination: destination, areas: areas, ticket: ticket)
                guard !Task.isCancelled, self.routeGeneration == ticket, let first = routes.first else { return }
                self.routePlanning = false; self.plannedRoutes = routes; self.selectedRouteIndex = 0
                self.navigationState.selectDestination(.init(coordinate: destination, title: record.displayName, source: record.source))
                self.navigationState.setMode(.navigating); self.navigationState.dismissSearch()
                self.syncDestinationUI(centerMap: true)
                self.ridingCamera.setRoute(first.coordinates, destination: destination, maneuvers: NativeRoutePlanner.ridingManeuvers(first))
                self.reroutePolicy.reset(acceptedAtMS: ProcessInfo.processInfo.systemUptime * 1000)
                self.ridingCamera.setMode(.navigation)
                self.phaseLabel.text = (first.label == "個人路線" ? "已套用明確路線記憶 · " : "機車路線已完成 · ") + "\(routes.count) 條可選"
                self.updateNativeCameraControls(); self.updateNativeCameraLayout(); self.updateDiagnostic()
            } catch {
                guard !Task.isCancelled, self.routeGeneration == ticket else { return }
                self.routePlanning = false
                self.phaseLabel.text = "新路線規劃失敗，上一條行程保留：\(error.localizedDescription)"
                self.updateNativeCameraControls(); self.updateDiagnostic()
            }
        }
    }
    private func maybeAutoReroute(_ fix: NativeSensorFix) {
        guard !testMode, !fix.warm, active, !routePlanning, !routeEditor.active,
              let destination = navigationState.destination else { return }
        let route = plannedRoutes.indices.contains(selectedRouteIndex) ? plannedRoutes[selectedRouteIndex].coordinates : []
        let now = ProcessInfo.processInfo.systemUptime * 1000
        let heading = fix.course ?? ridingCamera.displayHeading
        guard let decision = reroutePolicy.evaluate(position: fix.coordinate, accuracy: fix.accuracy,
                                                    heading: heading, speed: fix.speed,
                                                    route: route, nowMS: now) else { return }
        requestAutoReroute(origin: fix.coordinate, destination: destination, decision: decision, nowMS: now)
    }

    private func requestAutoReroute(origin: DoorCoordinate, destination: DoorNavigationState.Destination,
                                    decision: DoorReroutePolicy.Decision, nowMS: Double) {
        guard !routePlanning, !routeEditor.active, origin.isValid, destination.coordinate.isValid else { return }
        reroutePolicy.requested(at: nowMS, reason: decision.reason)
        routeGeneration &+= 1; let ticket = routeGeneration
        routeTask?.cancel(); routePlanning = true; autoRerouteCount += 1; lastRerouteReason = decision.reason.rawValue
        let vias = viaPoints, areas = avoidAreas
        let priorMode = ridingCamera.mode
        phaseLabel.text = decision.reason == .missedTurn ? "偵測到漏轉彎，重新規劃機車路線…" : "偏離路線，重新規劃機車路線…"
        updateNativeCameraControls(); updateDiagnostic()
        routeTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.powerDiagnostic.mark(.routeRequest); self.powerDiagnostic.mark(.networkRequest)
                let baseline = try await self.routePlanner.plan(origin: origin, destination: destination.coordinate,
                                                               via: vias, areas: areas, alternatives: 2)
                guard !Task.isCancelled, self.routeGeneration == ticket, !baseline.isEmpty else { return }
                let routes = await self.preferredRoutesIfAvailable(baseline, origin: origin,
                                                                    destination: destination.coordinate,
                                                                    areas: areas, ticket: ticket)
                guard !Task.isCancelled, self.routeGeneration == ticket, let first = routes.first else { return }
                self.routePlanning = false; self.plannedRoutes = routes; self.selectedRouteIndex = 0
                self.ridingCamera.setRoute(first.coordinates, destination: destination.coordinate,
                                           maneuvers: NativeRoutePlanner.ridingManeuvers(first))
                self.reroutePolicy.reset(acceptedAtMS: ProcessInfo.processInfo.systemUptime * 1000)
                self.navigationState.setMode(.navigating)
                if priorMode == .fit { self.ridingCamera.setMode(.fit) }
                else { self.ridingCamera.setMode(.navigation) }
                self.phaseLabel.text = "機車路線已重新規劃 · 原目的地保留"
                self.syncViaAnnotations(); self.refreshPublicLayers()
                self.updateNativeCameraControls(); self.updateNativeCameraLayout(); self.updateDiagnostic()
            } catch {
                guard !Task.isCancelled, self.routeGeneration == ticket else { return }
                self.routePlanning = false
                self.phaseLabel.text = "重新規劃失敗，原路線保留：\(error.localizedDescription)"
                self.updateNativeCameraControls(); self.updateDiagnostic()
            }
        }
    }

    private func replanCommittedDestination() {
        guard !testMode, !routePlanning, let origin = navigationState.rawPosition, let destination = navigationState.destination else { return }
        let record = DoorSearchRecord(displayName: destination.title, lat: destination.coordinate.lat, lng: destination.coordinate.lng, source: destination.source)
        planDestination(record, origin: origin)
    }
    private func selectPlannedRoute(_ index: Int) {
        guard plannedRoutes.indices.contains(index), let destination = navigationState.destination else { return }
        let previous = plannedRoutes.indices.contains(selectedRouteIndex) ? plannedRoutes[selectedRouteIndex] : nil
        selectedRouteIndex = index; let route = plannedRoutes[index]
        ridingCamera.setRoute(route.coordinates, destination: destination.coordinate, maneuvers: NativeRoutePlanner.ridingManeuvers(route))
        reroutePolicy.reset(acceptedAtMS: ProcessInfo.processInfo.systemUptime * 1000)
        navigationState.setMode(.navigating); ridingCamera.setMode(.navigation)
        if let previous, index != 0 { mergeRouteMemories(DoorPlannedMemory.differences(before: previous, after: route, source: .alternative, nowMS: Date().timeIntervalSince1970 * 1000)) }
        phaseLabel.text = "已切換：" + (route.label.isEmpty ? "備選 \(index+1)" : route.label)
        updateNativeCameraControls(); updateNativeCameraLayout(); updateDiagnostic()
    }
    private func syncDestinationUI(centerMap: Bool) {
        guard let destination = navigationState.destination else {
            if let destinationPin { map.removeAnnotation(destinationPin) }; destinationPin = nil
            destinationLabel.text = "未設定目的地"
            destinationMini?.setTarget(nil, revision: navigationState.destinationRevision, viewportCenter: currentCenter)
            ridingCamera.setDestination(nil); return
        }
        ridingCamera.setDestination(destination.coordinate)
        if let destinationPin { map.removeAnnotation(destinationPin) }
        let pin = MKPointAnnotation(); pin.coordinate = .init(latitude: destination.coordinate.lat, longitude: destination.coordinate.lng); pin.title = destination.title
        destinationPin = pin; map.addAnnotation(pin)
        destinationLabel.text = "  " + destination.title
        destinationMini?.setTarget(destination, revision: navigationState.destinationRevision, viewportCenter: currentCenter)
        if centerMap { map.setCenter(pin.coordinate, animated: false) }
        updateCameraSuspension(); updateNativeCameraLayout(); updateDiagnostic()
    }
    private func beginRouteEditing() {
        guard !routeEditor.active, plannedRoutes.indices.contains(selectedRouteIndex), navigationState.destination != nil, navigationState.rawPosition != nil else {
            phaseLabel.text = "需要已完成的機車路線才能編輯"; return
        }
        do {
            _ = try routeEditor.begin(.init(via: viaPoints, record: plannedRoutes[selectedRouteIndex],
                                            alternates: plannedRoutes.enumerated().filter { $0.offset != selectedRouteIndex }.map { $0.element }))
            navigationState.setMode(.routeEditing); syncViaAnnotations(); showRoutePreview(routeEditor.current?.record)
            updateCameraSuspension(); phaseLabel.text = "編輯路線：長按地圖加途經，拖動編號點移動"; updateDiagnostic()
        } catch { phaseLabel.text = error.localizedDescription }
    }
    @objc private func routeEditLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard routeEditor.active, gesture.state == .began else { return }
        let c = map.convert(gesture.location(in: map), toCoordinateFrom: map)
        let point = DoorCoordinate(lat: c.latitude, lng: c.longitude)
        do { let version = try routeEditor.change(.add(point)); syncViaAnnotations(); replanRouteEditor(version: version) }
        catch { phaseLabel.text = error.localizedDescription }
    }
    private func addEditorViaAtCenter() {
        guard routeEditor.active else { beginRouteEditing(); return }
        do { let version = try routeEditor.change(.add(currentCenter)); syncViaAnnotations(); replanRouteEditor(version: version) }
        catch { phaseLabel.text = error.localizedDescription }
    }
    private func undoRouteEdit() {
        guard routeEditor.undo() else { return }; syncViaAnnotations(); replanRouteEditor(version: routeEditor.version)
    }
    private func clearRouteEdit() {
        guard routeEditor.active else { return }; routeEditor.clear(); syncViaAnnotations(); replanRouteEditor(version: routeEditor.version)
    }
    private func replanRouteEditor(version: UInt64) {
        guard routeEditor.active, let snapshot = routeEditor.current, let origin = navigationState.rawPosition,
              let destination = navigationState.destination else { return }
        routeEditorTask?.cancel(); let areas = avoidAreas, vias = snapshot.via
        if testMode {
            let coordinates = [origin] + vias + [destination.coordinate]
            let distance = zip(coordinates, coordinates.dropFirst()).reduce(0.0) { $0 + DoorCameraGeometry.haversine($1.0, $1.1) }
            let fixture = DoorPlannedRoute(coordinates: coordinates, distance: distance, duration: max(30, distance / 6), label: "編輯預覽")
            do { _ = try routeEditor.accept(version: version, route: fixture); showRoutePreview(fixture); phaseLabel.text = "預覽完成；按完成編輯才會套用"; updateDiagnostic() }
            catch { routeEditor.fail(version: version, message: error.localizedDescription); phaseLabel.text = error.localizedDescription }
            return
        }
        phaseLabel.text = "正在驗證編輯後機車路線…"
        routeEditorTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.powerDiagnostic.mark(.routeRequest); self.powerDiagnostic.mark(.networkRequest)
                let routes = try await self.routePlanner.plan(origin: origin, destination: destination.coordinate, via: vias, areas: areas, alternatives: 2)
                guard !Task.isCancelled, self.routeEditor.active, self.routeEditor.version == version, let first = routes.first else { return }
                _ = try self.routeEditor.accept(version: version, route: first, alternates: Array(routes.dropFirst()))
                self.showRoutePreview(first); self.phaseLabel.text = "預覽完成；按完成編輯才會套用"; self.updateDiagnostic()
            } catch {
                guard !Task.isCancelled, self.routeEditor.active, self.routeEditor.version == version else { return }
                self.routeEditor.fail(version: version, message: error.localizedDescription)
                self.phaseLabel.text = "這次編輯無可用機車路線；正式行程未變"; self.updateDiagnostic()
            }
        }
    }
    private func showRoutePreview(_ route: DoorPlannedRoute?) {
        if let routePreviewLine { map.removeOverlay(routePreviewLine) }; routePreviewLine = nil
        guard let route, route.coordinates.count >= 2 else { return }
        var coords = route.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
        let line = MKPolyline(coordinates: &coords, count: coords.count); routePreviewLine = line; map.addOverlay(line, level: .aboveRoads)
    }
    private func syncViaAnnotations() {
        map.removeAnnotations(routeViaAnnotations); routeViaAnnotations.removeAll()
        guard routeEditor.active, let vias = routeEditor.current?.via else { return }
        routeViaAnnotations = vias.enumerated().map { NativeViaAnnotation(index: $0.offset, coordinate: .init(latitude: $0.element.lat, longitude: $0.element.lng)) }
        map.addAnnotations(routeViaAnnotations)
    }
    private func finishRouteEditing() {
        do {
            let result = try routeEditor.finish(); viaPoints = result.snapshot.via
            if result.changed { mergeRouteMemories(DoorPlannedMemory.differences(before: result.base.record, after: result.snapshot.record, source: .edit, nowMS: Date().timeIntervalSince1970 * 1000)) }
            plannedRoutes = [result.snapshot.record] + result.snapshot.alternates; selectedRouteIndex = 0
            if let destination = navigationState.destination {
                ridingCamera.setRoute(result.snapshot.record.coordinates, destination: destination.coordinate,
                                      maneuvers: NativeRoutePlanner.ridingManeuvers(result.snapshot.record))
            }
            cleanupRouteEditorVisuals(); navigationState.setMode(.navigating); ridingCamera.setMode(.navigation); updateCameraSuspension()
            phaseLabel.text = result.changed ? "路線編輯已套用" : "路線未變更"; updateNativeCameraControls(); updateNativeCameraLayout(); updateDiagnostic()
        } catch { phaseLabel.text = error.localizedDescription }
    }
    private func cancelRouteEditing() {
        _ = routeEditor.cancel(); cleanupRouteEditorVisuals(); navigationState.setMode(navigationState.destination == nil ? .browse : .navigating)
        updateCameraSuspension(); phaseLabel.text = "已取消編輯；原行程保留"; updateDiagnostic()
    }
    private func cleanupRouteEditorVisuals() {
        routeEditorTask?.cancel(); routeEditorTask = nil
        if let routePreviewLine { map.removeOverlay(routePreviewLine) }; routePreviewLine = nil
        map.removeAnnotations(routeViaAnnotations); routeViaAnnotations.removeAll()
    }
    private func removeVia(_ index: Int) {
        guard routeEditor.active else { return }
        do { let version = try routeEditor.change(.delete(index)); syncViaAnnotations(); replanRouteEditor(version: version) }
        catch { phaseLabel.text = error.localizedDescription }
    }
    private func addAvoidAreaAtCenter() {
        guard avoidAreas.count < DoorDeliveryCore.maxAreas, DoorDeliveryCore.point(currentCenter) else { return }
        let point = currentCenter
        avoidAreas.append(.init(id: UUID().uuidString, name: "避開區域 \(avoidAreas.count + 1)", lat: point.lat, lng: point.lng,
                               radius: 80, enabled: true, start: "00:00", end: "00:00", createdAt: Date().timeIntervalSince1970 * 1000))
        avoidAreas = DoorDeliveryCore.sanitizeAreas(avoidAreas); refreshAvoidOverlays(); persistPersonal()
        if routeEditor.active { replanRouteEditor(version: routeEditor.version) } else { replanCommittedDestination() }
        updateDiagnostic()
    }
    private func showAvoidAreas() {
        let sheet = UIAlertController(title: "避讓區域", message: "目前 \(avoidAreas.count) 個", preferredStyle: .actionSheet)
        for (index, area) in avoidAreas.enumerated() {
            sheet.addAction(UIAlertAction(title: "\(area.enabled ? "●" : "○") \(area.name) · \(Int(area.radius))m · \(area.start)-\(area.end)", style: .default) { [weak self] _ in self?.showAvoidAreaActions(index) })
        }
        sheet.addAction(UIAlertAction(title: "全部清除", style: .destructive) { [weak self] _ in
            self?.avoidAreas.removeAll(); self?.refreshAvoidOverlays(); self?.persistPersonal()
            if self?.routeEditor.active == true { self?.replanRouteEditor(version: self?.routeEditor.version ?? 0) } else { self?.replanCommittedDestination() }
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel)); present(sheet, animated: true)
    }
    private func showAvoidAreaActions(_ index: Int) {
        guard avoidAreas.indices.contains(index) else { return }; let area = avoidAreas[index]
        let sheet = UIAlertController(title: area.name, message: "避讓半徑 \(Int(area.radius))m", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: area.enabled ? "停用" : "啟用", style: .default) { [weak self] _ in self?.modifyAvoid(index) { $0.enabled.toggle() } })
        if area.radius < 200 { sheet.addAction(UIAlertAction(title: "半徑 +20m", style: .default) { [weak self] _ in self?.modifyAvoid(index) { $0.radius += 20 } }) }
        if area.radius > 30 { sheet.addAction(UIAlertAction(title: "半徑 -20m", style: .default) { [weak self] _ in self?.modifyAvoid(index) { $0.radius -= 20 } }) }
        sheet.addAction(UIAlertAction(title: "刪除", style: .destructive) { [weak self] _ in self?.deleteAvoid(index) })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel)); present(sheet, animated: true)
    }
    private func modifyAvoid(_ index: Int, change: (inout DoorAvoidArea) -> Void) {
        guard avoidAreas.indices.contains(index) else { return }; change(&avoidAreas[index]); avoidAreas = DoorDeliveryCore.sanitizeAreas(avoidAreas); refreshAvoidOverlays(); persistPersonal()
        if routeEditor.active { replanRouteEditor(version: routeEditor.version) } else { replanCommittedDestination() }; updateDiagnostic()
    }
    private func deleteAvoid(_ index: Int) {
        guard avoidAreas.indices.contains(index) else { return }; avoidAreas.remove(at: index); refreshAvoidOverlays(); persistPersonal()
        if routeEditor.active { replanRouteEditor(version: routeEditor.version) } else { replanCommittedDestination() }; updateDiagnostic()
    }
    private func refreshAvoidOverlays() {
        avoidOverlays.forEach { map.removeOverlay($0) }; avoidOverlays.removeAll(); avoidOverlayStatus.removeAll()
        let clean = DoorDeliveryCore.sanitizeAreas(avoidAreas), minute = DoorDeliveryCore.taipeiMinute(Date())
        let chosen = DoorDeliveryCore.choose(clean, origin: navigationState.rawPosition,
                                             destination: navigationState.destination?.coordinate,
                                             via: viaPoints, minute: minute)
        let exempt = Set(chosen.endpointExempt.map(\.id))
        for area in clean where area.enabled {
            let circle = MKCircle(center: .init(latitude: area.lat, longitude: area.lng), radius: area.radius)
            avoidOverlays.append(circle)
            avoidOverlayStatus[ObjectIdentifier(circle)] = !DoorDeliveryCore.active(area, minute: minute) ? "inactive" : exempt.contains(area.id) ? "exempt" : "active"
            map.addOverlay(circle, level: .aboveRoads)
        }
        scheduleAvoidBoundary()
    }
    private func scheduleAvoidBoundary() {
        avoidBoundaryTimer?.invalidate(); avoidBoundaryTimer = nil
        guard active, let delay = DoorDeliveryCore.nextBoundaryMS(avoidAreas, now: Date()), delay.isFinite else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: max(0.2, delay / 1000), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                self.refreshAvoidOverlays()
                if self.routeEditor.active { self.replanRouteEditor(version: self.routeEditor.version) }
                else if self.navigationState.destination != nil { self.replanCommittedDestination() }
                self.phaseLabel.text = "避讓時段已切換，機車路線已重新檢查"
                self.updateDiagnostic()
            }
        }
        timer.tolerance = 0.25; avoidBoundaryTimer = timer
    }
    private func refreshPublicLayers() {
        guard active, let publicLayers else { return }
        let route = plannedRoutes.indices.contains(selectedRouteIndex) ? plannedRoutes[selectedRouteIndex].coordinates : []
        publicLayers.refresh(route: route, destination: navigationState.destination?.coordinate, rider: navigationState.displayPosition)
    }
    @objc private func userPanned(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { morePanel.isHidden = true }
        if gesture.state == .ended {
            if centerPickerEnabled { updateCenterPickerLabel() }
            if search?.query.isEmpty == false { areaButton.isHidden = false }
            updateDiagnostic()
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if let publicView = publicLayers?.annotationView(for: annotation) { return publicView }
        if let via = annotation as? NativeViaAnnotation {
            let v = MKMarkerAnnotationView(annotation: via, reuseIdentifier: "native-via")
            v.markerTintColor = .systemOrange; v.glyphText = String(via.index + 1); v.displayPriority = .required
            v.isDraggable = routeEditor.active; v.canShowCallout = false; v.accessibilityIdentifier = "native-via-\(via.index)"
            return v
        }
        if let station = annotation as? BatteryStationAnnotation {
            let v = MKMarkerAnnotationView(annotation: station, reuseIdentifier: "native-gogoro-station")
            v.markerTintColor = .systemGreen; v.glyphText = "G"; v.displayPriority = .defaultHigh
            v.clusteringIdentifier = "native-gogoro-cluster"; v.canShowCallout = false
            v.accessibilityIdentifier = "native-gogoro-" + station.station.id
            return v
        }
        if let cluster = annotation as? MKClusterAnnotation,
           !cluster.memberAnnotations.isEmpty,
           cluster.memberAnnotations.allSatisfy({ $0 is BatteryStationAnnotation }) {
            let v = MKMarkerAnnotationView(annotation: cluster, reuseIdentifier: "native-gogoro-cluster")
            v.markerTintColor = .systemGreen; v.glyphText = String(cluster.memberAnnotations.count)
            v.displayPriority = .required; v.canShowCallout = false
            v.accessibilityIdentifier = "native-gogoro-cluster"
            return v
        }
        if let rider = ridingCamera.annotationView(for: annotation) { return rider }
        if let rendered = searchMap.annotationView(for: annotation) { return rendered }
        if annotation === destinationPin { let v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "native-selected-target"); v.markerTintColor = .systemRed; v.displayPriority = .required; v.canShowCallout = true; return v }
        return nil
    }
    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        if let info = publicLayers?.selection(for: view.annotation) {
            if let annotation = view.annotation { mapView.deselectAnnotation(annotation, animated: false) }
            let alert = UIAlertController(title: info.0.isEmpty ? "地圖資料" : info.0, message: info.1, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "完成", style: .default)); present(alert, animated: true); return
        }
        if let station = view.annotation as? BatteryStationAnnotation {
            mapView.deselectAnnotation(station, animated: false); showStationActions(station.station); return
        }
        if let cluster = view.annotation as? MKClusterAnnotation,
           !cluster.memberAnnotations.isEmpty,
           cluster.memberAnnotations.allSatisfy({ $0 is BatteryStationAnnotation }) {
            mapView.deselectAnnotation(cluster, animated: false)
            let coordinates = cluster.memberAnnotations.map(\.coordinate)
            if let first = coordinates.first {
                var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 1, height: 1))
                for point in coordinates.dropFirst() { rect = rect.union(MKMapRect(origin: MKMapPoint(point), size: MKMapSize(width: 1, height: 1))) }
                mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 120, left: 50, bottom: 140, right: 50), animated: true)
            }
            return
        }
        if let via = view.annotation as? NativeViaAnnotation {
            mapView.deselectAnnotation(via, animated: false)
            let sheet = UIAlertController(title: "途經 \(via.index + 1)", message: "拖動編號點可移動", preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "移到目前地圖中心", style: .default) { [weak self] _ in
                guard let self else { return }
                do { let version = try self.routeEditor.change(.move(via.index, self.currentCenter)); self.syncViaAnnotations(); self.replanRouteEditor(version: version) }
                catch { self.phaseLabel.text = error.localizedDescription }
            })
            sheet.addAction(UIAlertAction(title: "刪除", style: .destructive) { [weak self] _ in self?.removeVia(via.index) })
            sheet.addAction(UIAlertAction(title: "取消", style: .cancel)); present(sheet, animated: true); return
        }
        if let item = view.annotation as? NativeSearchAnnotation { select(item.result.record); mapView.deselectAnnotation(item, animated: false); return }
        if let cluster = view.annotation as? NativeSearchGroupAnnotation {
            mapView.deselectAnnotation(cluster, animated: false)
            openCluster(cluster); return
        }
        if !testMode, let feature = view.annotation as? MKMapFeatureAnnotation {
            mapSelectionRequest?.cancel(); let request = MKMapItemRequest(mapFeatureAnnotation: feature); mapSelectionRequest = request
            request.getMapItem { [weak self, weak request] item, error in
                Task { @MainActor [weak self] in
                    guard let self, let request, self.mapSelectionRequest === request, self.active, let item, error == nil else { return }
                    let p = item.placemark
                    let alert = UIAlertController(title: item.name, message: p.title, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "設為目的地", style: .default) { [weak self] _ in
                        self?.select(.init(displayName: item.name ?? "Apple 位置", lat: p.coordinate.latitude, lng: p.coordinate.longitude, address: p.title ?? "", source: "apple-native-mapkit"))
                    }); alert.addAction(UIAlertAction(title: "取消", style: .cancel))
                    if self.presentedViewController == nil { self.present(alert, animated: true) }
                }
            }
        }
    }
    private func openCluster(_ cluster: NativeSearchGroupAnnotation) {
        guard presentedViewController == nil, let first=cluster.members.first else { return }
        let coordinates=cluster.members.map { CLLocationCoordinate2D(latitude:$0.record.lat,longitude:$0.record.lng) }
        var rect=MKMapRect(origin:MKMapPoint(coordinates[0]),size:MKMapSize(width:1,height:1))
        for c in coordinates.dropFirst() { rect=rect.union(MKMapRect(origin:MKMapPoint(c),size:MKMapSize(width:1,height:1))) }
        let scale=MKMapPointsPerMeterAtLatitude(first.record.lat)
        if max(rect.width,rect.height) / scale <= 12 || map.camera.centerCoordinateDistance < 80 {
            let list=NativeSearchMembersViewController(members:cluster.members)
            list.onSelect={ [weak self] record in self?.select(record) }
            present(UINavigationController(rootViewController:list),animated:true)
        } else {
            queryField.resignFirstResponder(); mapResultsMode=true; renderSearch(); view.layoutIfNeeded()
            map.setVisibleMapRect(rect,edgePadding:UIEdgeInsets(top:max(140,searchPanel.frame.maxY+16),left:35,bottom:120,right:85),animated:true)
        }
    }
    func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                 didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
        guard newState == .ending, let via = view.annotation as? NativeViaAnnotation, routeEditor.active else { return }
        let p = DoorCoordinate(lat: via.coordinate.latitude, lng: via.coordinate.longitude)
        do { let version = try routeEditor.change(.move(via.index, p)); syncViaAnnotations(); replanRouteEditor(version: version) }
        catch { phaseLabel.text = error.localizedDescription }
    }
    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        powerDiagnostic.mark(.mapMove); searchMap.refresh(); ridingCamera.regionChanged(); refreshPublicLayers(); if centerPickerEnabled { updateCenterPickerLabel() }; updateDiagnostic()
    }
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let preview = routePreviewLine, overlay === preview {
            let r = MKPolylineRenderer(polyline: preview); r.strokeColor = .systemOrange; r.lineWidth = 5; r.lineDashPattern = [10, 6]; return r
        }
        if let circle = overlay as? MKCircle, avoidOverlays.contains(where: { $0 === circle }) {
            let status = avoidOverlayStatus[ObjectIdentifier(circle)] ?? "active"
            let color: UIColor = status == "inactive" ? .systemGray : status == "exempt" ? .systemOrange : .systemRed
            let r = MKCircleRenderer(circle: circle); r.fillColor = color.withAlphaComponent(status == "inactive" ? 0.06 : 0.12)
            r.strokeColor = color.withAlphaComponent(status == "inactive" ? 0.45 : 0.78); r.lineWidth = 2
            r.lineDashPattern = status == "active" ? [6,4] : [3,5]; return r
        }
        return publicLayers?.renderer(for: overlay) ?? ridingCamera.renderer(for: overlay) ?? MKOverlayRenderer(overlay: overlay)
    }
    func notifyLifecycle(_ state: String) {
        active = state == "foreground" || state == "willForeground"
        nativeSensors.setActive(active); ridingCamera.setActive(active); destinationMini?.setActive(active); powerDiagnostic.setForeground(active)
        if active { updateNativeOrientation(); updateCameraSuspension(); refreshPublicLayers(); refreshAvoidOverlays(); destinationSync.scheduleBurst() }
        if !active { search?.cancelPendingPreservingResults(); mapSelectionRequest?.cancel(); destinationSync.cancel() }
        if state == "background" {
            publicLayers?.releaseVisible()
            Task { [resources, repository] in await repository?.releaseDisposableCaches(); await resources?.releaseDisposableCaches() }
        }
    }
    func prepareForSceneDisconnect() {
        active = false; routeGeneration &+= 1; routeTask?.cancel(); routeTask = nil; routePlanning = false; routeEditorTask?.cancel(); routeEditorTask = nil
        handoffGeneration &+= 1; handoffTask?.cancel(); handoffTask = nil
        search?.cancelPendingPreservingResults(); search?.onChange = nil; mapSelectionRequest?.cancel(); map.delegate = nil
        avoidBoundaryTimer?.invalidate(); avoidBoundaryTimer = nil; destinationSync.cancel(); destinationSync.onDestination = nil; destinationSync.onRequest = nil; stationStore.cancel(); _ = powerDiagnostic.stop(reason: "scene-disconnect"); powerDiagnostic.onChange = nil; publicLayers?.clear(); publicLayers = nil; searchMap.clear(); nativeSensors.teardown(); ridingCamera.teardown(); destinationMini?.teardown(); destinationMini = nil
    }
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        Task { [resources, repository] in await repository?.releaseDisposableCaches(); await resources?.releaseDisposableCaches() }
    }
    func handleIncomingURL(_ url: URL) {
        guard search != nil else { initialURL = url; return }
        switch DeepLinkRouter.payload(from: url) {
        case .destination(let value): queryField.text = value; openSearch(); queryChanged()
        case .googleShare(let raw): resolveGoogleHandoff(raw)
        case .home: break
        }
    }
    private func resolveGoogleHandoff(_ raw: String) {
        if let url = NativeMapsInput.extract(raw), NativeMapsInput.point(from: url) == nil { powerDiagnostic.mark(.networkRequest) }
        handoffGeneration &+= 1; let ticket = handoffGeneration
        handoffTask?.cancel(); phaseLabel.text = "正在解析 Google Maps 分享…"
        handoffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.googleResolver.resolve(raw)
                guard !Task.isCancelled, self.handoffGeneration == ticket else { return }
                let record = DoorSearchRecord(displayName: value.title, lat: value.coordinate.lat, lng: value.coordinate.lng,
                                              address: value.addressText, locationHint: value.targetText,
                                              searchMetadata: value.floor, source: "google-native-resolve")
                self.select(record)
                let notice = value.notice.trimmingCharacters(in: .whitespacesAndNewlines)
                if !notice.isEmpty { self.phaseLabel.text = notice }
            } catch {
                guard !Task.isCancelled, self.handoffGeneration == ticket else { return }
                self.phaseLabel.text = "Google Maps 分享解析失敗：\(error.localizedDescription)"
                self.updateDiagnostic()
            }
        }
    }
    private func updateDiagnostic() {
        guard testMode else { return }
        func webCount(_ root: UIView) -> Int { (String(describing: type(of: root)).contains("WKWebView") ? 1 : 0) + root.subviews.reduce(0) { $0 + webCount($1) } }
        let points = search?.presentation.pins ?? [], q = search?.query ?? ""
        var data: [String: Any] = ["phase": "S8_NATIVE_NAVIGATION_NO_IPA", "ui": "UIKit", "wkViews": webCount(view),
            "localCount": publicCounts?.local ?? 0, "communityCount": publicCounts?.community ?? 0,
            "query": q, "busy": search?.busy ?? false, "candidateCount": search?.presentation.candidates.count ?? 0,
            "listCount": search?.presentation.list.count ?? 0, "pageCount": search?.page.count ?? 0, "pinCount": points.count,
            "maxPinMeters": points.compactMap(\.distanceM).max() ?? 0, "mapResultsMode": mapResultsMode,
            "renderedAnnotationCount": searchMap.stats.renderedAnnotations, "renderedMemberCount": searchMap.stats.renderedMembers,
            "offscreenPinCount": searchMap.stats.offscreen, "unprojectablePinCount": searchMap.stats.unprojectable,
            "accountedPinCount": searchMap.stats.renderedMembers + searchMap.stats.offscreen + searchMap.stats.unprojectable,
            "mapRenderMaximumMillis": searchMap.stats.maximumMillis, "mapRenderPasses": searchMap.stats.renderCount,
            "destination": navigationState.destination?.title ?? "", "destinationRevision": navigationState.destinationRevision,
            "source": "SIMULATED_MAP_CENTER_NO_SENSOR_OR_ROUTE", "searchTop": searchPanel.frame.minY,
            "safeTop": view.safeAreaInsets.top, "width": view.bounds.width, "height": view.bounds.height,
            "areaAvailable": !areaButton.isHidden, "searchEntry": "single-native-coordinator",
            "routePlanning": routePlanning, "routeCandidateCount": plannedRoutes.count, "routeSelectedIndex": selectedRouteIndex,
            "autoRerouteCount": autoRerouteCount, "lastRerouteReason": lastRerouteReason,
            "rerouteDeviationCount": reroutePolicy.deviationCount, "rerouteHeadingMismatchCount": reroutePolicy.headingMismatchCount,
            "viaCount": viaPoints.count, "avoidAreaCount": avoidAreas.count, "routeEditorActive": routeEditor.active,
            "routeEditorViaCount": routeEditor.current?.via.count ?? 0, "routeEditorReady": routeEditor.ready,
            "routePreviewVisible": routePreviewLine != nil, "avoidOverlayCount": avoidOverlays.count,
            "routeMemoryCount": routeMemories.count, "routeMemoryEnabled": nativePreferences.memoryEnabled,
            "navigationHUDVisible": !navigationHUD.isHidden, "appearance": nativePreferences.appearance.rawValue,
            "stationsEnabled": nativePreferences.stations, "stationCount": stationAnnotations.count,
            "routeVisible": nativePreferences.routeVisible, "miniMode": nativePreferences.miniMode.rawValue, "avatarMode": nativePreferences.avatar.rawValue,
            "publicCommunityFeatures": publicLayers?.stats.community ?? 0,
            "publicRoadFeatures": publicLayers?.stats.roads ?? 0,
            "publicBuildingFeatures": publicLayers?.stats.buildings ?? 0,
            "publicDoorplateLabels": publicLayers?.stats.doorplates ?? 0,
            "publicLayerTiles": publicLayers?.stats.tiles ?? 0,
            "centerPickerEnabled": centerPickerEnabled,
            "centerPickerCoordinate": centerPickerEnabled ? [currentCenter.lat, currentCenter.lng] : [],
            "powerDiagnosticRunning": powerDiagnostic.active,
            "powerDiagnosticDurationMS": powerDiagnostic.snapshot()?.durationMS ?? 0]
        data.merge(ridingCamera.diagnostics(), uniquingKeysWith: { _, new in new })
        data["sensorInputSimulated"] = nativeSensors.simulated
        data["sensorFixes"] = nativeSensors.acceptedFixes; data["sensorHeadings"] = nativeSensors.acceptedHeadings
        if let mini = destinationMini { data.merge(mini.diagnostics(), uniquingKeysWith: { _, new in new }) }
        if let bytes = try? JSONSerialization.data(withJSONObject: data, options: .sortedKeys) { diagnostic.accessibilityValue = String(data: bytes, encoding: .utf8) }
    }
    deinit { if let inputObservation { NotificationCenter.default.removeObserver(inputObservation) } }
}

final class NativeViaAnnotation: NSObject, MKAnnotation {
    let index: Int
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(index: Int, coordinate: CLLocationCoordinate2D) { self.index = index; self.coordinate = coordinate; super.init() }
}

final class NativeSearchAnnotation: NSObject, MKAnnotation {
    let result: DoorSearchCore.Result
    let coordinate: CLLocationCoordinate2D
    var title: String? { result.record.displayName }
    init(result: DoorSearchCore.Result) { self.result = result; coordinate = .init(latitude: result.record.lat, longitude: result.record.lng); super.init() }
}
final class NativeSearchDotView: MKAnnotationView {
    private let dot = UIView(), label = UILabel()
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame.size = CGSize(width: 140, height: 48); centerOffset = CGPoint(x: 0, y: 16)
        dot.frame = CGRect(x: 63, y: 1, width: 14, height: 14); dot.layer.cornerRadius = 7
        dot.backgroundColor = UIColor(red: 0.90, green: 0.36, blue: 0.28, alpha: 1); dot.layer.borderWidth = 2; dot.layer.borderColor = UIColor.white.cgColor
        label.frame = CGRect(x: 0, y: 19, width: 140, height: 29); label.numberOfLines = 2; label.textAlignment = .center
        label.font = .systemFont(ofSize: 11); label.textColor = .white; label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 1; label.layer.shadowRadius = 2; label.layer.shadowOffset = .zero
        addSubview(dot); addSubview(label); clusteringIdentifier = nil; collisionMode = .rectangle; canShowCallout = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func configure(_ item: NativeSearchAnnotation) {
        let r = item.result.record; label.text = r.displayName + "\n" + (r.branch.isEmpty ? r.address : r.branch)
        accessibilityLabel = r.displayName; accessibilityValue = item.result.id; displayPriority = .defaultHigh
    }
}
