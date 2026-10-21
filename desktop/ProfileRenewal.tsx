import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";

type Profile = { bundle: string; expires: string };
type Preview = { status: string; profiles: Profile[]; mode: string };
type Applied = {
  status: string; updated: Profile[]; reinstalledIpa: boolean;
  oldProfilesRemoved: boolean; postExpirationLaunchVerified: boolean
};

export function ProfileRenewal({
  connected, signedIn, connectionType,
}: { connected: boolean; signedIn: boolean; connectionType: string | null }) {
  const [preview, setPreview] = useState<Preview | null>(null);
  const [busy, setBusy] = useState(false);
  const [outcome, setOutcome] = useState("");
  const enabled = connected && connectionType === "Network";
  const errorText = (e: unknown) => {
    if (typeof e === "object" && e !== null && "message" in e) {
      return String((e as { message: unknown }).message);
    }
    return String(e);
  };

  const readOnly = async () => {
    setBusy(true); setPreview(null); setOutcome("");
    try {
      const result = await invoke<Preview>("preview_lcss_profile_renewal");
      setPreview(result);
      setOutcome("僅讀取到期日；尚未執行續簽。");
    } catch (e) {
      setOutcome("讀取失敗：" + errorText(e));
    } finally { setBusy(false); }
  };

  const apply = async () => {
    if (!preview || preview.profiles.length !== 4 || !signedIn || !enabled) return;
    if (!window.confirm(
      "僅更新這 4 個 LiveContainer 簽名描述檔，不重新安裝 IPA、不撤銷憑證、" +
      "不刪除舊描述檔。這是尚未在 iOS 27 完整驗收的實驗功能。確定執行？"
    )) return;

    setBusy(true); setOutcome("");
    try {
      const result = await invoke<Applied>("renew_lcss_profiles_via_wifi");
      setPreview({
        status: result.status,
        profiles: result.updated,
        mode: "iLoader Network → Misagent",
      });
      setOutcome(
        "已讀回 iPhone 上的新描述檔及到期日；" +
        "但『原始描述檔到期後 App 仍可開啟』尚未驗證。"
      );
    } catch (e) {
      setOutcome("未完成續簽：" + errorText(e));
    } finally { setBusy(false); }
  };

  return (
    <section aria-label="LC+SS 電腦 Wi-Fi 續簽測試">
      <h3>LC+SS Wi-Fi 描述檔續簽（實驗）</h3>
      <p>
        使用已選取的 iLoader Network 裝置；不使用 SideStore 手機端的 VPN／
        Remote Pairing。只允許主程式和三個擴充元件，核對 Apple Team、Bundle ID、
        裝置授權、原簽名憑證與 Entitlements 後才安裝。
      </p>
      <div className="action-row">
        <button disabled={busy || !enabled} onClick={readOnly}>
          {busy ? "處理中" : "先唯讀檢查 4 個描述檔"}
        </button>
        <button
          disabled={busy || !enabled || !signedIn ||
                    !preview || preview.profiles.length !== 4}
          onClick={apply}
        >
          手動試行 Wi-Fi 續簽
        </button>
      </div>
      {!enabled && <p>請在 iLoader 選取已配對的 Network iPhone。</p>}
      {preview && (
        <div>
          <p>{preview.status}（{preview.mode}）</p>
          <ul>{preview.profiles.map(p =>
            <li key={p.bundle}>{p.bundle} — {p.expires}</li>
          )}</ul>
        </div>
      )}
      {outcome && <p role="status">{outcome}</p>}
      <p>未實機驗證前不可把成功讀回描述檔當作完整七天續簽成功。</p>
    </section>
  );
}
