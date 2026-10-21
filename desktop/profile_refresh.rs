//! Experimental iLoader desktop-only provisioning profile renewal.
//!
//! This uses the ALREADY SELECTED usbmuxd Network connection, not a
//! RemotePairing tunnel, VPN, local TCP listener, or unsigned IPA re-install.
//! Requires a signed-in iLoader session and explicit user action.
//! Do not use with a different Team ID or mismatched signing certificate.
//! Its behavior after original embedded.mobileprovision expiry needs device
//! validation; Misagent readback alone is not end-to-end launch proof.

use std::{collections::BTreeMap, io::Cursor};

use idevice::{IdeviceService, misagent::MisagentClient};
use isideload::dev::app_ids::AppIdsApi;
use plist::{Dictionary, Value};
use serde::Serialize;
use tauri::State;
use tracing::{info, warn};

use crate::{
    device::{get_provider, DeviceInfoMutex},
    error::AppError,
    sideload::{SideloaderGuard, SideloaderMutex},
};

const BUNDLE_PREFIX: &str = "com.kdt.livecontainer";
const REQUIRED_COUNT: usize = 4;
const PROFILE_LIMIT: usize = 3 * 1024 * 1024;
const PROFILE_CLOSE: &[u8] = b"</plist>";

fn failure(message: &str) -> AppError {
    AppError::Misc(format!("Profile-only renewal: {message}"))
}

#[derive(Clone)]
struct ProfileMeta {
    bundle: String,
    team: String,
    uuid: String,
    expires: String,
    device_ids: Vec<String>,
    certificates: Vec<Vec<u8>>,
    entitlements: Dictionary,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfilePreview {
    pub bundle: String,
    pub expires: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreviewResult {
    pub status: &'static str,
    pub profiles: Vec<ProfilePreview>,
    pub mode: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RenewalResult {
    pub status: &'static str,
    pub updated: Vec<ProfilePreview>,
    pub reinstalled_ipa: bool,
    pub old_profiles_removed: bool,
    pub post_expiration_launch_verified: bool,
}

fn xml_plist(payload: &[u8]) -> Result<Value, AppError> {
    if payload.is_empty() || payload.len() > PROFILE_LIMIT {
        return Err(failure("invalid profile size"));
    }
    let start = payload.windows(5).position(|w| w == b"<?xml")
        .ok_or_else(|| failure("CMS envelope has no XML plist"))?;
    let end = payload.windows(PROFILE_CLOSE.len())
        .enumerate().skip(start)
        .find(|(_, w)| *w == PROFILE_CLOSE)
        .map(|(i, _)| i + PROFILE_CLOSE.len())
        .ok_or_else(|| failure("CMS envelope has no closing plist"))?;
    Value::from_reader_xml(Cursor::new(&payload[start..end]))
        .map_err(|_| failure("invalid embedded plist"))
}

// This parses metadata ONLY. The iPhone's Misagent service validates the
// actual Apple-signed profile. Metadata parsing is not CMS trust verification.
fn parse_meta(payload: &[u8]) -> Result<ProfileMeta, AppError> {
    let value = xml_plist(payload)?;
    let p = value.as_dictionary().ok_or_else(|| failure("profile is not a dictionary"))?;
    let dict = |name: &str| p.get(name).and_then(Value::as_dictionary);
    let ents = dict("Entitlements").ok_or_else(|| failure("missing entitlements"))?;
    let app = ents.get("application-identifier").and_then(Value::as_string)
        .ok_or_else(|| failure("missing application-identifier"))?;
    let (team, bundle) = app.split_once('.')
        .ok_or_else(|| failure("invalid application-identifier"))?;
    let listed_team = p.get("TeamIdentifier").and_then(Value::as_array)
        .and_then(|a| a.first()).and_then(Value::as_string)
        .ok_or_else(|| failure("TeamIdentifier missing"))?;
    if listed_team != team || team.len() != 10 {
        return Err(failure("profile TeamIdentifier mismatch"));
    }
    let uuid = p.get("UUID").and_then(Value::as_string)
        .ok_or_else(|| failure("missing UUID"))?;
    let expires = p.get("ExpirationDate").and_then(Value::as_date)
        .ok_or_else(|| failure("missing expiration date"))?.to_xml_format();
    let device_ids = p.get("ProvisionedDevices").and_then(Value::as_array)
        .ok_or_else(|| failure("no authorized devices"))?
        .iter().filter_map(Value::as_string).map(str::to_owned).collect::<Vec<_>>();
    let certificates = p.get("DeveloperCertificates").and_then(Value::as_array)
        .ok_or_else(|| failure("no signing certificates"))?
        .iter().filter_map(Value::as_data).map(|b| b.to_vec()).collect::<Vec<_>>();
    if device_ids.is_empty() || certificates.is_empty() {
        return Err(failure("empty device or certificate authorization"));
    }
    Ok(ProfileMeta {
        bundle: bundle.to_string(),
        team: team.to_string(),
        uuid: uuid.to_string(),
        expires,
        device_ids,
        certificates,
        entitlements: ents.clone(),
    })
}

fn is_target(bundle: &str) -> bool {
    bundle == BUNDLE_PREFIX || bundle.starts_with(&format!("{BUNDLE_PREFIX}."))
}

fn kind(bundle: &str) -> &'static str {
    if bundle.ends_with(".LiveProcess") { "process" }
    else if bundle.ends_with(".ShareExtension") { "share" }
    else if bundle.ends_with(".LaunchAppExtension") { "launch" }
    else { "main" }
}

fn prepare_installed(
    raw: &[Vec<u8>],
    device_id: &str,
) -> Result<BTreeMap<String, ProfileMeta>, AppError> {
    let mut existing = BTreeMap::new();
    for item in raw {
        // Other apps may have unrelated profile formats. Skip them, but the
        // mandatory four target profiles must all be present and valid.
        let p = match parse_meta(item) {
            Ok(p) => p,
            Err(_) => continue,
        };
        if !is_target(&p.bundle) || !p.device_ids.iter().any(|id| id == device_id) {
            continue;
        }
        if existing.get(&p.bundle).is_none_or(|current: &ProfileMeta| current.expires < p.expires) {
            existing.insert(p.bundle.clone(), p);
        }
    }
    if existing.len() != REQUIRED_COUNT {
        return Err(failure("expected exactly four installed LiveContainer profiles; no changes made"));
    }
    let mut kinds = existing.values().map(|v| kind(&v.bundle)).collect::<Vec<_>>();
    kinds.sort_unstable();
    if kinds != ["launch", "main", "process", "share"] {
        return Err(failure("LiveContainer extension set is incomplete or unexpected"));
    }
    let teams = existing.values().map(|v| v.team.as_str()).collect::<std::collections::BTreeSet<_>>();
    if teams.len() != 1 {
        return Err(failure("existing LiveContainer profiles have different Apple Teams"));
    }
    Ok(existing)
}

fn validate_new(old: &ProfileMeta, new: &ProfileMeta, device_id: &str) -> Result<(), AppError> {
    if old.team != new.team || old.bundle != new.bundle {
        return Err(failure("new profile changes the team or Bundle ID"));
    }
    if old.entitlements != new.entitlements {
        return Err(failure("new profile changes app entitlements"));
    }
    if !new.device_ids.iter().any(|id| id == device_id) {
        return Err(failure("new profile does not authorize selected iPhone"));
    }
    if !old.certificates.iter().any(|x| new.certificates.contains(x)) {
        return Err(failure("new profile has no certificate in common with installed app"));
    }
    if new.expires <= old.expires {
        return Err(failure("Apple did not issue a profile with a later expiration"));
    }
    Ok(())
}

fn previews(profiles: &BTreeMap<String, ProfileMeta>) -> Vec<ProfilePreview> {
    profiles.values().map(|v| ProfilePreview {
        bundle: v.bundle.clone(), expires: v.expires.clone()
    }).collect()
}

/// Reads only iPhone profile metadata using selected iLoader Network device.
/// No Apple Developer Portal write, certificate revoke or installation.
#[tauri::command]
pub async fn preview_lcss_profile_renewal(
    device_state: State<'_, DeviceInfoMutex>,
) -> Result<PreviewResult, AppError> {
    let device = {
        let guard = device_state.lock().unwrap();
        guard.as_ref().ok_or_else(|| failure("select a device in iLoader"))?.clone()
    };
    if device.info.connection_type != "Network" {
        return Err(failure("Wi-Fi Network device is required"));
    }
    let provider = get_provider(&device.info).await?;
    let mut misagent = MisagentClient::connect(&provider).await
        .map_err(|e| failure(&format!("Misagent service unavailable: {e}")))?;
    let installed = misagent.copy_all().await
        .map_err(|e| failure(&format!("Unable to read device profiles: {e}")))?;
    let existing = prepare_installed(&installed, &device.info.udid)?;
    Ok(PreviewResult {
        status: "READ_ONLY_PREVIEW",
        profiles: previews(&existing),
        mode: "iLoader Network -> Misagent (no VPN)",
    })
}

/// Explicit, in-place profile-only canary. No IPA installation, no removal,
/// no certificate rotation. Downloads all 4 before installing any.
#[tauri::command]
pub async fn renew_lcss_profiles_via_wifi(
    device_state: State<'_, DeviceInfoMutex>,
    sideloader_state: State<'_, SideloaderMutex>,
) -> Result<RenewalResult, AppError> {
    let device = {
        let guard = device_state.lock().unwrap();
        guard.as_ref().ok_or_else(|| failure("select a device in iLoader"))?.clone()
    };
    if device.info.connection_type != "Network" {
        return Err(failure("Wi-Fi Network device is required"));
    }
    let provider = get_provider(&device.info).await?;
    let mut misagent = MisagentClient::connect(&provider).await
        .map_err(|e| failure(&format!("Misagent service unavailable: {e}")))?;
    let before_raw = misagent.copy_all().await
        .map_err(|e| failure(&format!("Unable to read existing profiles: {e}")))?;
    let before = prepare_installed(&before_raw, &device.info.udid)?;
    let mut session = SideloaderGuard::take(&sideloader_state)?;
    let team = session.get_mut().get_team().await
        .map_err(|e| failure(&format!("Could not determine signed-in Apple team: {e}")))?;
    if !before.values().all(|p| p.team == team.team_id) {
        return Err(failure("iLoader signed-in Apple team differs from existing installation"));
    }
    let app_ids = session.get_mut().get_dev_session()
        .list_app_ids(&team, None).await
        .map_err(|e| failure(&format!("Could not list existing App IDs: {e}")))?
        .app_ids;

    // Apple download phase. Gather and verify the COMPLETE set before any
    // phone-side profile installation.
    let mut downloaded = Vec::new();
    for (bundle, old) in &before {
        let app = app_ids.iter().find(|app| &app.identifier == bundle)
            .ok_or_else(|| failure("matching App ID missing from Apple team; no changes made"))?;
        let fresh = session.get_mut().get_dev_session()
            .download_team_provisioning_profile(&team, app, None).await
            .map_err(|e| failure(&format!("Apple provisioning request failed: {e}")))?;
        let bytes: Vec<u8> = fresh.encoded_profile.into();
        let new = parse_meta(&bytes)?;
        validate_new(old, &new, &device.info.udid)?;
        downloaded.push((bundle.clone(), new, bytes));
    }
    drop(session);

    // No destructive operations. The original profiles remain in place even
    // if a later installation fails.
    for (bundle, _, bytes) in &downloaded {
        misagent.install(bytes.clone()).await
            .map_err(|e| {
                warn!("Profile-only renewal failed on one app (no profiles removed)");
                failure(&format!("iOS rejected new provisioning profile for {bundle}: {e}"))
            })?;
    }
    let after_raw = misagent.copy_all().await
        .map_err(|e| failure(&format!("Unable to verify profiles after install: {e}")))?;
    let after = prepare_installed(&after_raw, &device.info.udid)?;
    for (bundle, wanted, _) in downloaded {
        let actual = after.get(&bundle)
            .ok_or_else(|| failure("profile missing in post-install readback"))?;
        if actual.uuid != wanted.uuid || actual.expires != wanted.expires {
            return Err(failure("new profile expiry/UUID not confirmed by iPhone"));
        }
    }
    info!("LCSS profile-only iLoader Network renewal received authoritative Misagent readback");
    Ok(RenewalResult {
        status: "PROFILES_INSTALLED_AND_READ_BACK_NOT_LAUNCH_PROOF",
        updated: previews(&after),
        reinstalled_ipa: false,
        old_profiles_removed: false,
        post_expiration_launch_verified: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn synthetic(bundle: &str, expiry: &str, cert: &[u8]) -> Vec<u8> {
        let mut ent = Dictionary::new();
        ent.insert("application-identifier".into(),
            Value::String(format!("TESTTEAM00.{bundle}")));
        let mut root = Dictionary::new();
        root.insert("Entitlements".into(), Value::Dictionary(ent));
        root.insert("TeamIdentifier".into(), Value::Array(
            vec![Value::String("TESTTEAM00".into())]));
        root.insert("UUID".into(), Value::String(format!("UUID-{bundle}-{expiry}")));
        root.insert("ExpirationDate".into(), Value::Date(
            plist::Date::from_xml_format(expiry).expect("synthetic date")));
        root.insert("ProvisionedDevices".into(), Value::Array(
            vec![Value::String("SYNTHETIC-DEVICE".into())]));
        root.insert("DeveloperCertificates".into(), Value::Array(
            vec![Value::Data(cert.to_vec())]));
        let mut out = Vec::new();
        plist::to_writer_xml(&mut out, &Value::Dictionary(root)).unwrap();
        out
    }
    #[test]
    fn four_profiles_and_signature_team_guards() {
        let a = ["", ".LiveProcess", ".ShareExtension", ".LaunchAppExtension"];
        let old = a.iter().map(|tail| synthetic(
            &format!("{BUNDLE_PREFIX}{tail}"), "2026-10-23T00:00:00Z", b"DER-OLD")
        ).collect::<Vec<_>>();
        let existing = prepare_installed(&old, "SYNTHETIC-DEVICE").unwrap();
        assert_eq!(existing.len(), 4);
        let p = existing.values().next().unwrap();
        let changed = synthetic(&p.bundle, "2026-10-30T00:00:00Z", b"DER-DIFFERENT");
        let new = parse_meta(&changed).unwrap();
        assert!(validate_new(p, &new, "SYNTHETIC-DEVICE").is_err());
        let same = synthetic(&p.bundle, "2026-10-30T00:00:00Z", b"DER-OLD");
        let new = parse_meta(&same).unwrap();
        validate_new(p, &new, "SYNTHETIC-DEVICE").unwrap();
        assert!(prepare_installed(&old[..3], "SYNTHETIC-DEVICE").is_err());
    }
}
