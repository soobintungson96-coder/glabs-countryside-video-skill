#!/usr/bin/env python3
"""Validate core production invariants of a canonical plan (stdlib only).

This tool validates *planning metadata*; it cannot prove English grammar,
photorealism, licensed music, no spoken audio, or provider/API readiness.
"""
import json
import sys
from pathlib import Path


def validate(plan, execution_ready=False):
    errors, warnings = [], []
    pre = plan.get('preflight_configuration', {})
    production = plan.get('production', {})
    approvals = plan.get('approvals', {})
    shots = plan.get('shots', [])
    provider = plan.get('provider', {})
    audio = plan.get('audio_policy', {})
    seo = plan.get('seo', {})

    if plan.get('schema_version') != '3.4':
        errors.append('Unsupported schema_version (expected 3.4).')
    required = ['target_duration_seconds', 'character_choice', 'location', 'model_id', 'quality_choice', 'output_folder']
    for field in required:
        if pre.get(field) is None or str(pre.get(field)).strip() == '':
            errors.append('Missing preflight field: ' + field)
    if pre.get('character_choice') not in ('user_specified', 'none', 'claude_proposes'):
        errors.append('Invalid character_choice')
    if pre.get('quality_choice') not in ('FULL_HD', '4K_UHD'):
        errors.append('Invalid quality_choice')
    fps = production.get('fps')
    target_sec = pre.get('target_duration_seconds')
    frames = production.get('total_frames')
    if not isinstance(fps, int) or fps <= 0 or not isinstance(target_sec,(int,float)) or target_sec <= 0:
        errors.append('Invalid fps or requested duration')
    elif frames != round(fps * target_sec):
        errors.append('total_frames does not match duration * fps')
    if not shots:
        errors.append('No storyboard shots found')
    shot_frames = 0
    broll_frames = 0
    ids = set()
    for index, shot in enumerate(shots, 1):
        ident = shot.get('id')
        if ident in ids:
            errors.append(f'Duplicate shot id: {ident}')
        ids.add(ident)
        if shot.get('order') != index:
            errors.append(f'Unordered shot: {ident}')
        n = shot.get('duration_frames')
        if not isinstance(n, int) or n <= 0:
            errors.append(f'Invalid duration_frames: {ident}')
            continue
        shot_frames += n
        if shot.get('scene_type') == 'BROLL':
            broll_frames += n
        elif shot.get('scene_type') != 'MAIN':
            errors.append(f'Invalid scene type: {ident}')
        for key in ('image_prompt','video_prompt','negative_prompt','audio_prompt'):
            if not isinstance(shot.get(key), str) or not shot[key].strip():
                errors.append(f'Missing {key}: {ident}')
    if frames != shot_frames:
        errors.append(f'Shot frame sum ({shot_frames}) != production total_frames ({frames})')
    if shot_frames:
        broll_ratio=broll_frames/shot_frames
        if not (0.20 <= broll_ratio <= 0.30):
            warnings.append(f'B-roll ratio is {100*broll_ratio:.1f}% (advisory target: 20–30%).')
    quality = pre.get('quality_choice')
    if (quality == 'FULL_HD' and production.get('resolution') != '1920x1080') or (quality == '4K_UHD' and production.get('resolution') != '3840x2160'):
        errors.append('Production resolution mismatches quality choice')
    for flag in ('dialogue_enabled','voiceover_enabled','singing_lyrics_enabled','speech_in_background_enabled'):
        if audio.get(flag) is not False:
            errors.append(f'No-dialogue contract violated: {flag} must be false')
    for flag in ('ambient_asmr_enabled','instrumental_music_only','music_license_required'):
        if audio.get(flag) is not True:
            errors.append(f'Audio contract violated: {flag} must be true')
    if production.get('watermark_enabled') is not False or production.get('subtitles_enabled') is not False:
        errors.append('Clean video contract violated')
    seo_title=seo.get('title_en','')
    if not isinstance(seo_title,str) or not seo_title.strip():
        errors.append('Missing English SEO title')
    elif len(seo_title)>100:
        warnings.append(f'English SEO title length is {len(seo_title)} >100; shorten it.')
    elif not seo_title.isascii():
        warnings.append('SEO English title contains non-ASCII characters: check language manually.')
    if not approvals.get('configuration_approved'):
        errors.append('Five-question configuration has not been explicitly approved')
    if execution_ready:
        if not (approvals.get('storyboard_approved') and approvals.get('execution_approved')):
            errors.append('Execution requires storyboard and execution approvals')
        if provider.get('adapter_status') != 'READY':
            errors.append('Execution blocked until a verified provider adapter is READY')
        if str(pre.get('model_id','')).startswith('REPLACE_'):
            errors.append('Execution blocked: example model ID must be replaced')
        if provider.get('render_kind') == 'UNCONFIRMED':
            errors.append('Execution blocked: rendering capabilities are unconfirmed')
    else:
        if not approvals.get('storyboard_approved') or not approvals.get('execution_approved'):
            warnings.append('Plan is a DRAFT: no API execution is authorized.')
        if provider.get('adapter_status') != 'READY':
            warnings.append('G-Labs adapter not verified; do not claim rendering is available.')
    if pre.get('character_choice') == 'none':
        if any(x.get('role') in ('main','pet','human','human_protagonist') for x in plan.get('characters',[])):
            warnings.append('User selected no characters but person/pet character refs exist.')
    return errors,warnings


def main():
    if len(sys.argv) < 2:
        print('Usage: python validate_plan.py <canonical_plan.json> [--execution-ready]')
        return 2
    file=Path(sys.argv[1])
    data=json.loads(file.read_text(encoding='utf-8'))
    errors,warnings=validate(data,'--execution-ready' in sys.argv[2:])
    for x in warnings:
        print('WARNING:',x)
    for x in errors:
        print('ERROR:',x)
    print('RESULT:', 'FAIL' if errors else 'PASS', '|' ,len(errors),'errors,',len(warnings),'warnings')
    return 1 if errors else 0

if __name__=='__main__':
    sys.exit(main())
