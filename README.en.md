# VRChat Stream Server

[Русский](README.md) | **English**

[![Tests](https://github.com/Skumen/vrchat-stream-server/actions/workflows/tests.yml/badge.svg)](https://github.com/Skumen/vrchat-stream-server/actions/workflows/tests.yml)
[![Release](https://img.shields.io/github/v/release/Skumen/vrchat-stream-server)](https://github.com/Skumen/vrchat-stream-server/releases/latest)

Your own streaming server for VRChat video players. OBS sends the stream to the server, and the server delivers it in three formats at once, so every viewer gets a link that works:

```
                          ┌─ RTSP  rtspt://…:8554/live/stream  → VRChat PC            ~1 s
OBS ──RTMP:1935──▶ MediaMTX ┼─ RTMP  rtmp://…/live/stream        → VRChat PC (fallback) ~1–2 s
                          └─ HLS ─▶ nginx :80/:443 ─▶ …/live/stream/index.m3u8
                                                              → PC + Quest/Android  ~3–5 s
```

- **[MediaMTX](https://github.com/bluenviron/mediamtx)** receives the stream from OBS and serves it over RTSP, RTMP and HLS without re-encoding, so it barely uses any CPU.
- **nginx** serves HLS over HTTP and HTTPS and obtains the Let's Encrypt certificate.
- **ufw and fail2ban** close unused ports and ban anyone trying to guess the OBS stream key.

Tested in **VRChat on PC and on Quest**.

## Quick install

On a VM with Ubuntu 20.04+ or Debian 11+ (x86_64 or ARM), run:

```bash
curl -fsSL https://github.com/Skumen/vrchat-stream-server/releases/latest/download/setup.sh -o setup.sh
sudo DOMAIN=stream.example.com bash setup.sh
```

Replace `stream.example.com` with your domain. Without a domain, just run `sudo bash setup.sh`: the server will work over HTTP.

In a few minutes the script prints ready-to-use OBS settings and VRChat links. Then:
1. Open the ports at your hosting provider (see below).
2. Set up OBS with a ready-made profile from [`obs-profiles.zip`](https://github.com/Skumen/vrchat-stream-server/releases/latest/download/obs-profiles.zip) (**Profile → Import**) or by following [OBS-settings.en.md](OBS-settings.en.md).

## Installation details

**HTTPS** is recommended: Quest works more reliably with it. You need a domain whose A record points to the server. A free one is available at, for example, [DuckDNS](https://www.duckdns.org). The certificate renews automatically. An email is optional: `EMAIL=you@example.com` only attaches it to the Let's Encrypt account.

**Provider ports.** If the VM is in a cloud, open inbound **TCP 80, 443, 1935, 8554** in your provider's panel (security group / firewall).

**Fresh VM.** Right after creation, Ubuntu installs updates in the background and holds the apt lock. The script detects this, waits (printing a message every 30 seconds) and continues as soon as apt is free.

**The VM's own firewall (ufw)** is configured by the script. If ufw is missing, it installs it. If ufw is disabled, it enables it. If it is already enabled, it only adds rules.
- **SSH stays open.** The script detects the SSH port (from the sshd config, from active connections, and always 22) and allows it **before** enabling ufw.
- **Open ports:** 80, 443, 1935, 8554. **Port 80 is always open:** Let's Encrypt uses it to verify the domain on every renewal. Even `uninstall` never closes 80, 443 or SSH.
- **All other inbound traffic is blocked.** If other services run on the VM, the script lists their ports and suggests a command like `sudo FIREWALL_EXTRA="25565/tcp 7777/udp" vrc-stream install`.
- **Leave the firewall alone:** `FIREWALL=0`.

> The first time ufw is enabled, keep your provider's VNC console open. If SSH access is lost anyway, run `sudo ufw disable` there.

**fail2ban** bans IPs that try to guess the OBS key: **20 failed attempts within 10 minutes → 30-minute ban**.
- The rule is deliberately lenient: OBS with a typo in the key reconnects every couple of seconds, and a streamer should not lock themselves out for long.
- `sudo vrc-stream status` shows who is banned. Unban: `sudo vrc-stream unban <IP>` (or `all`).
- fail2ban also protects SSH. On Debian 12 the script switches the SSH rule to the systemd journal, otherwise fail2ban does not start there.
- Disable: `FAIL2BAN=0`.

**Re-running** the script is safe. It removes an old `nginx-rtmp` setup (the `rtmp{}` block, `SK.conf`, tmpfs) and backs up `/etc/nginx` to `/root/vrc-stream-backups/`.

## Updating

```bash
sudo vrc-stream update           # to the latest version
vrc-stream update --check        # only check whether a new version exists
sudo vrc-stream update v1.0.3    # a specific version (e.g. roll back)
```

The script is downloaded from the GitHub release. Before installing, the checksum from `SHA256SUMS.txt` and the syntax are verified. The OBS key, domain and other settings are kept.

## OBS setup

> Full guide with quality profiles, settings for NVIDIA/AMD/Intel/x264 and troubleshooting: [OBS-settings.en.md](OBS-settings.en.md).

**Settings → Stream**
- Service: *Custom…*
- Server: `rtmp://<your server>/live`
- Stream Key: `stream?user=obs&pass=<key>` (`sudo vrc-stream info` prints the whole string)

**Settings → Output** (*Advanced* mode)

| Setting | Value |
|---|---|
| Encoder | **H.264**: NVENC / AMF / QuickSync / x264. HEVC and AV1 won't work: Quest can't play them |
| Rate Control | CBR |
| Bitrate | 3000–4500 kbps for 720p, 4500–6000 for 1080p |
| **Keyframe Interval** | **1 s** (equals `HLS_SEGMENT`; with `HLS_SEGMENT=2s` use 2) |
| B-frames | 0 |
| x264: Tune | zerolatency |
| Audio | AAC, 160 kbps, **48 kHz**, stereo |

**Video:** 1920×1080 or 1280×720, 30 fps. 720p30 is more reliable for Quest.

## VRChat links

| Link | Who can watch | Latency |
|---|---|---|
| `https://<domain>/live/stream/index.m3u8` | **Everyone**: PC, Quest, Android | ~3–5 s |
| `rtspt://<server>:8554/live/stream` | PC only | ~1 s |
| `rtmp://<server>/live/stream` | PC only (fallback) | ~1–2 s |

- With a mixed audience (PC + Quest), put the **HLS link** into the player: everyone can see it.
- If only PC users watch and sync matters (music, reacting to chat), use `rtspt://`.
- You need an **AVPro**-based player: ProTV, iwaSync3 (LIVE mode), USharpVideo (Stream). The Unity player can't play live streams.
- **Every viewer must enable "Allow Untrusted URLs"** (Settings → Comfort & Safety). Your server is not on VRChat's allowlist, so without this setting the link won't load.
- To check the stream outside VRChat, open `https://<domain>/live/stream/` in a browser or use VLC (*Media → Open Network Stream*).

## Commands

```bash
sudo vrc-stream info            # OBS settings and links
sudo vrc-stream status          # live status, viewers, HLS latency, certificate, bans
sudo vrc-stream logs            # live MediaMTX logs
sudo vrc-stream restart         # restart services
sudo vrc-stream new-key         # new OBS key (if the old one leaked)
sudo vrc-stream update          # update from GitHub
sudo vrc-stream unban <IP|all>  # unban in fail2ban
sudo vrc-stream install         # apply new settings
sudo vrc-stream uninstall       # remove
vrc-stream version              # version
```

The script's messages are in Russian; the commands and settings are the same in any language.

### Automatic HLS latency reset

If the connection to OBS drops in the middle of a segment, HLS gets one long segment. After that, MediaMTX keeps an increased `TARGETDURATION` until restarted, and players stay ~3 × `TARGETDURATION` behind. So latency can grow from ~3 to ~15 s.

The `vrc-stream-heal.timer` timer checks the playlist every minute. If latency has grown, **OBS is offline and nobody is watching**, it restarts MediaMTX and latency is back to ~3 s. Viewers are not affected; restarts happen at most once every 10 minutes. `journalctl -u vrc-stream-heal` shows what the timer did.

## Settings

Settings are passed as variables at install time and saved in `/etc/vrc-stream/settings.env`. Example: `sudo HLS_SEGMENT=2s vrc-stream install`.

| Variable | Default | What it does |
|---|---|---|
| `DOMAIN` | — | Enables HTTPS via Let's Encrypt. `DOMAIN=` disables HTTPS |
| `EMAIL` | — | Optional: email for the Let's Encrypt account |
| `STREAM_KEY` | random | OBS password |
| `HLS_SEGMENT` | `1s` | HLS segment length. `2s`: ~6 s latency but fewer stalls for viewers with a weak connection |
| `OFFLINE_SCREEN` | `1` | Offline screen while OBS is not live (see below). `0` disables |
| `HLS_VARIANT` | `mpegts` | `mpegts` — maximum compatibility. `fmp4` and `lowLatency` are experimental |
| `PUBLIC_HOST` | auto | Server address in links, if IP auto-detection is wrong |
| `RTMP_PORT`, `RTSP_PORT` | `1935`, `8554` | Ports |
| `FIREWALL` | `1` | Install and configure ufw. `0` — leave the firewall alone |
| `FIREWALL_EXTRA` | — | Extra open ports, space-separated, e.g. `"25565/tcp 7777/udp"` |
| `FAIL2BAN` | `1` | Ban IPs guessing the OBS key. `0` disables |
| `APT_WAIT_MAX` | `900` | How many seconds to wait while the system installs updates (not saved) |

### Offline screen instead of a dropped stream (on by default)

While OBS is not live, the server shows a "STREAM IS OFFLINE" screen. Viewers' players stay connected, so when OBS starts or restarts the picture appears on its own, without restarting the video.

**Requirement:** OBS must send H.264 and **AAC 48 kHz stereo** audio (the OBS defaults). With 44.1 kHz the server refuses the OBS connection; `sudo vrc-stream logs` shows why (`audio configuration does not match`). Disable the offline screen: `sudo OFFLINE_SCREEN=0 vrc-stream install`.

## Capacity

Every viewer downloads the whole stream, so outbound traffic ≈ bitrate × number of viewers. For example, 5 Mbps × 40 viewers ≈ 200 Mbps. CPU usage is minimal; the VM's bandwidth is the bottleneck.

## Troubleshooting

| Symptom | What to check |
|---|---|
| OBS can't connect | `sudo vrc-stream logs`: `authentication failed` — wrong key; `audio configuration does not match` — OBS audio is 44.1 kHz, set 48 kHz (Settings → Audio → Sample Rate). Port 1935 must be open at the provider |
| OBS can't connect even with the right key | fail2ban may have banned your IP after attempts with a wrong key: `sudo vrc-stream status`, then `sudo vrc-stream unban <IP>` |
| Nobody can load the stream | `sudo vrc-stream status`: is it live? Are ports 80/443 open at the provider? Does the link open in a browser? |
| Another service on the VM stopped working | ufw closed its port. Open it: `sudo FIREWALL_EXTRA="port/tcp" vrc-stream install` |
| `status` says the certificate was not renewed in time | `sudo certbot renew --dry-run` shows why. Usually port 80 is closed at the provider or the DNS record changed |
| Some viewers can't load it | They haven't enabled "Allow Untrusted URLs" |
| Works on PC, not on Quest | Use the HLS link for Quest (not `rtspt://` or `rtmp://`), preferably with HTTPS. OBS must use H.264 |
| `rtspt://` doesn't work | Port 8554/TCP is closed at the provider |
| Frequent buffering | Set `HLS_SEGMENT=2s` (and a 2 s keyframe interval), lower the bitrate |
| High HLS latency | `sudo vrc-stream status` shows segment length and expected latency. Segments longer than 1 s mean the OBS keyframe interval must be 1 s, not "0/auto". If segments are 1 s but `TARGETDURATION` grew (after an OBS connection drop), it resets by itself once the stream ends and viewers leave. Immediately: `sudo vrc-stream restart`, but viewers will have to restart the video |

## What has been tested

**Manually, on a real VM** (1 vCPU AMD EPYC, 2 GB RAM, domain with HTTPS): one-command installation, streaming from OBS to **VRChat on PC**, **VRChat on Quest** and a browser. HTTPS, HLS, RTSP, RTMP, key protection, closed internal ports and the offline screen were checked from the internet.

**Automatically, on every push** ([GitHub Actions](https://github.com/Skumen/vrchat-stream-server/actions)):
- ShellCheck on all scripts.
- Unit tests: settings, firewall, fail2ban, waiting for apt, latency reset, `update`, certificate expiry, config generation, OBS profiles. System commands (`ufw`, `apt-get`, `systemctl`…) are mocked.
- Integration tests with a real MediaMTX: OBS key, HLS, RTSP, offline screen, `status`. The fail2ban filter is checked with the real `fail2ban-regex`.

If something doesn't work, open an [issue](https://github.com/Skumen/vrchat-stream-server/issues) with the output of `sudo vrc-stream status` and `sudo vrc-stream logs`.

## For developers

```bash
tests/run.sh unit          # fast tests, change nothing on the system
tests/run.sh integration   # with a real MediaMTX (downloaded to tests/.cache)
tests/run.sh               # everything
```

Requires `bash`, `jq`, `curl`, `openssl`. Checking the fail2ban filter needs `fail2ban-regex`; without it that test is skipped.

**Releasing.** Bump `VRC_STREAM_VERSION` in `setup.sh`, add release notes to `docs/releases/vX.Y.Z.md` and push a tag. The release title is the version number; a leading `# …` line in the file is skipped:

```bash
git tag -a v1.2.0 -m "vrc-stream 1.2.0" && git push origin v1.2.0
```

GitHub Actions runs the tests, builds `setup.sh`, `obs-profiles.zip`, `SHA256SUMS.txt` and publishes the release.
