import UIKit

final class MapSettingsViewController: UITableViewController {
    var preferences: MapPreferences
    var onChange: ((MapPreferences) -> Void)?
    var onAction: ((String) -> Void)?
    var cameraStatus: (() -> String)?
    var stationStatus = ""
    var hasApplePlace = false

    init(_ preferences: MapPreferences) { self.preferences = preferences; super.init(style: .insetGrouped) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "更多地圖設定"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(close))
        tableView.accessibilityIdentifier = "map-settings"
        tableView.rowHeight = 52
    }
    @objc private func close() { dismiss(animated: true) }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); tableView.reloadData() }
    private func emit() { preferences.sanitize(); preferences.save(); onChange?(preferences) }
    override func numberOfSections(in tableView: UITableView) -> Int { 7 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { [3,3,2,7,1,3,3][section] }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["外觀", "Apple 商家", "路況與建物", "視角與手勢", "門牌小地圖", "Gogoro 交換站", "目的地與其他"][section]
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return preferences.muted ? "淡化底圖會降低道路與文字強調；Apple 仍依倍率決定商家密度。" : nil
        case 1: return "控制 Apple 主圖顯示類別；商家資訊不傳到 NLSC 門牌圖。"
        case 2: return "建物細節依 Apple 圖資及倍率顯示；機車路由與立體呈現分開。"
        case 3: return (cameraStatus?() ?? "") + "\nApple 依倍率限制傾角，實際以畫面為準。手勢角度會保存；定位與全程保留選定傾角。"
        case 4: return "展開後拖動門牌圖，把準星對準位置，再按「定位修正」。收合或關閉不套用未確認的移動。"
        case 5: return stationStatus.isEmpty ? "位置與名稱，不查即時電池量。開啟後沿用原版站點資料；未更新時顯示已保存位置。" : stationStatus
        case 6: return "581 Apple 測試 · 0.3.0 (7)\nFIT、PiP、多站、避開區與路線編輯已接回現行 3.78 規則。Apple 建物輪廓呈現仍依圖資與 SDK。"
        default: return nil
        }
    }
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.section == 0 || indexPath.section == 4 || (indexPath.section == 3 && indexPath.row < 3) { return 78 }
        return 52
    }
    private func cell(_ title: String, id: String) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = title; cell.textLabel?.font = .systemFont(ofSize: 15)
        cell.accessibilityIdentifier = id; cell.selectionStyle = .none
        return cell
    }
    private func toggle(_ title: String, id: String, value: Bool, action: @escaping (Bool) -> Void) -> UITableViewCell {
        let cell = self.cell(title, id: "row-" + id)
        let control = ActionSwitch(); control.isOn = value; control.accessibilityIdentifier = id
        control.changed = action; cell.accessoryView = control
        return cell
    }
    private func segments(_ title: String, id: String, items: [String], selected: Int, action: @escaping (Int) -> Void) -> UITableViewCell {
        let cell = self.cell("", id: "row-" + id)
        let label = UILabel(); label.text = title; label.font = .systemFont(ofSize: 12, weight: .medium); label.textColor = .secondaryLabel
        let control = ActionSegments(items: items); control.selectedSegmentIndex = selected
        control.accessibilityIdentifier = id; control.changed = action
        let stack = UIStackView(arrangedSubviews: [label, control]); stack.axis = .vertical; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor)])
        return cell
    }
    private func slider(_ title: String, id: String, value: Float, range: ClosedRange<Float>, action: @escaping (Float) -> Void) -> UITableViewCell {
        let cell = self.cell("", id: "row-" + id)
        let label = UILabel(); label.text = title; label.font = .systemFont(ofSize: 12, weight: .medium); label.textColor = .secondaryLabel
        let control = ActionSlider(); control.minimumValue = range.lowerBound; control.maximumValue = range.upperBound
        control.value = value; control.accessibilityIdentifier = id
        control.changed = { v in action(v) }
        let stack = UIStackView(arrangedSubviews: [label, control]); stack.axis = .vertical; stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false; cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor)])
        return cell
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch (indexPath.section, indexPath.row) {
        case (0,0): return segments("配色", id: "appearance", items: ["深色","淺色","跟隨系統"], selected: MapAppearance.allCases.firstIndex(of: preferences.appearance) ?? 0) { [weak self] n in guard let self else { return }; self.preferences.appearance = MapAppearance.allCases[n]; self.emit() }
        case (0,1): return segments("底圖風格", id: "emphasis", items: ["一般","淡化"], selected: preferences.muted ? 1 : 0) { [weak self] n in self?.preferences.muted = n == 1; self?.emit() }
        case (0,2): return segments("導航角色", id: "avatar-mode", items: ["經典","悟空","魯夫"], selected: RiderAvatarMode.allCases.firstIndex(of: preferences.avatar) ?? 0) { [weak self] n in guard let self else { return }; self.preferences.avatarMode = RiderAvatarMode.allCases[n]; self.emit() }
        case (1,0): return toggle("顯示 Apple 商家", id: "setting-poi", value: preferences.showsPOI) { [weak self] v in self?.preferences.showsPOI = v; self?.emit() }
        case (1,1): return toggle("全部類別", id: "setting-all-poi", value: preferences.allPOI) { [weak self] v in self?.preferences.allPOI = v; self?.emit() }
        case (1,2): let c = cell("選擇商家類別", id: "poi-categories"); c.accessoryType = .disclosureIndicator; c.selectionStyle = .default; return c
        case (2,0): return toggle("顯示路況", id: "setting-traffic", value: preferences.traffic) { [weak self] v in self?.preferences.traffic = v; self?.emit() }
        case (2,1): return toggle("顯示立體建物", id: "setting-buildings", value: preferences.buildings) { [weak self] v in self?.preferences.buildings = v; self?.emit() }
        case (3,0): return slider("俯視傾角 · \(Int(preferences.pitch))°", id: "camera-pitch", value: Float(preferences.pitch), range: 0...70) { [weak self] v in self?.preferences.pitch = Double(v); self?.emit() }
        case (3,1): return slider("縮放 · 近 ↔ 遠", id: "camera-distance", value: Float(log10(preferences.distance)), range: Float(log10(80.0))...Float(log10(80000.0))) { [weak self] v in self?.preferences.distance = pow(10, Double(v)); self?.emit() }
        case (3,2): return slider("旋轉方向 · \(Int(preferences.heading))°", id: "camera-heading", value: Float(preferences.heading), range: 0...359) { [weak self] v in self?.preferences.heading = Double(v); self?.preferences.followHeading = false; self?.emit() }
        case (3,3): return toggle("允許縮放手勢", id: "setting-zoom", value: preferences.zoomGestures) { [weak self] v in self?.preferences.zoomGestures = v; self?.emit() }
        case (3,4): return toggle("允許旋轉手勢", id: "setting-rotation", value: preferences.rotateGestures) { [weak self] v in self?.preferences.rotateGestures = v; self?.emit() }
        case (3,5): return toggle("允許傾斜手勢", id: "setting-pitch-gesture", value: preferences.pitchGestures) { [weak self] v in self?.preferences.pitchGestures = v; self?.emit() }
        case (3,6): return toggle("跟隨時朝向前方", id: "setting-follow-heading", value: preferences.followHeading) { [weak self] v in self?.preferences.followHeading = v; self?.emit() }
        case (4,0): return segments("門牌小地圖", id: "mini-mode", items: ["關閉","收合","展開"], selected: MiniMapMode.allCases.firstIndex(of: preferences.miniMode) ?? 1) { [weak self] n in self?.preferences.miniMode = MiniMapMode.allCases[n]; self?.emit() }
        case (5,0): return toggle("Gogoro 交換站", id: "setting-stations", value: preferences.stations) { [weak self] v in self?.preferences.stations = v; self?.emit() }
        case (5,1): let c = cell("更新站點位置", id: "refresh-stations"); c.selectionStyle = .default; c.textLabel?.textColor = .systemGreen; return c
        case (5,2): return toggle("顯示導航路線", id: "setting-route-visible", value: preferences.routeVisible) { [weak self] v in self?.preferences.routeVisible = v; self?.emit() }
        case (6,0): let c = cell("商家資訊", id: "place-details"); c.selectionStyle = .default; c.textLabel?.textColor = hasApplePlace ? .label : .secondaryLabel; return c
        case (6,1): let c = cell("清除目的地", id: "clear-destination"); c.selectionStyle = .default; c.textLabel?.textColor = .systemRed; return c
        default: let c = cell("開啟正式 Door Map", id: "open-production"); c.selectionStyle = .default; return c
        }
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.section == 1 && indexPath.row == 2 {
            let picker = POICategoryViewController(preferences)
            picker.onChange = { [weak self] v in self?.preferences = v; self?.emit() }
            navigationController?.pushViewController(picker, animated: true)
        } else if indexPath.section == 5 && indexPath.row == 1 { onAction?("refresh-stations") }
        else if indexPath.section == 6 {
            let action = ["place-details","clear-destination","open-production"][indexPath.row]
            if action == "place-details" && !hasApplePlace { return }
            dismiss(animated: true) { [weak self] in self?.onAction?(action) }
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

private final class POICategoryViewController: UITableViewController {
    var preferences: MapPreferences
    var onChange: ((MapPreferences) -> Void)?
    init(_ value: MapPreferences) { preferences = value; super.init(style: .insetGrouped) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); title = "商家類別"; tableView.accessibilityIdentifier = "poi-category-list" }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { NativePOICategory.options.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let option = NativePOICategory.options[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil); cell.textLabel?.text = option.title
        let control = ActionSwitch(); control.accessibilityIdentifier = "poi-" + option.id
        control.isOn = preferences.allPOI || preferences.poiCategories.contains(option.id)
        control.changed = { [weak self] on in
            guard let self else { return }
            if self.preferences.allPOI { self.preferences.poiCategories = NativePOICategory.options.map(\.id) }
            self.preferences.allPOI = false
            self.preferences.poiCategories.removeAll { $0 == option.id }
            if on { self.preferences.poiCategories.append(option.id) }
            self.preferences.save(); self.onChange?(self.preferences)
        }
        cell.accessoryView = control; cell.selectionStyle = .none; return cell
    }
}

private final class ActionSwitch: UISwitch {
    var changed: ((Bool) -> Void)?
    override init(frame: CGRect) { super.init(frame: frame); addTarget(self, action: #selector(update), for: .valueChanged) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    @objc private func update() { changed?(isOn) }
}
private final class ActionSegments: UISegmentedControl {
    var changed: ((Int) -> Void)?
    override init(items: [Any]?) { super.init(items: items); addTarget(self, action: #selector(update), for: .valueChanged) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    @objc private func update() { changed?(selectedSegmentIndex) }
}
private final class ActionSlider: UISlider {
    var changed: ((Float) -> Void)?
    override init(frame: CGRect) { super.init(frame: frame); addTarget(self, action: #selector(update), for: [.valueChanged, .touchUpInside]) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    @objc private func update() { changed?(value) }
}
