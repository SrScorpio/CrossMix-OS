# OTA channel security design (TLS and authenticity)

**Status:** design proposal only (GitHub #30, P1). Not approved for implementation.  
**Scope:** CrossMix-OS SE on TrimUI Smart Pro (TG5040).  
**Branch / worktree intent:** document evidence, threats, options, one recommendation, migration, and negative tests. No code changes in this deliverable.

**Evidence legend (used throughout):**

| Label | Meaning |
| --- | --- |
| **FACT** | Verified in this repository at the cited path and line (or binary string/size). |
| **ASSUMPTION** | Reasonable inference; not proven on device. |
| **UNKNOWN** | Must be confirmed on hardware or with a fuller tree checkout before coding. |

---

## 1. Inventory: TLS bypass and execution of downloaded content

### 1.1 Tools present on the SD image (repo evidence)

| Artifact | Path | Evidence | Notes |
| --- | --- | --- | --- |
| GNU Wget (full) | `System/bin/wget` | **FACT:** ELF aarch64, dynamically linked; strings include `--no-check-certificate`, GnuTLS symbols (`gnutls_*`), default trust path `/etc/ssl/certs` | Used by `download_file` and many OTA paths. |
| curl (static) | `System/bin/curl-aarch64` | **FACT:** ELF aarch64, statically linked (~3.2 MB); strings `libcurl/8.5.0`, `OpenSSL 1.1.1t  7 Feb 2023`, `--cacert`, default `/etc/ssl/certs/ca-certificates.crt`, `CURL_CA_BUNDLE` | Scripts call bare `curl`, not this path. |
| Bare `curl` in scripts | (PATH) | **FACT:** OTA scripts invoke `curl -k ...` without `/mnt/SDCARD/System/bin/curl-aarch64` | **UNKNOWN:** which binary PATH resolves on device (stock firmware curl vs symlink vs missing). |
| BusyBox | `System/usr/trimui/scripts/busybox` | **FACT:** `BusyBox v1.36.1 (2024-04-01 ...)`; applets include `wget`, `ssl_client`, `openssl`, `md5sum`, `sha1sum`, `sha256sum` | **FACT (strings):** BusyBox TLS path prints `note: TLS certificate validation not implemented` and supports `no-check-certificate`. |
| CA bundle | `System/updates/update_001/ca-certificates.crt` | **FACT:** PEM bundle, **129** `BEGIN CERTIFICATE` blocks, ~200 KB | Installed by `update_001.sh` to `/etc/ssl/certs/`. |
| CA install | `System/updates/update_001.sh` | **FACT** lines 24–26: `mkdir -p /etc/ssl/certs/` then `cp ... ca-certificates.crt /etc/ssl/certs/` | Bundle is copied as a **file** named under `certs/`, not necessarily the filename curl expects (`ca-certificates.crt` as single file is OK for curl `--cacert` / default file path; **UNKNOWN** whether GnuTLS wget expects a directory of hashed links). |
| libssl / libcrypto | `System/lib/libssl.so.1.1`, `System/lib/libcrypto.so.1.1` | **FACT:** present in tree | No full `openssl` CLI binary under `System/bin/` (**FACT:** `git ls-tree` has no `System/bin/openssl`). |
| PortMaster certifi | `Apps/PortMaster/.../certifi/cacert.pem` | **FACT:** present | Python stack only; not used by OTA shell scripts. |

**ASSUMPTION:** `curl -k` is used because device trust store / clock / intermediate chain made verifying HTTPS unreliable historically.  
**UNKNOWN (hardware):** Does `wget` without `--no-check-certificate` succeed against `github.com` with the installed bundle and device clock? Does bare `curl` (without `-k`) work if pointed at `/etc/ssl/certs/ca-certificates.crt` via `--cacert` or `CURL_CA_BUNDLE`? Does BusyBox `openssl` applet implement `dgst -verify` / `rsautl -verify`, or only a stub?

### 1.2 OTA / update scripts — TLS verification disabled

| # | File | Line(s) | What happens |
| --- | --- | --- | --- |
| T1 | `System/usr/trimui/scripts/ota_update.sh` | **5** | `curl -k -s -L https://raw.githubusercontent.com/$GITHUB_REPOSITORY/main/_assets/scripts/ota_bootstrap.sh \| sh` |
| T2 | `System/usr/trimui/scripts/ota_update.sh` | **27** | `curl -k -s -L "$url" \| sh` for hotfix URL |
| T3 | `System/usr/trimui/scripts/update_ota_release.sh` | **74** | `curl -k -s -L https://api.github.com/repos/$GITHUB_REPOSITORY/releases/latest` |
| T4 | `System/usr/trimui/scripts/update_notification.sh` | **52** | `curl -k -s -L` same GitHub API latest release |
| T5 | `System/usr/trimui/scripts/update_notification.sh` | **146** | `curl -k -s "$url"` fetches hotfix script body for metadata |
| T6 | `System/usr/trimui/scripts/update_common.sh` | **226** | `download_file`: `wget --no-check-certificate --quiet --show-progress -O "$temp_file" "$url"` |
| T7 | `System/usr/trimui/scripts/common_functions.sh` | **235** | Duplicate `download_file` with same `wget --no-check-certificate` |
| T8 | `_assets/scripts/ota_bootstrap.sh` | **10** | `wget --no-check-certificate ... -O /tmp/update_common.sh` then may replace on-device `update_common.sh` |
| T9 | Hotfix stubs | `_assets/hotfixes/CrossMix-OS_v{1.2.1,1.3.0,1.3.9,1.3.9.1,v}.sh` line **8** each | `curl -k -s -L "$url" \| sh` re-pipe to another remote script |

**Related (TLS not explicitly disabled, still unauthenticated trust):**

| # | File | Line(s) | What happens |
| --- | --- | --- | --- |
| T10 | `update_common.sh` | **26** | `wget -q --spider https://github.com` connectivity probe (no `-k` here) |
| T11 | `update_notification.sh` | **38**, **141** | `wget -q --spider` without `--no-check-certificate` |
| T12 | `ota_update.sh` | **23** | `/mnt/SDCARD/System/bin/wget -q --spider "$url"` hotfix existence check |
| T13 | `_assets/hotfixes/CrossMix-OS_v1.4.0-ce.2.sh` | hotfix zip + firmware parts | `wget -q` / `System/bin/wget` without `--no-check-certificate` for payload URLs (**FACT** in hotfix body); still no authenticity beyond transport |

**Beta channel (extra unauthenticated origin):**

| # | File | Line(s) | What happens |
| --- | --- | --- | --- |
| T14 | `_assets/scripts/ota_bootstrap.sh` | **37–38** | If `/mnt/SDCARD/betatest` exists, downloads `update_ota_release.sh` from a **Dropbox** shared link via `download_file` (inherits `--no-check-certificate`) |

### 1.3 Execution / trust of downloaded content (code execution or root FS write)

| # | File | Line(s) | Behavior | Privilege impact |
| --- | --- | --- | --- | --- |
| E1 | `ota_update.sh` | **5** | Pipe remote `ota_bootstrap.sh` to `sh` | Full shell as update user (device root context **ASSUMPTION** for TrimUI shell apps) |
| E2 | `ota_update.sh` | **27** | Pipe remote hotfix `.sh` to `sh` | Same |
| E3 | `_assets/scripts/ota_bootstrap.sh` | **10–17**, **37–55** | Overwrites local updater scripts from GitHub (or Dropbox beta): `update_common.sh`, `update_ota_release.sh`, `crossmix_update.sh`, `ota_update.sh`, `Apps/OTA-update/launch.sh`, `keys.gptk`, Terminal `launch.sh`, `shellect.sh`, `infoscreen.sh` | Persistent replacement of OTA trust root on SD |
| E4 | `update_ota_release.sh` | **145** | `download_file $Release_url` → zip under `$updatedir` | Large archive on SD; later applied |
| E5 | `update_ota_release.sh` | **163–173** | `check_update`: compares **only file size** to GitHub API `size` | Integrity = length match, not hash/signature |
| E6 | `update_ota_release.sh` | **181–184** | Downloads **tag** copy of `crossmix_update.sh` over local path, then **196–204** moves zip to SD root and **reboots** | Installer script replaced from network; reboot runs install |
| E7 | `crossmix_update.sh` | start | Extracts/applies zip from SD root after reboot | Local zip trusted once present (may have been network-sourced earlier) |
| E8 | Hotfix `CrossMix-OS_v1.4.0-ce.2.sh` | body | Downloads zip, `7zz x` onto `/mnt/SDCARD`; may download firmware multipart from `releases/latest/download/` | Writes system tree + large firmware blobs |
| E9 | Hotfix stubs | line **8** | Chain `curl \| sh` to canonical hotfix | Indirection; same as E2 |
| E10 | `portmaster_fix.sh` | MD5 flow ~57–225 | Downloads `.md5` from **same** GitHub raw channel as archive, then `md5sum -c` | **FACT:** same-channel hash is not origin authentication (illustrates the #30 design flaw pattern; PortMaster fix is adjacent, not core OTA UX) |

### 1.4 Trust anchors hard-coded today

| Item | Value | Location |
| --- | --- | --- |
| GitHub repo | `SrScorpio/CrossMix-OS-SE` | **FACT** `update_common.sh:18`, bootstrap, hotfixes |
| Release API | `https://api.github.com/repos/.../releases/latest` | **FACT** |
| Raw content | `https://raw.githubusercontent.com/.../main/...` | **FACT** |
| Tag script URL | hard-coded `SrScorpio/CrossMix-OS-SE` in `update_ota_release.sh:181` | **FACT** (not only `$GITHUB_REPOSITORY`) |
| Beta script | Dropbox `dl.dropbox.com` URL + `rlkey` | **FACT** bootstrap **38** |
| Version gate | `cmp_crossmix_versions` (GH#29) | **FACT** `update_common.sh` — prevents equal/downgrade **flags**, does **not** authenticate content |

### 1.5 What is *not* verified today

- TLS peer certificate and hostname (explicitly disabled on primary download/API paths).
- Artifact digest independent of the download channel.
- Publisher signature (no embedded release public key; no `.sig` / minisign / cosign).
- Pinning of GitHub or raw.githubusercontent.com certificate/SPKI.
- Freshness beyond “remote version string > local” (replay of an old *newer-than-local* build still applies if attacker serves it as “latest”).

---

## 2. Concrete threats and attacker gains

Threat model: attacker controls network path to the console (home LAN MITM, malicious Wi‑Fi, captive portal, compromised DNS, or compromised CDN/mirror). Attacker does **not** need physical SD access. Console user initiates OTA or boots with notifier enabled.

| ID | Threat | Preconditions | What attacker achieves | Maps to inventory |
| --- | --- | --- | --- | --- |
| TH1 | **MITM on home / captive Wi‑Fi** | User on attacker AP or ARP/DNS spoof on LAN; OTA or boot check runs | Forge HTTPS responses because clients use `-k` / `--no-check-certificate`; inject bootstrap/hotfix scripts → **arbitrary code as update shell**; replace zip + matching **size** field in forged API JSON | T1–T9, E1–E8 |
| TH2 | **DNS hijack** of `github.com` / `raw.githubusercontent.com` / `api.github.com` | Rogue DNS on DHCP or upstream | Same as TH1 without L2 MITM if TLS not verified; if TLS were verified without pin, still needs cert from public CA (harder) or user-trusted CA | T1–T9 |
| TH3 | **Compromised GitHub project or stolen release credentials** | Attacker publishes malicious release/tag or pushes to `main` hotfixes | Supply-chain: all clients that trust repo URL pull malware; TLS and CA bundle **do not help** | E3–E8; entire channel |
| TH4 | **Compromised / abusive mirror or beta Dropbox link** | Beta flag file present, or future mirror | Dropbox object or mirror serves hostile `update_ota_release.sh`; bootstrap installs it permanently | T14, E3 |
| TH5 | **Replay of older “valid” artifact** | Attacker has copy of previous good zip/script that is still newer than victim’s version, or rewrites API “latest” | Downgrade to known-vulnerable build, or re-run old hotfix with buggy logic; size check passes if file intact | E5, version compare only |
| TH6 | **Same-channel hash/CRC** | Defender adds MD5/SHA of zip next to zip on GitHub | Attacker MITM replaces **both**; false sense of safety (already visible in PortMaster fix pattern E10) | E10 pattern |
| TH7 | **Partial integrity only (size)** | Current release path | Attacker pads/truncates carefully or serves different content of equal length | E5 |
| TH8 | **Silent metadata poison (notifier)** | Boot `update_notification.sh` | Forged “update available” toast / JSON metadata; social-engineers user into launching OTA into TH1 | T4–T5 |

**Out of scope for this design (note only):** physical SD tampering, evil maid, and full firmware boot-chain attestation (TrimUI stock bootloader). Those need separate hardware/rootfs work.

**Risk statement (aligned with #30):** design risk is **accredited**; there is **no demonstrated public exploit** required to justify hardening. Highest severity paths are **E1/E2/E3** (remote shell) and **E6+E7** (replace installer + full image).

---

## 3. Options realistic for TG5040

Constraints unique to this device:

- Updates run as **BusyBox ash** scripts on SD (`/mnt/SDCARD/...`).
- Network tools: GNU **wget** (GnuTLS), static **curl** (OpenSSL 1.1.1t), BusyBox wget/ssl_client (**no cert validation** per binary strings).
- Crypto libraries on SD: `libssl`/`libcrypto` 1.1; **no** full OpenSSL CLI in `System/bin/`.
- Hash applets: BusyBox `sha256sum` / `md5sum` (**FACT**).
- CA material already shipped once via `update_001` (**FACT**).
- Storage and UX: handheld, intermittent Wi‑Fi, large zips (~hundreds of MB), user confirms download/apply in terminal UI.
- Must not brick field units; bootstrap today **self-replaces** updaters from the network (chicken-and-egg).

### Option A — Enable real TLS verification (CA bundle on SD)

**Mechanism:** Stop passing `-k` / `--no-check-certificate`. Point curl/wget at a known-good CA bundle on the SD card (e.g. `System/etc/ssl/cert.pem` or reuse/fix `ca-certificates.crt`). Prefer **explicit** `--cacert` / `SSL_CERT_FILE` / wget CA flags over hoping `/etc/ssl` survived OEM updates.

**Client capability (repo, not hardware):**

| Client | Can verify TLS? | Evidence |
| --- | --- | --- |
| `System/bin/wget` | **Likely yes** with GnuTLS + trust file/dir | **FACT** strings: verify APIs, `--no-check-certificate` implies verify is default when not passed |
| `System/bin/curl-aarch64` | **Likely yes** with OpenSSL 1.1.1t + `--cacert` | **FACT** strings |
| BusyBox `wget` / `ssl_client` | **No meaningful verify** | **FACT** string: `TLS certificate validation not implemented` |
| Bare `curl` on PATH | **UNKNOWN** | Must resolve on device |

**Pros:** Stops casual LAN MITM with forged certs; small script change; reuses existing bundle.  
**Cons:** Does **not** stop TH3 (GitHub account/repo compromise); clock skew / incomplete chain / captive portals may break OTA (why `-k` may have appeared); BusyBox paths remain unsafe if ever used; Dropbox beta still a second trust root.  
**Cost:** Low engineering; medium QA (matrix of Wi‑Fi, date, DNS).  
**Hardware gate:** **UNKNOWN** — must test wget/curl verify against GitHub with device clock correct and wrong.

### Option B — Certificate or SPKI pinning

**Mechanism:** Pin GitHub (or a project-controlled endpoint) leaf/intermediate SPKI hash or pin a project-owned TLS cert on a first-party HTTPS endpoint.

**Pros:** Stronger than public CA alone against rogue CAs and some MITM.  
**Cons:** GitHub rotates certs; pins break OTA until hotfix (paradox); first-party endpoint adds hosting; curl/wget pin support varies (**UNKNOWN** exact flags on device builds); still no protection if pinned host is compromised at app layer.  
**Cost:** High operational fragility on a volunteer handheld distro.  
**Verdict for TG5040:** poor fit as *primary* control.

### Option C — Artifact signatures with embedded public key (recommended core)

**Mechanism:**

1. Maintain an **ed25519** (preferred) or RSA-3072 **release public key** on the SD image, e.g. `System/usr/trimui/security/crossmix-ota-v1.pub` (shipped in image + hotfixes).
2. CI/release process signs:
   - release archive (`CrossMix-OS_v*.zip` / `.7z`)
   - hotfix script and hotfix zip
   - optional: detached signature over a **manifest** listing name, version, size, sha256, channel
3. Device: download artifact + `.sig` (or manifest+sig) over HTTPS; verify signature with **on-device verifier** before any `sh`, unzip-to-SD, or script overwrite.
4. TLS still recommended (defense in depth) but **authenticity does not depend on TLS**.

**On-device verifier choices:**

| Verifier | On image today? | Notes |
| --- | --- | --- |
| `minisign` / `signify` static binary | **No** — would add ~small static aarch64 binary under `System/bin/` | Simple UX; well-proven for OS images |
| Full `openssl dgst -sha256 -verify` | **No** CLI; libs yes | Would need to ship `openssl` CLI or use a tiny custom tool linked to libcrypto |
| BusyBox `openssl` applet | **UNKNOWN** feature set | Do **not** plan on it until hardware/`busybox openssl` help is captured |
| Pure shell + `sha256sum` of **pinned** digest list | Weak unless list is signed | Unsigned list = TH6 |

**Pros:** Defeats TH1/TH2/TH6/TH7 for *signed* objects; limits TH4 if beta also signed by same key; clear negative tests; matches “don’t trust the pipe” reality of `curl | sh`.  
**Cons:** Key ceremony and loss/compromise process; first rollout must deliver pubkey **before** enforcing verify (migration); TH3 becomes “attacker steals signing key” (smaller, manageable surface); slightly more release engineering.  
**Cost:** Medium (tooling + one static verifier binary + script gates). Best cost/benefit for this threat model.

### Option D — Out-of-band signed hash (TOFU / secondary channel)

**Mechanism:** Publish sha256 on a second channel (site, QR, Discord) or embed expected hash in **previous** release only.

**Pros:** No new crypto binary if hashes are pre-embedded.  
**Cons:** Does not scale; users won’t compare hashes on a handheld; embedding next hash in previous release fails for skipped versions and first install; still needs a signature or it collapses to TH6 when both channels are MITM’d.  
**Verdict:** useful as **optional** owner check, not primary OTA gate.

### Option E — Hybrid (TLS verify + signed artifacts)

**Mechanism:** A + C together: remove `-k` where clients can verify, **and** require signature before execute/apply.

**Pros:** Defense in depth; TLS reduces metadata spoofing noise; signatures are the real control for E1–E8.  
**Cons:** Two failure modes to support in UX (“network certificate” vs “bad signature”).  
**Verdict:** target end state; ship signatures first if TLS prove flaky on hardware.

---

## 4. Comparison and recommendation

| Option | Stops LAN MITM script inject | Stops equal-size zip swap | Stops GitHub project compromise | Field fragility | Fits TG5040 tooling |
| --- | --- | --- | --- | --- | --- |
| A TLS only | Mostly | No | No | Medium (clock/CA) | Yes, if hardware OK |
| B Pinning | Strong | No | No | High | Weak |
| C Signatures | Yes (for signed steps) | Yes | No (key theft only) | Low–medium | Yes with small binary |
| D OOB hash | Partial | Partial | No | High UX | Poor |
| E A+C | Yes | Yes | No (key theft) | Medium | Yes |

### Recommendation (single choice)

**Implement Option E with phased enforcement, signatures as the hard gate (Option C), TLS verification as a fast-follow (Option A).**

Concretely:

1. **Hard gate (must):** Before any of: pipe-to-`sh`, overwrite of updater scripts, `7zz` extract to `/mnt/SDCARD`, or reboot-to-install — verify a **detached minisign (or openssl) signature** over the bytes about to be trusted, using **public key file shipped on SD** (`crossmix-ota-v1.pub`).  
2. **Stop `curl | sh`:** always download to a temp file under `$updatedir` or `/tmp`, verify, then `sh` the file.  
3. **Manifest:** release and hotfix publish `CrossMix-OS_vX.Y.Z.manifest.json` (or simple text) containing `version`, `filename`, `sha256`, `size`, `channel`, signed as a whole; device checks sha256 of payload matches manifest after signature verifies.  
4. **TLS:** switch OTA scripts to `System/bin/curl-aarch64` or `System/bin/wget` with **explicit CA file on SD** and **no** `-k` / `--no-check-certificate`, behind a feature flag `OTA_TLS_VERIFY=1` defaulting on once hardware matrix passes; keep emergency override file on SD for support (**ASSUMPTION** operators need break-glass).  
5. **Beta Dropbox:** either remove or require the Dropbox-delivered script to be **signed by the same key** (URL alone is not trust).  
6. **Do not** treat GitHub API `size` or same-channel md5 as authenticity.

**Why not TLS-only:** inventory E1–E3 execute remote shell; a stolen Wi‑Fi path + `-k` is enough; fixing only TLS leaves TH3 and any future pin/CA failure without a second factor.  
**Why signatures-first on this device:** works even when CA store is wrong; matches existing “download then apply” UX; BusyBox already has `sha256sum` for manifest payload checks once signature covers the manifest.

**Signing algorithm preference:** minisign/ed25519 (small sigs, easy tooling on CI). Fallback: OpenSSL RSA-PSS over SHA-256 if shipping minisign is rejected — requires openssl CLI or custom verifier linked to existing `libcrypto.so.1.1`.

---

## 5. Migration and compatibility with already-installed consoles

Field units already trust **unsigned** bootstrap (E1/E3). Enforcement cannot flip on overnight without a signed carrier.

### Phase 0 — Prep (no device behavior change)

- Generate release keypair offline; store private key in restricted CI/secrets (not in git).  
- Add `docs` + release checklist: every GitHub Release asset gets `.minisig` / `.sig` and manifest.  
- Commit **public** key path layout in repo (implementation PR later).  
- **Hardware lab:** record outputs of:
  - `System/bin/wget --version` and test fetch **with** and **without** `--no-check-certificate` to `https://api.github.com` and `https://raw.githubusercontent.com`
  - `System/bin/curl-aarch64 --version` and same with `--cacert` pointing at SD copy of bundle
  - `busybox openssl` help / `busybox wget` behavior  
  Mark results under **FACT** before coding.

### Phase 1 — Soft verify (compatible with all current SE installs)

- Hotfix (existing unsigned channel one last time, or manual SD drop) ships:
  - pubkey file
  - verifier binary (if needed)
  - updated `update_common.sh` with `verify_ota_artifact` helper that logs **WARN** on missing sig, **does not block**
- Release process starts attaching signatures (clients ignore if soft).  
- Goal: one version of telemetry/logs prove verify works on real devices.

### Phase 2 — Bootstrap trust upgrade

- New image / CE release includes pubkey + verifier + scripts that **require** sig for:
  - hotfix body
  - `crossmix_update.sh` network refresh
  - release zip before move-to-root + reboot  
- Keep accepting **local** pre-placed zip on SD root only if signed sidecar present **or** user holds a confirm “UNSAFE local zip” (**product choice**; default deny recommended).

### Phase 3 — TLS enforcement

- After Phase 2 is dominant: remove `-k` / `--no-check-certificate` from T1–T9 paths; force SD CA path.  
- Connectivity probe (T10) should use same CA settings.  
- Document break-glass: `System/updates/ota_insecure_tls` file re-enables old flags for one session and logs loudly.

### Phase 4 — Refuse unsigned network bootstrap

- `ota_update.sh` no longer pipe-to-sh without verify.  
- Old stubs that only `curl | sh` must be replaced by hotfix chain that is itself signed (stubs can embed sha256 of next script **only if** that digest is covered by a signature already on device — prefer full sig verify).

### Compatibility matrix (intent)

| Console state | Phase 1 | Phase 2+ |
| --- | --- | --- |
| Old SE, never hotfixed | OTA still works unsigned | Needs one unsigned or USB/SD manual jump to Phase 1/2 carrier |
| Has latest CE hotfix | Soft verify logs | Enforced verify |
| Offline zip install | Unchanged | Requires sig sidecar or explicit unsafe confirm |
| `betatest` Dropbox | Still weak | Blocked unless signed |

**Rollback:** signed “previous” build can be published; version compare (GH#29) already blocks casual downgrade — support may need a signed **allow-downgrade** token or recovery image doc (product decision; call out as open).

**Key rotation:** ship `crossmix-ota-v2.pub` alongside v1; accept either for period N releases; then drop v1. Compromise response: revoke by emergency hotfix that only installs new pubkey if signed by v1, plus out-of-band SD image.

---

## 6. Negative tests for QA (console-visible outcomes)

Run on real TG5040 hardware with controlled MITM (e.g. local reverse proxy with bad cert) or pre-placed bad files. **Do not** require production GitHub compromise.

| ID | Test | Setup | Expected console behavior (after enforcement) |
| --- | --- | --- | --- |
| N1 | **Invalid TLS certificate** | MITM with self-signed cert; TLS verify ON; no break-glass file | Download/API fails; message like `TLS verification failed` / wget/curl error; **no** script execute; no zip apply; `/tmp/ota_release_result` → `download failed` or new `tls failed`; hotfix not run |
| N2 | **Valid TLS, tampered archive hash** | Serve real HTTPS but zip bytes modified; manifest sig still old **or** manifest sha256 mismatch | Verify fails **before** extract; clear error `payload hash mismatch` / `signature invalid`; zip not moved to SD root; no reboot |
| N3 | **Artifact signed by wrong key** | Signature made with attacker ed25519 key; victim pubkey unchanged | `signature invalid` / `public key mismatch`; no `sh` of hotfix; bootstrap does not overwrite `update_common.sh` |
| N4 | **Replay older signed release** | Server advertises old release still newer than device; sig valid for that old version | Prefer: reject if version ≤ last-applied **or** if release timestamp/monotonic counter in manifest &lt; device watermark; at minimum GH#29 blocks equal/downgrade; document if “older-but-still-newer-than-local” replay remains accepted (residual risk TH5) — QA records actual policy |
| N5 | **Unsigned hotfix pipe** | Hotfix URL returns body without `.sig` | Refuse execute; user-visible `hotfix signature missing`; leave `crossmix-hotfix-version.txt` unchanged |
| N6 | **API JSON size lie** | API says size=S, file length=S, content malicious, **bad sig** | Rejected on signature, not accepted on size (proves E5 fixed) |
| N7 | **BusyBox wget only path** | Force PATH without GNU wget/curl | Must fail closed or fall back to known-good binaries under `System/bin/`; never silently use non-verifying BusyBox TLS |
| N8 | **Clock far in the past** | Device date 2018; TLS verify ON | Defined behavior: fail TLS with readable “check date/time” hint (infoscreen), not infinite hang |
| N9 | **Beta Dropbox without sig** | `betatest` present; unsigned remote script | Blocked under Phase 2+ |
| N10 | **Local zip without sig** | User copies zip to SD root | Per product policy: block or explicit unsafe confirm; never silent apply |

**Positive controls (sanity):** genuine latest release with valid sig and TLS applies; hotfix increments `crossmix-hotfix-version.txt`; logs under `$updatedir/*.log` contain verify OK lines for support.

---

## 7. Open questions (block implementation coding)

1. **UNKNOWN:** On-device PATH resolution for `curl` and whether `System/bin/curl-aarch64` is symlinked as `curl`.  
2. **UNKNOWN:** GnuTLS wget trust of `update_001` layout (`ca-certificates.crt` file in `/etc/ssl/certs/` vs hashed directory).  
3. **UNKNOWN:** BusyBox `openssl` applet command set for verify.  
4. **Product:** allow unsafe local zip? beta channel retention?  
5. **Ops:** where private signing key lives; who can cut emergency releases.  
6. **Residual TH5:** monotonic watermark beyond version string?

---

## 8. Implementation boundary (explicit non-goals of this document)

- No script patches, no new binaries committed as part of this proposal.  
- No change to GitHub release process until design approval.  
- PortMaster MD5 same-channel issue (E10) should follow the **same** signing pattern in a separate change list; not required to land in the first OTA PR but must not be cited as “already solved.”

---

## 9. Sources cited

- Repository paths and lines listed in §1 (branch worktree `docs/gh-30-ota-security` / repo CrossMix-OS SE layout).  
- Binary string inspection of `System/bin/wget`, `System/bin/curl-aarch64`, `System/usr/trimui/scripts/busybox` (local `strings` / `file`).  
- BusyBox project documentation: general multi-call model and applet set — https://busybox.net/downloads/BusyBox.html (upstream docs; device build is **FACT** v1.36.1 with local applet list from binary).  
- curl 8.5.0 / OpenSSL 1.1.1t identification from `System/bin/curl-aarch64` strings (**FACT**).

---

## 10. Summary for decision makers

| | |
| --- | --- |
| **Problem** | OTA disables TLS verify and runs network content as shell; size≠authenticity. |
| **Worst case** | LAN attacker gets persistent code execution and full SD image replace. |
| **Recommend** | Sign artifacts with embedded pubkey; kill `curl\|sh`; then enable TLS with SD CA bundle. |
| **Do not** | Ship “HTTPS + md5 on same URL” as the fix. |
| **Next** | Approve design → hardware TLS/crypto probes → Phase 1 soft-verify hotfix. |
