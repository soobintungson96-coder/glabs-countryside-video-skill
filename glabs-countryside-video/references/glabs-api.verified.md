# G-Labs Studio — verified local adapter (2026-11-11)

Source: live probing of the local G-Labs Studio webhook + the API guide embedded in
`G-LabsStudio.exe`. Only items marked **verified** were tested against the running server.

## Connection
- Base URL: `http://127.0.0.1:8765` (G-Labs Studio desktop app must be running; webhook autostart on).
- Auth: header `X-API-Key: <key>` (**verified**; `Authorization: Bearer` is rejected with 401).
- Secret lives in `<project>/.env.glabs` (`GLABS_BASE_URL`, `GLABS_API_KEY`, `OUTPUT_ROOT`). Never print it.
- Adapter: `scripts/glabs.ps1` (PowerShell 5.1; Python is not installed on this machine).

## Endpoints
| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/api/health` | no | **verified** `{"status":"ok","server":"G-Labs Webhook",...}` |
| GET | `/api/tasks` | yes | **verified** list tasks |
| GET | `/api/characters` | yes | **verified** character library (currently empty) |
| POST | `/api/image/generate` | yes | async → 202 + task_id |
| POST | `/api/video/generate` | yes | async → 202 + task_id |
| POST | `/api/grok/generate`, `/api/meta/generate`, `/api/openai/generate` | yes | other providers |
| POST | `/api/upscale/generate` | yes | local Real-ESRGAN image upscale |
| GET | `/api/status/{task_id}` | yes | status / progress / error_code |
| GET | `/api/result/{task_id}` | yes | result + meta (only when completed) |
| GET | `/api/files/{filename}` | yes | serve output file |
| POST | `/api/stop[/{task_id}]` | yes | stop one / all pending tasks (avoid wasted quota) |
| POST/PUT/PATCH/DELETE | `/api/characters[/{name}]` | yes | manage character library |
| POST | `/api/preupload`, `/api/characters/preupload` | yes | pre-upload refs to accounts |

## Accounts configured in the app (no secrets)
- Google Flow: 1 account, tier **ULTRA** → Veo 4K output and Veo 4/6 s clips allowed.
- Google Vids: 1 account (`omni_vids`, 720p/1080p, 3–10 s).
- Meta Muse: 5 accounts (`meta_muse`).

## Model IDs seen (ask the user to pick; do not choose silently)
Video: `veo_31_fast` (Veo 3.1 Fast), `omni_flash` (Omni Flash), `omni_vids` (Google Vids), `meta_muse`; Grok/Meta via their own endpoints.
Image: `nano_banana_2`, `nano_banana_pro`, `nano_pics`, `meta_muse`.
The full model table is served by the G-Labs server inside the app UI (Webhook page) and is not
exposed over HTTP — confirm model availability by submitting only after plan approval.

## Video request (POST /api/video/generate)
```json
{
  "prompt": "motion description",
  "model": "veo_31_fast",
  "aspect_ratio": "16:9",
  "mode": "start_image",                 // text_to_video | start_image (1 ref) | start_end_image (2) | components
  "reference_images": ["file:D:\\...\\ref.png"],   // glabs.ps1 converts file: to data URI
  "resolution": ["1080p"],               // "720p" | "1080p" | "4K" (4K needs ULTRA) ; omni_flash also "360p"
  "video_length": 8,                     // Veo 4/6/8 (4/6 need ULTRA); Omni Flash 4/6/8/10; Vids 3–10
  "remove_logo": true
}
```
**No-dialogue policy:** never send `voice`; do not use `components` mode with voice. Veo/Muse
generate audio natively — QC every clip for speech and replace audio with licensed ASMR if needed.

## Image request (POST /api/image/generate)
```json
{ "prompt": "...", "model": "nano_banana_pro", "aspect_ratio": "16:9",
  "reference_images": ["file:D:\\...\\char.png"], "upscale": ["2K"] }   // "4K" upscale needs ULTRA
```

## meta_muse measured output (verified 2026-11-11)
- Image: ~2048x1152 JPG for 16:9; `results` holds `/api/files/...` URLs; ~40 s per image.
- Video (`image_to_video`, 2 refs, `video_length: 8`): 1280x720, 24 fps, 8.00 s, H.264 + AAC mono 24 kHz; ~2.5 min per clip.
- Completed task JSON: `{task_id, type, status, prompt, results:[url], meta:{mode, aspect_ratio, count, account}}`. No credit cost reported.
- Plan Muse projects at 24 fps; Full HD = 1.5x upscale in edit.
- Content policy: a failed task returns `error: "CONTENT_POLICY - Muse answered without an image/video"` (code 400). Bed/sleep scenes with words like "nightgown", "barefoot" were refused; "modest, high-necked flannel sleepwear, body under a wool blanket" passed. Keep wardrobe wording modest for any bed/washing/dressing shot.

## 4K note
`resolution: ["4K"]` on Veo is produced by Google's upscale path — treat as **upscaled 4K, not native**,
and tell the user before choosing 4K.

## Not yet verified
Exact shape of `/api/result` payload and output file naming (`glabs.ps1 download` handles
`/api/files/...` URLs and local paths generically). Credit cost per task. Verify on the first approved job.
