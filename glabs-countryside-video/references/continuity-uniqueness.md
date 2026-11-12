# Episode memory, continuity and B-roll uniqueness

## Persistent history

Store at minimum in `project_history/episodes.json`:
- episode ID, original title, English SEO title, core activity, recipe/task, cast and location IDs, season/time
- approved story beats and final shot descriptions
- footage asset IDs, content hashes/fingerprints and output file paths
- completion date/status (DRAFT/APPROVED/RUNNING/COMPLETED/FAILED)

And for each shot: `scene_id`, `scene_type`, `action_verb`, `subject`, `object`, `purpose`, `camera`, `environment`, `prompt_hash`, `clip_checksum`, `semantic_signature` and `duration_frames`.

## Novelty gates

1. **Core episode novelty (hard gate):** If the new title maps to the same core task/recipe as a completed prior episode, warn user; ask for a genuinely new activity or explicitly approved variation before writing nearly identical storyboards.
2. **Exact asset duplication (hard gate):** Never reuse a generated media file (`asset_id`, checksum/hash) from past episodes, including B-roll, unless user explicitly directs reuse.
3. **Semantic shot duplication (review gate):** Compare action + subject + object + camera + purpose + environment against history. Any substantially identical combination must be redesigned rather than merely renumbered.
4. **Same-world continuity:** Reuse a character, pets, architecture and natural design language if requested, without repeating filmed action.
5. **Unavailable history:** Say that uniqueness against unseen past work cannot be guaranteed. Never fabricate a completed library.

## B-roll timing and diversity

- Start at a target 25% of frame count (recommended range 20–30%); not mandatory for very short/atypical storylines.
- Insert at chapter boundaries, after completed actions, or for meaningful spatial/temporal transitions.
- Match biome, place, season, weather and time of day. Bird species or farm animals must be plausible in that location.
- Example subject/action combinations (adapt to episode): butterfly lands on a lavender blossom; cattail nods in breeze; barn cat stretches on veranda; bee moves from flower to flower; farm dog watches a worker; grass sways in the morning light.
- Reject arbitrary B-roll that breaks causality, uses a seasonal mismatch or distracts at a critical action moment.
- Ambient audio bridges can begin slightly before the next scene if it supports natural continuity; never use dialogue to bridge.

## Continuity checklist

- Character look and clothes, handedness, companion animal coat colors
- Distinct objects and ingredient inventory; location of baskets, bowls, knives and vehicles
- Landscape, tree type, season, time, weather, architecture
- Logical transition of ingredient states: harvested → cleaned → prepared → cooked → served
- No magic state changes or morphing within a shot; use explicit cuts and pre-staged states where needed
- Sound matches material and physics, and **contains no speech**
