# G-Labs adapter integration contract (provider-agnostic; NOT the official G-Labs API)

## Why an adapter is mandatory

The Claude Skill emits a **canonical plan**. There is no verified G-Labs Studio API endpoint, authentication, model catalog, duration set, image reference format or output-quality contract included in the project notes. Therefore the fields in this package **must not** be posted directly to a guessed URL.

## Required adapter interfaces

| Method | Inputs | Required return |
|---|---|---|
| `list_models()` | credentials from protected server configuration | exact available model IDs, display names |
| `get_capabilities(model_id)` | model ID | allowed durations/resolutions/aspect ratios, image-to-video, subject reference support, negative prompt support, audio support, costs where available |
| `generate_reference_image(prompt, options)` | character/location prompt | `job_id`, async state or completed `asset_id` |
| `generate_image(prompt, ref_asset_ids, options)` | still prompt and supported reference IDs | `job_id` / `asset_id` |
| `generate_video(model_id, image_asset_id, motion_prompt, options)` | supported duration/resolution/audio options | `job_id` |
| `get_job_status(job_id)` | job ID | `queued/running/succeeded/failed` and actionable failure codes |
| `download_asset(asset_id, destination)` | trusted asset ID, safe output path | local path, checksum, media metadata |
| `cancel_job(job_id)` | job ID | if provider supports cancellation |

The exact endpoint, JSON keys, authentication and status codes **must be mapped after reading actual G-Labs documentation / inspecting authorized API responses**.

## Validation before generation

1. Resolve `model_id` exactly from user's chosen model.
2. Check `image_to_video` supported; distinguish reference control (person/animal/style) versus image conditioning.
3. Check clip length options against storyboard shot length. Build longer source clips and trim; do not stretch audio/video unnaturally.
4. Check aspect ratio and output resolution. Record `render_kind: native_4k | upscale_4k | full_hd`; seek user approval for substitution.
5. If model cannot generate no-dialogue audio reliably, discard source audio when appropriate and provide controlled ASMR Foley/ambience, ensuring no hidden speech.
6. Explain unsupported features and options; no silent model switching.

## Orchestration and safety

Persist `project_id`, `episode_id`, `scene_id`, `attempt`, `job_id`, `asset_id`, `status`, `created_at`, `completed_at`, `model_id`, `error_code`, `qc_report` in job manifest. Implement retry with exponential backoff and a configured maximum. Do not retry non-idempotent job submission without a deduplication/job recovery strategy. Respect service quotas, billing and terms. Do not log authentication tokens or signed media URLs. Sanitize filenames and make all output paths descendants of the configured `OUTPUT_ROOT`.

## Editing pipeline

Normalize approved clip frame size, pixel format, fps, orientation, sample aspect ratio and codec to an editing mezzanine, then trim exactly `duration_frames` and concatenate with hard cuts. Use FFmpeg or approved editor; do not rely on unverified effects or blanket slow-motion. Build ambient and Foley layers per shot, use short audio overlaps/crossfades when beneficial, mix a permitted instrumental bed, and export AAC audio (48 kHz recommended). Check no discernible speech/lyrics.

## Output verification

After render, inspect file with an actual media probe (e.g. ffprobe), check width/height, fps, video duration, audio presence, clear frame, no speech, storyboard continuity, plus manual checks for generative artifacts. On failure, publish state `NEEDS_HUMAN_REVIEW` or `FAILED_RETRY_LIMIT`, not `COMPLETED`. Store episode fingerprints only after completion.
