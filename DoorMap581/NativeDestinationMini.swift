import CoreLocation
import MapKit
import UIKit

/// Native NLSC correction surface. It never contains a WebView, copies Apple
/// map items/labels, or commits a correction before an explicit Apply gesture.
@MainActor final class NativeDestinationMini: UIView, MKMapViewDelegate {
    private let map = MKMapView()
    private let handle = UIButton(type: .system), correct = UIButton(type: .system)
    private let apply = UIButton(type: .system), cancel = UIButton(type: .system), recenter = UIButton(type: .system)
    private let attribution = UILabel(), reticle = UILabel(), status = UILabel()
    private let raster: NativeMiniRaster
    private var pin: NativeCorrectionAnnotation?
    private var target: DoorNavigationState.Destination?
    private var revision: UInt64 = 0
    private var draft: DoorCoordinate?
    private var viewportCenter: DoorCoordinate?
    private var savedCenter: DoorCoordinate?
    private var savedZoom = 19.5
    private var needsInitialCamera = false
    private var applyingCamera = false
    private var appActive = true
    private var manualDraft = false
    private var contacts: NativeContactObserver?
    private var userMapMoved = false
    private let gestureCoexistence = NativeMiniGestureDelegate()
    private(set) var expanded = false
    private(set) var correcting = false
    private(set) var mainOnlySource = false
    private(set) var lastCommitSucceeded = false
    private var lastMapSize = CGSize.zero
    var onExpansion: ((Bool) -> Void)?
    var onCorrectionMode: ((Bool) -> Void)?
    var onApply: ((DoorCoordinate, UInt64) -> Bool)?
    var onChange: (() -> Void)?

    init(simulated: Bool) {
        let image: Data?
        if simulated {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            image = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).pngData { context in
                UIColor(white: 0.90, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
                UIColor.darkGray.setStroke(); context.cgContext.setLineWidth(2)
                for x in stride(from: 0, through: 256, by: 64) { context.cgContext.move(to: CGPoint(x: x, y: 0)); context.cgContext.addLine(to: CGPoint(x: x, y: 256)) }
                context.cgContext.strokePath()
                ("測試圖磚\n非官方門牌" as NSString).draw(at: CGPoint(x: 20, y: 90), withAttributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.black])
            }
        } else { image = nil }
        raster = NativeMiniRaster(fixture: image)
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.07, alpha: 0.97); layer.cornerRadius = 18; clipsToBounds = true
        layer.borderWidth = 1; layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        accessibilityIdentifier = "native-destination-mini"
        map.delegate = self; map.accessibilityIdentifier = "native-nlsc-map"
        map.showsUserLocation = false; map.showsBuildings = false; map.showsTraffic = false; map.showsCompass = false
        map.isRotateEnabled = false; map.isPitchEnabled = false
        map.selectableMapFeatures = []
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
        configuration.pointOfInterestFilter = .excludingAll; map.preferredConfiguration = configuration
        map.addOverlay(raster, level: .aboveLabels); addSubview(map)
        let contacts = NativeContactObserver(target: nil, action: nil)
        contacts.cancelsTouchesInView = false; contacts.delegate = gestureCoexistence
        contacts.onContact = { [weak self] phase, _, _ in
            if phase == "move" { self?.userMapMoved = true }
        }
        self.contacts = contacts; map.addGestureRecognizer(contacts)
        map.isHidden = true; raster.setActive(false)
        handle.setTitle("未設定目的地  ⌃", for: .normal); handle.contentHorizontalAlignment = .left
        handle.titleLabel?.font = .systemFont(ofSize: 23, weight: .heavy); handle.tintColor = .white
        handle.titleLabel?.lineBreakMode = .byTruncatingTail; handle.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        handle.accessibilityIdentifier = "native-mini-toggle"; handle.addTarget(self, action: #selector(toggle), for: .touchUpInside); addSubview(handle)
        for (button, title, identifier, action) in [
            (correct, "修正 PIN", "native-mini-correct", #selector(beginCorrection)),
            (apply, "套用修正", "native-mini-apply", #selector(applyCorrection)),
            (cancel, "取消", "native-mini-cancel", #selector(cancelCorrection)),
            (recenter, "⌖", "native-mini-recenter", #selector(recenterTarget))] {
            button.setTitle(title, for: .normal); button.tintColor = .white
            button.backgroundColor = UIColor(white: 0.08, alpha: 0.95); button.layer.cornerRadius = 12
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            button.accessibilityIdentifier = identifier; button.addTarget(self, action: action, for: .touchUpInside); addSubview(button)
        }
        reticle.text = "+"; reticle.font = .systemFont(ofSize: 38, weight: .light); reticle.textColor = .systemRed
        reticle.textAlignment = .center; reticle.isUserInteractionEnabled = false; reticle.isHidden = true
        reticle.accessibilityIdentifier = "native-mini-reticle"; addSubview(reticle)
        attribution.text = simulated ? "模擬圖磚 · 僅驗原生手勢／尺度，非門牌驗收" : "內政部國土測繪中心 · 臺灣通用電子地圖"
        attribution.textColor = .white; attribution.backgroundColor = UIColor(white: 0.08, alpha: 0.90)
        attribution.font = .systemFont(ofSize: 9); attribution.textAlignment = .center; addSubview(attribution)
        status.textColor = .white; status.font = .systemFont(ofSize: 11); status.numberOfLines = 2
        status.backgroundColor = UIColor(white: 0.08, alpha: 0.90); addSubview(status)
        raster.onFailure = { [weak self] in self?.status.text = "國土測繪圖磚暫不可用；不可當門牌已驗證" }
        updateVisibility()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func setTarget(_ value: DoorNavigationState.Destination?, revision: UInt64, viewportCenter: DoorCoordinate?) {
        guard revision != self.revision || value != target else { return }
        target = value; self.revision = revision; self.viewportCenter = viewportCenter
        mainOnlySource = value?.source.hasPrefix("apple") == true
        savedCenter = mainOnlySource ? viewportCenter : value?.coordinate; savedZoom = 19.5
        draft = nil; correcting = false; manualDraft = false; lastCommitSucceeded = false; needsInitialCamera = true
        // Apple map-item identity/pin never appears on a non-Apple map.
        if let pin { map.removeAnnotation(pin) }; pin = nil
        if !mainOnlySource, let value { setPin(value.coordinate) }
        updateTitle(); updateVisibility(); setNeedsLayout(); onCorrectionMode?(false)
    }
    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        if !value { saveCamera() }
        expanded = value
        if value { needsInitialCamera = true }
        raster.setActive(value && appActive); updateVisibility()
        if value { (map.renderer(for: raster) as? MKTileOverlayRenderer)?.reloadData() }
        onExpansion?(value); setNeedsLayout(); onChange?()
    }
    @objc private func toggle() { setExpanded(!expanded) }
    override func layoutSubviews() {
        super.layoutSubviews()
        let nextSize = CGSize(width: bounds.width, height: max(1, bounds.height - 56))
        if expanded && lastMapSize != .zero && nextSize != lastMapSize {
            saveCamera(); needsInitialCamera = true
        }
        lastMapSize = nextSize
        handle.frame = CGRect(x: 0, y: max(0, bounds.height - 56), width: bounds.width, height: 56)
        map.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(1, bounds.height - 56))
        correct.frame = CGRect(x: max(8, bounds.width - 98), y: 10, width: 88, height: 46)
        apply.frame = CGRect(x: max(8, bounds.width - 110), y: 10, width: 100, height: 46)
        cancel.frame = CGRect(x: max(8, bounds.width - 184), y: 10, width: 66, height: 46)
        recenter.frame = CGRect(x: 10, y: 10, width: 46, height: 46)
        reticle.frame = CGRect(x: map.bounds.midX - 22, y: map.bounds.midY - 22, width: 44, height: 44)
        attribution.frame = CGRect(x: 0, y: map.frame.maxY - 20, width: bounds.width, height: 20)
        status.frame = CGRect(x: 8, y: 62, width: max(1, bounds.width - 16), height: status.text?.isEmpty == false ? 32 : 0)
        if expanded && needsInitialCamera, let center = savedCenter ?? viewportCenter, center.isValid, map.bounds.height > 100 {
            applyingCamera = true
            _ = NativeCameraAdapter.apply(["center": ["lat": center.lat, "lng": center.lng], "zoom": savedZoom, "pitch": 0.0, "bearing": 0.0], to: map)
            applyingCamera = false; needsInitialCamera = false
            map.isHidden = false // First reveal only after close-up scale is applied.
            onChange?()
        }
    }
    private func updateVisibility() {
        map.isHidden = !expanded || needsInitialCamera
        correct.isHidden = !expanded || correcting; correct.isEnabled = target != nil
        apply.isHidden = !expanded || !correcting; apply.isEnabled = manualDraft
        cancel.isHidden = !expanded || !correcting; recenter.isHidden = !expanded
        reticle.isHidden = !expanded || !correcting
        attribution.isHidden = !expanded; status.isHidden = !expanded
        if let pin { map.view(for: pin)?.isDraggable = correcting }
        updateTitle()
    }
    private func updateTitle() {
        let title = mainOnlySource ? "手動修正位置" : (target?.title ?? "未設定目的地")
        handle.setTitle(title + (expanded ? "  ⌄" : "  ⌃"), for: .normal)
    }
    private func setPin(_ coordinate: DoorCoordinate) {
        if let pin { pin.coordinate = .init(latitude: coordinate.lat, longitude: coordinate.lng) }
        else { let p = NativeCorrectionAnnotation(coordinate: .init(latitude: coordinate.lat, longitude: coordinate.lng)); pin = p; map.addAnnotation(p) }
    }
    private func saveCamera() {
        guard expanded && !needsInitialCamera else { return }
        let c = map.camera.centerCoordinate; savedCenter = .init(lat: c.latitude, lng: c.longitude)
        let z = NativeCameraAdapter.measuredZoom(map); if z.isFinite { savedZoom = max(12, min(21, z)) }
    }
    @objc private func beginCorrection() {
        guard target != nil else { return }
        correcting = true; manualDraft = false
        userMapMoved = false; draft = mainOnlySource ? nil : (draft ?? target?.coordinate)
        if !mainOnlySource, let draft { setPin(draft) }
        if mainOnlySource { status.text = "拖移準星後產生手動位置；Apple 商家內容不帶入小地圖" }
        else { status.text = "拖地圖或拖 PIN；按套用才改終點" }
        onCorrectionMode?(true); updateVisibility(); onChange?()
    }
    private func moveDraft(_ value: DoorCoordinate) {
        guard correcting, value.isValid else { return }; draft = value; manualDraft = true
        setPin(value); apply.isEnabled = true; onChange?()
    }
    @objc private func applyCorrection() {
        guard correcting, manualDraft, let draft else { return }
        guard onApply?(draft, revision) == true else { status.text = "修正未套用：目的地已改變或路線交易尚未完成"; lastCommitSucceeded = false; onChange?(); return }
        lastCommitSucceeded = true; correcting = false; manualDraft = false; self.draft = nil
        status.text = "修正已套用"; onCorrectionMode?(false); updateVisibility(); onChange?()
    }
    @objc private func cancelCorrection() {
        correcting = false; manualDraft = false; draft = nil
        if let pin { map.removeAnnotation(pin) }; pin = nil
        if !mainOnlySource, let target { setPin(target.coordinate) }
        status.text = "已取消，原目的地未變"; onCorrectionMode?(false); updateVisibility(); onChange?()
    }
    @objc private func recenterTarget() {
        let point = draft ?? (mainOnlySource ? viewportCenter : target?.coordinate)
        guard let point else { return }; savedCenter = point; needsInitialCamera = true; setNeedsLayout()
    }
    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        guard expanded, !applyingCamera, !needsInitialCamera else { return }
        saveCamera()
        if correcting && userMapMoved {
            userMapMoved = false
            let c = mapView.centerCoordinate
            moveDraft(.init(lat: c.latitude, lng: c.longitude))
        }
        onChange?()
    }
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let tile = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tile) }
        return MKOverlayRenderer(overlay: overlay)
    }
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard annotation === pin else { return nil }
        let view = MKPinAnnotationView(annotation: annotation, reuseIdentifier: "native-correction-pin")
        view.pinTintColor = .red; view.isDraggable = correcting; view.canShowCallout = false; view.displayPriority = .required
        view.accessibilityIdentifier = "native-mini-draft-pin"; return view
    }
    func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
        if newState == .ending, let pin = view.annotation as? NativeCorrectionAnnotation {
            moveDraft(.init(lat: pin.coordinate.latitude, lng: pin.coordinate.longitude)); view.dragState = .none
        } else if newState == .canceling { view.dragState = .none }
    }
    func setActive(_ value: Bool) {
        appActive = value; raster.setActive(value && expanded)
        if value && expanded { (map.renderer(for: raster) as? MKTileOverlayRenderer)?.reloadData() }
    }
    func diagnostics() -> [String: Any] {
        ["miniExpanded": expanded, "miniCorrecting": correcting, "miniDraft": draft.map { [$0.lat, $0.lng] } ?? [],
         "miniZoom": expanded ? NativeCameraAdapter.measuredZoom(map) : savedZoom,
         "miniCommitSucceeded": lastCommitSucceeded, "miniRevision": revision,
         "miniMainOnlySource": mainOnlySource, "miniReplacesAppleBase": raster.canReplaceMapContent,
         "miniMapWidth": Double(map.bounds.width), "miniMapHeight": Double(map.bounds.height),
         "miniTitle": handle.title(for: .normal) ?? "", "miniPublicPinCount": pin == nil ? 0 : 1,
         "miniPitch": Double(map.camera.pitch), "miniBearing": map.camera.heading]
    }
    func teardown() {
        contacts?.onContact = nil; if let contacts { map.removeGestureRecognizer(contacts) }; contacts = nil
        raster.shutdown(); map.delegate = nil; onExpansion = nil; onCorrectionMode = nil; onApply = nil; onChange = nil
    }
}

final class NativeCorrectionAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate; super.init() }
}

private final class NativeMiniGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
