# OBS settings for VRChat Stream Server

[Русский](OBS-settings.md) | **English**

These settings are tuned for this server: viewers on PC and Quest, 1-second HLS segments, an offline screen while OBS is disconnected.
Items marked **⚠** are required. Without them the stream won't start or will work poorly.

Menu names follow the English OBS 30+ interface.

---

## Quick way: import a ready-made profile

The [`obs-profiles`](obs-profiles) folder contains ready-made OBS profiles with all the settings from this guide ("Standard" profile: 1080p30, 4500 kbps). Checked against the OBS 32.2 source code.

| Folder | For |
|---|---|
| `VRChat-NVIDIA` | NVIDIA GeForce GTX 10xx and newer |
| `VRChat-AMD` | AMD Radeon GPUs |
| `VRChat-Intel` | Intel integrated graphics or Intel Arc |
| `VRChat-CPU` | If your GPU is not suitable: the CPU encodes (x264) |

1. Download [`obs-profiles.zip`](https://github.com/Skumen/vrchat-stream-server/releases/latest/download/obs-profiles.zip) from the latest release and unzip it.
2. In OBS: **Profile → Import**, pick the folder for your GPU, e.g. `obs-profiles\VRChat-NVIDIA`.
3. **Profile** → select `VRChat Stream (NVIDIA)` (or your variant).
4. **⚠ Settings → Stream:** replace `rtmp://YOUR-SERVER/live` and `YOUR-KEY` with your values from `sudo vrc-stream info` on the server.
5. Done. Scenes and sources are not changed: a profile only holds settings.

- Need a different quality (e.g. "Crowd" 720p)? Change the resolution and bitrate using the table in section 1 below.
- If OBS says the profile already exists, rename the folder before importing (e.g. `VRChat-NVIDIA-2`).
- If your GPU doesn't support the encoder, OBS shows an error when you start streaming. Import the `VRChat-CPU` profile.

The same settings are described step by step below.

---

## 1. Choose the quality

The main limit is the server's bandwidth. Viewer counts in the table are for a VM with a 500 Mbps link. Pick a profile for your expected audience:

| Profile | Resolution | FPS | Video bitrate | Viewers (approx.) | When to use |
|---|---|---|---|---|---|
| **Crowd** | 1280×720 | 30 | 2500 kbps | up to ~135 | Big events, several instances |
| **Standard** ⭐ | 1920×1080 | 30 | 4500 kbps | up to ~80 | One full instance, movies, general use |
| **Action** | 1280×720 | 60 | 3500 kbps | up to ~100 | Games, fast motion |
| **Maximum** | 1920×1080 | 60 | 6000 kbps | up to ~60 | Small audience, maximum sharpness |

The **streamer's** upload speed should be at least 1.5× the bitrate: from ~7 Mbps for "Standard".

---

## 2. Stream

**Settings → Stream**

| Setting | Value |
|---|---|
| Service | **Custom…** |
| Server | `rtmp://<server address>/live` |
| Stream Key | `stream?user=obs&pass=<key>` |
| Use authentication | ✗ off |
| Multitrack Video (if present) | ✗ off |

`sudo vrc-stream info` on the server prints the exact server and key. Copy the key **in full**, including `stream?user=obs&pass=`.

---

## 3. Output

**Settings → Output → Output Mode: Advanced**

### Streaming tab

Choose the encoder for your GPU. A GPU encodes with almost no load on your game or OBS; use the CPU (x264) only if you have no suitable GPU.

| Setting | NVIDIA NVENC H.264 | AMD H.264 (AMF) | Intel QuickSync H.264 | x264 (CPU) |
|---|---|---|---|---|
| **⚠ Video Encoder** | NVIDIA NVENC **H.264** | AMD HW **H.264** | QuickSync **H.264** | x264 |
| **⚠ Rate Control** | CBR | CBR | CBR | CBR |
| Bitrate | per profile in section 1 | per profile | per profile | per profile |
| **⚠ Keyframe Interval** | **1 s** | **1 s** | **1 s** | **1 s** |
| Preset | P5: Slow (Good Quality) | Quality | TU4 / Balanced | veryfast |
| Tuning | High Quality | — | — | — |
| Multipass Mode | Two Passes (Quarter Resolution) | — | — | — |
| Profile | high | high | high | high |
| Look-ahead | ✗ off | — | — | — |
| **⚠ Max B-frames** | **0** | **0** | **0** | — |
| Tune (x264) | — | — | — | zerolatency |

- **⚠ H.264 only.** Quest can't play HEVC (H.265) or AV1, and the server with the offline screen won't accept them.
- **⚠ Keyframe interval 1 s** (not 0/auto). Latency depends on it: with "auto" it grows from ~3–5 to 10+ seconds.
- If the server uses `HLS_SEGMENT=2s`, set the interval to **2 s**.
- If x264 overloads your CPU (OBS shows "Encoding overloaded"), switch the preset to `superfast` or pick a lower quality profile.

### Audio tab

| Setting | Value |
|---|---|
| Audio Track 1 bitrate | **160** |
| Streaming track | 1 |

---

## 4. Audio

**Settings → Audio**

| Setting | Value |
|---|---|
| **⚠ Sample Rate** | **48 kHz** |
| **⚠ Channels** | **Stereo** |

**⚠ Important:** with 44.1 kHz the server won't let OBS go live (because of the offline screen, the stream format must match). The server log shows `audio configuration does not match`.

---

## 5. Video

**Settings → Video**

| Setting | Value |
|---|---|
| Base (Canvas) Resolution | 1920×1080 |
| Output (Scaled) Resolution | per profile: 1920×1080 or 1280×720 |
| Downscale Filter | Lanczos |
| Common FPS Values | 30 or 60, per profile |

---

## 6. Advanced

**Settings → Advanced**

| Section | Setting | Value | Why |
|---|---|---|---|
| Video | Color Format | **NV12** | Works with every player |
| Video | Color Space | **Rec. 709** | Correct colors |
| Video | Color Range | **Limited** | With "Full", colors in VRChat look washed out or blown out |
| Automatically Reconnect | Enable | ✓ | If the connection drops, OBS goes live again by itself. Meanwhile viewers see the offline screen |
| Automatically Reconnect | Retry Delay | 2 s | |
| Automatically Reconnect | Maximum Retries | 25 | |
| Network | Dynamically change bitrate | ✓ (optional) | If the streamer's connection struggles, OBS lowers the bitrate instead of dropping |

---

## 7. Check before going live

1. Click **Start Streaming**. The square in the bottom-right corner of OBS should turn green.
2. On the server run `sudo vrc-stream status`. You should see:
   - `● В ЭФИРЕ` (live);
   - `H264 1920x1080` (or 1280x720) and `MPEG-4 Audio 48000 Гц`;
   - a bitrate close to the one set in OBS.
3. Open `https://<domain>/live/stream/` in a browser. You should see the picture and hear the sound.
4. Check the HLS link in VRChat. If you can, check on Quest too.

---

## Common problems

| Symptom | Cause / fix |
|---|---|
| OBS: "Failed to connect to server" | Wrong server or key (copy them again from `sudo vrc-stream info`). Port 1935 is closed at the server's provider |
| OBS can't connect although the key is already fixed | After many attempts with a wrong key, fail2ban bans the IP for 30 minutes. On the server: `sudo vrc-stream status`, then `sudo vrc-stream unban <IP>` |
| OBS connects and immediately disconnects | Audio is 44.1 kHz → set **48 kHz**. Or HEVC/AV1 is selected → set **H.264** |
| 10+ seconds of latency | Keyframe interval is 0/auto → set **1 s** |
| Washed-out or blown-out colors | Color range is "Full" → set **Limited** |
| Viewers buffer while the server is idle | The streamer's upload is too slow: OBS shows a yellow/red square and dropped frames. Lower the bitrate |
| All viewers buffer at the same time | The server's bandwidth is maxed out. Switch to the "Crowd" profile |
| OBS: "Encoding overloaded" | Switch to the GPU encoder or pick a faster preset |
