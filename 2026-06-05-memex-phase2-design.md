# Memex Phase 2 — Embedded Metadata Extraction (Basic Design)

**Date:** 2026-06-05
**Status:** Draft — basic design to work from later. **Do not implement now.**
**Depends on:** Phase 1 (`2026-06-05-memex-client-design.md`) shipped.
**Cross-repo / OP skill pointers:** see the *Implementing-Agent Reference (Cross-Repo)* section in the Phase 1 doc — the same OP skills (`octothorpes` skill, `harmonizers.md`), core files, and package-consumption notes apply. Phase 2 work lives in the separate Memex repo (extractors in the ingest agent), except any new vocab predicates that need package-side projection support, which land in `@octothorpes/core`.

---

## Goal

Phase 1 launches with **human curators** as the only source of *descriptive* metadata (`dcterms:*` via `about=` pages). Phase 2 adds an **embedded-metadata extractor** that reads metadata baked into the files themselves (EXIF, ID3, PDF info/XMP, container metadata), plus media-specific vocabulary and a provenance/precedence model so machine-extracted and human-asserted facts coexist cleanly.

Because Phase 1's vocabulary is purely additive, Phase 2 adds only **more predicates on the same subject** — no rework of identity, relationships, or the ingest pipeline.

---

## Vocabulary additions (additive)

- **`schema.org` MediaObject subtypes** for format-specific fields:
  - `schema:ImageObject` → `schema:width`, `schema:height`, `schema:encodingFormat`, EXIF capture data.
  - `schema:AudioObject` → `schema:duration`, `schema:encodingFormat`, bitrate.
  - `schema:VideoObject` → `schema:duration`, `schema:width/height`, codec.
  - `schema:encodingFormat` everywhere for precise MIME/codec.
- **PREMIS fixity** — record the hash as a first-class fixity event, not just an opaque id:
  - `premis:fixity` / `premis:messageDigest` = the sha256, `premis:messageDigestAlgorithm` = "SHA-256".
  - Self-describing preservation metadata; the id *is* the fixity value.
- All remain in `documentRecord` projection space, namespaced, with declared ranges (consistent with #194 when it lands).

---

## Embedded extractors (per media class)

Run inside the **ingest agent**, gated behind a config flag (off by default to preserve Phase 1 behavior). Each extractor maps embedded fields → namespaced predicates.

| Class | Source | Candidate library |
|---|---|---|
| Image | EXIF / IPTC / XMP | `exifr` |
| Audio | ID3 / Vorbis / container tags | `music-metadata` |
| Video | container/codec metadata | `ffprobe` (via `fluent-ffmpeg`) or `music-metadata` |
| PDF | Info dict + XMP | `pdfjs-dist` / `pdf-lib` |
| Text | none (structural only) | n/a |

Extractors emit into a distinct **provenance bucket** (see below) so embedded values never silently overwrite curator assertions.

---

## Provenance & precedence model (the core of Phase 2)

The asset record now accretes "standard properties" from **three sources**:

1. **Structural** — agent-derived filesystem facts (`memex:*`). Authoritative for what they describe; never contested.
2. **Embedded** — machine-read from file bytes (Phase 2).
3. **Asserted** — human curator via `about=` pages (Phase 1).

**Precedence rule (proposed):** for any *descriptive* predicate where multiple sources offer a value (e.g. title), **curator assertion wins; embedded fills gaps**. Structural facts occupy disjoint predicate space and never conflict. Options to decide at implementation time:

- **Accumulate + provenance tags** — keep all values, attach a source qualifier (blank node carrying `prov:wasGeneratedBy` / source), let the blobject projection pick the display value by precedence. Most faithful to OP's accumulate-don't-overwrite tendency. *Recommended.*
- **Overwrite by precedence** — single value per predicate, curator > embedded. Simpler reads, lossy.

Embedded values should land on predicates that *don't* collide with curator predicates where possible (e.g. embedded title → `schema:name`/a qualified node, leaving `dcterms:title` curator-owned), so "curator wins" is structural rather than a runtime contest.

---

## Edit lineage (annotation continuity across hash changes)

Editing/re-encoding a file changes its bytes → new `memex://` id. Phase 2 preserves continuity:

```
<memex://m1/{newHash}>  prov:wasDerivedFrom  <memex://m1/{oldHash}> .
```

- The agent detects this as the "edited" case (path known in manifest, hash changed).
- Annotations/octothorpes on the old id are **not** auto-migrated, but the lineage link makes them discoverable and lets tools optionally propagate.
- Open question: auto-propagate curator annotations across `wasDerivedFrom`, or surface for manual confirmation?

---

## Tie-in to on-request DR harmonization (#166)

Rather than persist all embedded content at ingest time, Phase 2 may store a **harmonizer reference** and extract on request (the #166 pattern):

```
<memex://m1/{sha256}>  octo:harmonizeWith  <harmonizer-id> .
```

At request time, re-read the file through the referenced harmonizer and project an ephemeral `documentRecord`. Keeps heavy/voluminous embedded metadata out of the triplestore while still queryable on demand. Depends on #166 landing.

---

## Open Questions

- Accumulate-with-provenance vs overwrite-by-precedence (recommended: accumulate).
- Auto-propagation of annotations across `prov:wasDerivedFrom`.
- Which embedded fields are worth persisting vs computing on-request (#166).
- Whether video extraction (ffprobe dependency) is in initial Phase 2 or deferred again.

---

## Out of Scope

- Phase 1 concerns (identity, relationships, ingest agent, manifests).
- Re-processing strategy for the existing corpus when extraction is first enabled (backfill is a separate operational task).
