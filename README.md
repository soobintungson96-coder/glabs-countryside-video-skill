# G-Labs Countryside Video — Claude Code Skill

Claude Code skill that plans, generates and edits **no-dialogue, cinematic countryside / slow-living ASMR videos** with **G-Labs Studio** (local webhook API), then packages a YouTube-ready folder (video, thumbnail, SEO, metadata).

Skill version: **v3.7** — see [`glabs-countryside-video/SKILL.md`](glabs-countryside-video/SKILL.md) for the full rules (Vietnamese) and [`glabs-countryside-video/README.md`](glabs-countryside-video/README.md) for the file guide.

## Features
- 5-question intake, two approval gates, no paid API calls before approval
- Reference images (characters, master setting, props) generated and QC'd **before** any video
- Storyboard builder with exact frame totals, wardrobe variants, camera-lock prompts, rule checks (one task per character, slow/static camera, logical sound, B-roll ratio)
- Parallel clip generation (up to 20 in flight), resumable, auto-retry, QC contact sheets
- Master assembly: QC trims, 1080p upscale, **GPU encoding** (NVENC → QSV → AMF → CPU), colour grades, 2-pass loudness + limiter, optional licensed music
- Per-title delivery folder `YouTube/<Title>/` with `youtube_metadata.json` (YouTube Data API v3 shape, AI-content disclosure)
- Reference-video analyser (cuts, pacing, colour, loudness, contact sheets) + "Harvest & Cook" style preset

## Install
1. Copy the `glabs-countryside-video` folder into your workspace: `<workspace>/.claude/skills/glabs-countryside-video/`.
2. Create `<workspace>/.env.glabs` from [`.env.glabs.example`](.env.glabs.example) with your own G-Labs webhook key (**never commit it**).
3. Requirements (Windows): G-Labs Studio running with the webhook enabled (default `http://127.0.0.1:8765`); Windows PowerShell 5.1; ffmpeg is taken from the G-Labs Studio install (`scripts/*.ps1` → `$ff` path — adjust if your install path or user name differs).
4. In Claude Code: `/glabs-countryside-video dựng video với tiêu đề: <title>` or `/glabs-countryside-video gợi ý tiêu đề về ...`.

## Notes
- Background music must be licensed (e.g. YouTube Audio Library, "Attribution not required").
- Realistic AI footage must be disclosed on YouTube ("Altered or synthetic content").
- `references/style-samples/` contains frames from third-party reference videos for internal style study only — keep this repository **private** or remove that folder before making it public.
