# Memex — Local Archival OP Client Design

**Date:** 2026-06-05
**Status:** Draft
**Scope (this doc):** Phase 1 architecture for a local, push-based OP client that describes a digital archive of media files, PDFs, and text files. Covers `packages/core/` additions, a standalone ingest agent (`scripts/` or its own package), and the curator/static-site integration surface. Phase 2 (embedded-metadata extraction) has its own doc: `2026-06-05-memex-phase2-design.md`.

---

## Problem

We want to describe a local digital archive — directories of standard media files, PDFs, and text files — using OP, where **the OP triplestore is the source of truth**. Every quality of an asset (including its local path) is queryable through a stable id. This departs from OP's standard `url = object` model: assets are not web pages and have no canonical dereferenceable URL. A static site will later integrate with this client so that URLs can carry descriptions and annotations (octothorpes) for assets.

Two asks:
- **(a)** How to structure the asset records.
- **(b)** How to implement a tool that makes records for 10k+ local assets simply and repeatably.

---

## Relationship to Existing Roadmap

This is not a new mechanism — it is the concrete realization of concepts already sketched in `vocabulary-design.md`:

- **`documentRecord`** is the established name for client-specific structured content projected onto a blobject. Harmonizers already emit it (`harmonizers.js`), the HTML handler passes it through (`handlers/html/handler.js`), and publishers read from `documentRecord.*` (`publishers.js`). Memex's archival fields project into this sub-object.
- **Client vocabulary config (#194)** — planned `createClient({ vocabulary })` that registers namespaced predicates + ranges and projects them into `documentRecord`. **Not yet built** (`vocabulary.js`, `validateClientVocab`, `mergeVocab` do not exist).
- **Canonical Document Records (CDRs)** — `vocabulary-design.md`'s closing open question: "records originated in the datastore (not harmonized from external sources), keyed to internal URI schemes." Memex **is** that design pass.
- **On-request DR harmonization (#166)** — still a TODO in `v07-tracker.md`; relevant to Phase 2, not Phase 1.

**Sequencing decision:** Phase 1 does **not** block on the full #194 system. Spec #1 implements a *minimal vocab registration* — just enough to declare the `memex:`/`dcterms:` predicates and ranges needed to write and project `documentRecord` — designed to slot into #194 when it lands. Memex may drive a thin first slice of #194.

---

## Core Concepts

### 1. Content-addressed identity (the one departure from `url = object`)

Assets are identified by a **content hash**, not a URL:

```
memex://{memexId}/{sha256}
```

- `{memexId}` — a centrally-assigned, collision-free, per-install slug (not a sequence number). Assumed governed externally.
- `{sha256}` — hash of the **file bytes**. The id *is* the asset's fixity value (self-describing preservation metadata).
- An RDF subject URI is a **name, not a locator** — nothing requires it to be dereferenceable. The triplestore can hold any URI as a subject.

**Consequences (accepted as correct archival behavior):**
- *Identical bytes collapse to one id* — free deduplication. The same file in three folders is one asset with three locations.
- *Editing/re-encoding mints a new id* — bytes are the artifact. Annotations on the old id do not auto-follow; Phase 2 adds a lineage link (`prov:wasDerivedFrom`).
- *Filename and path are irrelevant to identity* — rename/move freely; they are mutable properties.

### 2. Two-stage indexing

- **Ingest** — hash the bytes, mint the `memex://` id, write the Document Record (structural facts + any descriptive facts available).
- **Locate** — register a **referrer** that points at the id. The filesystem path is the first and most important referrer. Moving a file **adds a referrer to the existing id**; it never re-ingests.

This inverts standard OP from *pull* (relay fetches a URL) to *push* (a local agent walks the filesystem and writes records). New OP clients may carry index-policy settings enabling active/push indexing; Memex assumes that capability.

### 3. Relationships — all native OP, no new relationship vocabulary

Every **location** is still `url = object` — a normal addressable node that *references* the content-addressed record. The departure is confined to the record layer.

**Associative / referrer (the gallery).** A location references an asset exactly as a Page octothorpes a Term:

```
<file:///Volumes/arch/audio/cyl0421.wav>   octo:octothorpes  <memex://m1/{sha256}> .
<https://archive.example/gallery/edison>   octo:octothorpes  <memex://m1/{sha256}> .
<file:///Volumes/backup/old.wav>           octo:octothorpes  <memex://m1/{sha256}> .   # former path, kept as provenance
```

A gallery is a referrer with its own identity and its own tags; **gallery tags do not confer to assets** (nothing says they should — standard OP). Existing backlink/reference queries now answer "where does this asset live?" and "what references it?" for free.

**Assertive / descriptive (the curator's record page).** A curator authors a document whose statements are *about the asset*. OP already supports this via RDFa's `about` attribute and `getStatementsAboutOtherSubjects` in `ld/rdfa2triples.js`:

```html
<div about="memex://m1/{sha256}">
  <span property="dcterms:description">A wax cylinder recording of…</span>
  <a property="octo:octothorpes" href="/~/edison">edison</a>
</div>
```

On indexing, those statements land on the **asset record**, not the curator's URL. No per-asset endpoint configuration is needed — the markup declares the subject. The only new requirement: OP must accept `memex://` as a legal subject URI (`uri.js`). The same page may mix `about=` description blocks with ordinary referrer links.

---

## Data Model

### URI scheme

`memex://{memexId}/{sha256}` — authority = memexId, path = the sha256. Parsed by a small scheme module; registered as a legal subject scheme in `uri.js` (alongside HTTP and AT Protocol).

### Predicates — disjoint structural vs descriptive space

Source separation guarantees no collisions across the agent, curators, and (Phase 2) embedded extractors.

**Structural / fixity (agent-written):**

| Predicate | Meaning |
|---|---|
| *(the id)* `memex://m1/{sha256}` | content hash = fixity |
| `memex:path` | a referrer location (may be many; written as referrer nodes, see below) |
| `memex:filename` | filesystem name (a fact, **not** the canonical title) |
| `memex:byteSize` | file size in bytes |
| `memex:mediaType` | detected MIME type |

**Descriptive (curator-written, Phase 1):**

| Predicate | Meaning |
|---|---|
| `dcterms:title` | canonical title (curator-owned) |
| `dcterms:description` | description |
| `dcterms:creator` | creator/author |
| `octo:octothorpes` | subject terms / cross-asset links |

`memex:filename` is deliberately **not** `dcterms:title`, so when Phase 2's embedded reader and curators both assert titles, there is never contention over the canonical one.

### Graph shape (referrer nodes, not opaque path strings)

Locations are first-class subjects that `octo:octothorpes` the record — **not** literal properties hanging off it. This makes paths queryable through existing OP endpoints and unifies filesystem paths, site URLs, and galleries as one kind of thing.

```
<memex://m1/{sha256}>  a memex:Asset ;
    memex:filename "cyl0421.wav" ;
    memex:byteSize 80422 ;
    memex:mediaType "audio/wav" ;
    dcterms:title "Edison Favorite" ;          # curator-asserted
    dcterms:description "…" ;                   # curator-asserted
    octo:octothorpes <…/~/edison> .

<file:///Volumes/arch/audio/cyl0421.wav>  octo:octothorpes <memex://m1/{sha256}> .
```

### Blobject projection

The archival fields project into the established **`documentRecord`** sub-object (same mechanism harmonizers/publishers already use), keeping Memex consistent with the rest of OP:

```json
{
  "@id": "memex://m1/{sha256}",
  "octothorpes": ["edison"],
  "documentRecord": {
    "title": "Edison Favorite",
    "description": "…",
    "filename": "cyl0421.wav",
    "byteSize": 80422,
    "mediaType": "audio/wav"
  }
}
```

---

## Architecture — decomposed into three specs (build in order)

### Spec #1 — Core protocol support (smallest; unblocks everything)

| Change | File(s) |
|---|---|
| `memex://` scheme parse + validation | `packages/core/uri.js` (+ small scheme helper) |
| `memex` handler: file (bytes + structural facts) → blobject | `packages/core/handlers/memex/handler.js` |
| Accept `memex://` subjects in `about=` retargeting | verify path through `ld/rdfa2triples.js` |
| Resolver publisher: `memex://` → `file:///…` / UI URL | `packages/core/publishers.js` (new publisher) |
| Minimal vocab registration for `memex:`/`dcterms:` + `documentRecord` projection | thin slice toward #194 |

The handler does **content → metadata**; identity (`@id` = the `memex://` URI) is assigned by the storage/ingest step, not the handler — consistent with how the existing registry separates harmonization from identity.

### Spec #2 — The ingest agent (part (b))

A standalone Node tool (own package or `scripts/`) that uses **`createClient` → the `memex` handler → indexer** (no hand-written SPARQL; follows the project's "only use core" rule).

**State model — per-directory portable manifests.** Each asset-containing directory gets a hidden `.memex.json` after its initial scan (excluded from scanning so it is never mistaken for an asset). Entry shape:

```json
{ "filename": "cyl0421.wav", "sha256": "…", "byteSize": 80422,
  "mediaType": "audio/wav", "mtime": 1733000000, "uri": "memex://m1/{sha256}" }
```

- **Manifests travel with assets.** Move a folder to another drive or install and its manifest rides along; a re-scan recognizes every asset by recorded hash+id and just registers the new path. This satisfies "across separate installations."
- **Manifests carry the original memexId.** A folder landing on install `m2` keeps its `memex://m1/…` ids — `m2` adopts identity and adds a local referrer rather than re-minting. The triplestore holds "foreign" memexId subjects without issue.
- **Manifests are a portable cache, never the authority.** Rebuildable from the triplestore if lost.

**Run algorithm:**
1. Walk the tree (excluding `.memex.json`).
2. For each file: pre-check `mtime`+`size` against the local manifest; **skip hashing if unchanged** (the key speedup for 10k+ on re-runs).
3. For changed/new files, hash, then classify:
   - **new to this dir** → ask the triplestore "is this hash known?" → **known** = move/copy (register new referrer to existing id); **unknown** = genuine new asset (ingest + record).
   - **edited** (path known, hash changed) → new id; Phase 2 links lineage.
   - **deleted** (manifest entry, file gone) → mark referrer removed (provenance retained).
4. Update the directory manifest.

Cross-*directory* move detection is resolved via the **triplestore as global index** (per-dir manifests only know their own folder).

CLI: dry-run, scan root(s), concurrency for hashing, memexId from config/`.env`.

### Spec #3 — Curator + static-site integration

- The descriptive `about="memex://…"` authoring workflow (assertive mode) through the standard index endpoint.
- Gallery publishing (associative mode): a curated page that referrer-links a set of assets, with its own tags.
- The static site consumes the resolver publisher to dereference `memex://` ids into displayable assets.

(Static site itself is a downstream consumer; full design is out of scope for this doc.)

---

## Dependencies & Sequencing

- Spec #1 → #2 → #3, strictly ordered.
- #1 carries a **minimal vocab registration** rather than depending on #194's full client-vocab system; forward-compatible with it.
- Active/push index policy on the client is assumed available (work largely in place per project state).

---

## Implementing-Agent Reference (Cross-Repo)

This work spans two repos. **An agent working in the separate Memex repo will not have OP's skills or `packages/core/` source loaded** — this section is the bridge.

### Repo split — what lands where

| Spec | Repo | Why |
|---|---|---|
| **#1 Core protocol support** | `octothorp.es` (this repo), `packages/core/` | Adds the `memex://` scheme, the `memex` handler, the resolver publisher, `about=` acceptance, and the minimal vocab registration **into the package itself**. Cannot be done from the consumer repo. |
| **#2 Ingest agent** | separate Memex repo | Depends on `@octothorpes/core`; hand-writes no SPARQL. |
| **#3 Curator + static site** | separate Memex repo | Consumes the index endpoint + resolver publisher. |

**Build #1 first, here, and publish.** The separate repo consumes `@octothorpes/core` (imported as `octothorpes`). Until published to npm it is only a workspace symlink (see `packages/core/package.json`, currently `0.1.0-alpha.x`) — so the Memex repo needs either (a) the core changes merged and the package published, or (b) a temporary `file:`/git dependency pointing at a local `octothorp.es` checkout. Decide this before starting spec #2.

### OP skills the implementing agent should load

The OP knowledge lives as a project skill in **this** repo at `.claude/skills/octothorpes/`. Install/copy it into the Memex repo (or keep an `octothorp.es` checkout alongside) and invoke `octothorpes`. Most pertinent files for Memex:

| Skill file | Why it matters to Memex |
|---|---|
| `.claude/skills/octothorpes/SKILL.md` | Architecture terms (Core, Relay, Indexer, Publisher, Blobject), repo map, env/SPARQL setup. |
| `.claude/skills/octothorpes/package.md` | `createClient` API, framework-agnostic rules — the agent's primary interface. |
| `.claude/skills/octothorpes/handlers.md` | Handler contract (`mode`, `contentTypes`, `harmonize`), registry dispatch, and the `createClient({ handlers })` extension point for the new `memex` handler. (Full rationale: `docs/plans/point7/2026-05-27-generic-handler-pipeline.md`.) |
| `.claude/skills/octothorpes/publishers.md` | Publisher contract for the `memex://` resolver. |
| `.claude/skills/octothorpes/server-architecture.md` | MultiPass, RDF schema, blank-node subtypes, `about=` retargeting context. |
| `.claude/skills/octothorpes/indexing.md` | Indexing pipeline the agent pushes through. |
| `.claude/skills/octothorpes/harmonizers.md` | Extraction-rule model (relevant to Phase 2 embedded extractors). |

### Key core source files to study (paths in `octothorp.es`)

| File | Purpose for Memex |
|---|---|
| `packages/core/index.js` | `createClient` factory — config shape the agent uses. |
| `packages/core/handlerRegistry.js` | Handler registry; pattern for registering the `memex` handler. |
| `packages/core/handlers/blobject/handler.js` | Simplest handler example (passthrough → blobject). |
| `packages/core/uri.js` | Where `memex://` scheme validation is added. |
| `packages/core/ld/rdfa2triples.js` | `getStatementsAboutOtherSubjects` — the `about=` retargeting Memex relies on. |
| `packages/core/publishers.js` | Publisher registry; where the resolver publisher is added; existing `documentRecord.*` reads. |
| `packages/core/blobject.js` | Blobject projection — where `documentRecord` surfaces. |
| `packages/core/indexer.js` | Push-indexing pipeline. |

### Other reference docs in this repo

- `docs/plans/point7/vocabulary-design.md` — `documentRecord`, client vocab config (#194), CDR open question (Memex's origin).
- `docs/plans/point7/2026-06-05-memex-phase2-design.md` — Phase 2 companion.
- `packages/core/README.md` + `packages/core/CHANGELOG.md` — package API surface and recent changes (no standalone `core-api-guide.md` exists despite the reference in `package.md`).

---

## Open Questions

- **memexId governance.** Format and assignment of the central slug (UUID vs human slug); out of band but must be fixed before multi-install use.
- **Resolver publisher targets.** Does Phase 1 emit `file:///` only, or also a configurable `/api/file/{id}` / static-site URL template?
- **Referrer removal semantics.** On delete, do we hard-remove the referrer node or soft-mark it (mirrors the page-deletion soft/hard pattern)?
- **#194 slice size.** How much of the formal vocab config to build now vs defer.

---

## Out of Scope (this doc / Phase 1)

- Embedded-metadata extraction (EXIF/ID3/PDF/XMP), `schema.org` MediaObject vocab, PREMIS fixity events, edit-lineage linking → **Phase 2** (`2026-06-05-memex-phase2-design.md`).
- The static site implementation.
- Any Dashboard/account concepts (OP Core has no accounts).
- Full #194 client-vocabulary system.
