import UIKit

/// A real native operation screen. Bundled availability, installed receipt and
/// network updates are explicitly different states. No WK/HTTP/IDB installation.
@MainActor final class NativeOfflineViewController: UIViewController {
    private let resources: NativePublicResources
    private let summary = UILabel(), detail = UILabel(), progress = UIProgressView(progressViewStyle: .default)
    private let install = UIButton(type: .system), download = UIButton(type: .system), remove = UIButton(type: .system), cancel = UIButton(type: .system), verify = UIButton(type: .system)
    private var operation: Task<Void, Never>?
    private var generation: UInt64 = 0
    private(set) var installedReceipt: DoorOfflineReceipt?
    private(set) var running = false
    init(resources: NativePublicResources) { self.resources = resources; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "離線資料"; view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "native-offline-screen"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(close))
        summary.font = .systemFont(ofSize: 18, weight: .semibold); summary.numberOfLines = 0
        summary.accessibilityIdentifier = "native-offline-summary"
        detail.numberOfLines = 0; detail.font = .systemFont(ofSize: 14); detail.textColor = .secondaryLabel
        detail.accessibilityIdentifier = "native-offline-detail"
        progress.accessibilityIdentifier = "native-offline-progress"
        install.setTitle("安裝內建資料", for: .normal); install.accessibilityIdentifier = "native-offline-install"
        download.setTitle("網路下載已核對公開資料", for: .normal); download.accessibilityIdentifier = "native-offline-download"
        remove.setTitle("刪除已安裝副本", for: .normal); remove.accessibilityIdentifier = "native-offline-delete"; remove.tintColor = .systemRed
        cancel.setTitle("取消作業", for: .normal); cancel.accessibilityIdentifier = "native-offline-cancel"
        verify.setTitle("檢查已安裝資料", for: .normal); verify.accessibilityIdentifier = "native-offline-verify"
        install.addTarget(self, action: #selector(beginInstallation), for: .touchUpInside)
        download.addTarget(self, action: #selector(beginDownload), for: .touchUpInside)
        remove.addTarget(self, action: #selector(deleteInstalled), for: .touchUpInside)
        cancel.addTarget(self, action: #selector(cancelInstallation), for: .touchUpInside)
        verify.addTarget(self, action: #selector(verifyInstallation), for: .touchUpInside)
        let notice = UILabel(); notice.numberOfLines = 0; notice.font = .systemFont(ofSize: 13); notice.textColor = .secondaryLabel
        notice.text = "內建的店家、社區與門牌可由 App 直接讀取。內建安裝不算下載；網路下載只使用目前既有 Door Map 正式站，下載後同時核對原始內容 SHA256 與 deterministic gzip SHA256，全部必要元件成功才切換。App 專用索引沿用包內已核版本。Apple 底圖、Apple 即時搜尋、NLSC 圖磚與重新規劃路線的離線能力另計。"
        let stack = UIStackView(arrangedSubviews: [summary, detail, progress, install, download, remove, cancel, verify, notice])
        stack.axis = .vertical; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)])
        for button in [install, download, remove, cancel, verify] { button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true }
        summary.text = "讀取本機狀態…"; applyRunning(false)
        Task { [weak self] in await self?.refreshReceipt() }
    }
    private func applyRunning(_ value: Bool) {
        running = value; install.isEnabled = !value; download.isEnabled = !value; remove.isEnabled = !value; verify.isEnabled = !value; cancel.isEnabled = value
        cancel.isHidden = !value; isModalInPresentation = value
        navigationItem.rightBarButtonItem?.isEnabled = !value
    }
    private func refreshReceipt() async {
        do {
            installedReceipt = try await resources.receipt()
            if let receipt = installedReceipt {
                summary.text = "已安裝 · \(receipt.fileCount) 個資料檔"
                let source = receipt.origin == "validated-download" ? "網路下載後雙重 hash 校驗" : "內建資料安裝"
                detail.text = "資料版本 \(receipt.version)\n來源：\(source)；收據已讀取，完整檢查請按下方按鈕。"
            } else {
                summary.text = "內建資料可用 · 尚未建立安裝副本"
                detail.text = "搜尋仍可直接讀取內建資料；安裝狀態與資料是否存在分開顯示。"
            }
        } catch { summary.text = "本機收據無法確認"; detail.text = error.localizedDescription }
    }
    @objc private func beginInstallation() {
        guard !running else { return }
        generation &+= 1; let expected = generation
        applyRunning(true); summary.text = "安裝與驗證中…"; detail.text = "全部必要資料驗證成功後才切換。"; progress.progress = 0
        let resources = self.resources
        operation = Task { [weak self] in
            do {
                let receipt = try await resources.installBundledSeed { [weak self] status in
                    // Do not create thousands of main-queue tasks for the 3,122 files.
                    guard status.completed % 32 == 0 || status.phase == .committing else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == expected, self.running else { return }
                        self.progress.progress = Float(status.completed) / Float(max(1, status.total))
                        self.detail.text = "\(status.completed) / \(status.total) 個資料檔 · \(status.phase == .committing ? "完成校驗，切換版本" : "逐檔驗證")"
                    }
                }
                guard let self, self.generation == expected else { return }
                self.installedReceipt = receipt; self.progress.progress = 1
                self.summary.text = "已安裝 · \(receipt.fileCount) 個資料檔"
                self.detail.text = "全部必要資料已校驗並完成原生版本切換。\n可關閉 App 後再驗證；未下載 Apple 或 NLSC 圖磚。"
                self.applyRunning(false); self.operation = nil
            } catch {
                guard let self, self.generation == expected else { return }
                self.applyRunning(false); self.operation = nil
                self.summary.text = (error as? DoorOfflineError) == .cancelled || error is CancellationError ? "已取消，未切換版本" : "安裝未完成，未切換版本"
                self.detail.text = "先前可用資料保留；已驗證的暫存檔下次可接續。\n\(error.localizedDescription)"
            }
        }
    }
    @objc private func beginDownload() {
        guard !running else { return }
        generation &+= 1; let expected = generation
        applyRunning(true); summary.text = "下載與驗證中…"
        detail.text = "只用既有 Door Map 正式站；原始 JSON 與重建 gzip 兩層 SHA256 都正確才切換。"; progress.progress = 0
        let resources = self.resources
        operation = Task { [weak self] in
            do {
                let receipt = try await resources.installValidatedNetworkSeed { [weak self] status in
                    guard status.completed % 16 == 0 || status.phase == .committing else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == expected, self.running else { return }
                        self.progress.progress = Float(status.completed) / Float(max(1, status.total))
                        self.detail.text = "\(status.completed) / \(status.total) 個資料檔 · \(status.phase == .committing ? "全部校驗完成，切換版本" : "下載／校驗／建立本機包")"
                    }
                }
                guard let self, self.generation == expected else { return }
                self.installedReceipt = receipt; self.progress.progress = 1
                self.summary.text = "下載完成 · \(receipt.fileCount) 個資料檔"
                self.detail.text = "已核對全部必要元件並原子切換；Apple 底圖與 NLSC 圖磚不在這個離線包內。"
                self.applyRunning(false); self.operation = nil
            } catch {
                guard let self, self.generation == expected else { return }
                self.applyRunning(false); self.operation = nil
                self.summary.text = (error as? DoorOfflineError) == .cancelled || error is CancellationError ? "下載已取消，舊版保留" : "下載未完成，舊版保留"
                self.detail.text = error.localizedDescription
            }
        }
    }

    @objc private func deleteInstalled() {
        guard !running else { return }
        generation &+= 1; let expected = generation
        applyRunning(true); cancel.isHidden = true
        summary.text = "正在刪除安裝副本…"; detail.text = "App 內建資料不會刪除。"
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.resources.removeInstalledCopy()
                guard self.generation == expected else { return }
                self.installedReceipt = nil; self.progress.progress = 0
                self.summary.text = "已刪除安裝副本 · 內建資料仍可用"
                self.detail.text = "搜尋、社區與門牌可回退直接讀 App 內建已核資料。"
            } catch {
                guard self.generation == expected else { return }
                self.summary.text = "刪除未完成"; self.detail.text = error.localizedDescription
            }
            self.applyRunning(false); self.operation = nil
        }
    }

    @objc private func cancelInstallation() {
        guard running else { return }; cancel.isEnabled = false
        operation?.cancel()
        Task { [resources] in await resources.cancelInstallation() }
        // Keep the operation owner until its completion/cancellation handler returns.
    }
    @objc private func verifyInstallation() {
        guard !running else { return }; applyRunning(true); cancel.isHidden = true
        summary.text = "完整檢查本機檔案…"
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await self.resources.verifyInstalled()
                self.installedReceipt = receipt
                self.summary.text = receipt == nil ? "尚未安裝副本，內建資料仍可用" : "檢查通過 · \(receipt!.fileCount) 個資料檔"
                self.detail.text = receipt == nil ? "沒有把內建資料誤報為安裝完成。" : "已核對實際檔案、大小、SHA256、所有必要資料與目前版本收據。"
            } catch { self.summary.text = "資料檢查失敗"; self.detail.text = error.localizedDescription }
            self.applyRunning(false); self.operation = nil
        }
    }
    @objc private func close() { guard !running else { return }; dismiss(animated: true) }
    deinit { operation?.cancel() }
}
