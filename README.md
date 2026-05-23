# Media Duplicate Reviewer 2.1 — update notes

This build replaces version 2.0 after testing revealed selection and orientation issues.

## Fixed in 2.1

- Rotated/orientation-equivalent dimensions such as `1936 × 2592` and `2592 × 1936` are treated as the same dimensions after a visual match.
- For a very strong visual match (Vision distance ≤ 0.060) with the same format and rotation-equivalent dimensions, the smaller file is suggested for Trash even when the size difference is under 3%.
- Same-dimension HEIC/JPEG visually matched pairs suggest keeping HEIC.
- Visual matches that overlap into multiple rows do **not** auto-select a deletion candidate; this prevents pair-by-pair suggestions from selecting both sides of another row.
- Before moving files to Trash, the app blocks deletion when both sides of any visual-match row are selected.
- Video candidates are now narrowed with indexed perceptual fingerprints at the 10%, 50%, and 90% samples before Apple Vision confirmation, reducing large duration-based comparison sets.
- Exact duplicate scanning still works across and within selected roots; Root A / Root A results are expected when two copies exist within that tree.
- Possible Live Photo companion warnings remain in-memory and conservative.

## Safety

Only byte-identical SHA-256 duplicate groups are definitive duplicates. Visual matches remain review items. Test this version before moving files to Trash.
