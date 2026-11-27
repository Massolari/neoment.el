# Proposal

## Why

Issue #21: `m.location` messages carry `geo_uri`, not `url`, so the old `(and type (alist-get 'url content) ...)` check dropped every real location attachment. The code half of the fix has already landed with `apply-attachment-from-edits` (PR #49): `neoment-events--content-attachment` now requires `geo_uri` for locations, and `neoment-events-location-without-url` covers it. The issue's case (`geo_uri "geo:1,2"`, no `url`) now yields `https://maps.google.com/?q=1,2`. Three parts of the issue are still open:

- The `neoment-events-attachments` test still adds a fake `url` (`mxc://s/l`) to its location content, so it doesn't test the real event shape.
- The main `matrix-events` "Attachments" requirement still says every attachment type, location included, needs `content.url`. `apply-attachment-from-edits` only *adds* a location requirement, so after it is archived the spec would contradict itself.
- The location check only tests that `geo_uri` is non-nil. A non-string `geo_uri` (for example `5`) still builds an attachment with no URL, so an edit with that content replaces a working location with a broken one. The helper's docstring says this must not happen.

## What Changes

- A location attachment requires a string `geo_uri`; it never depends on `url`. A non-string `geo_uri` gives no attachment. For an edit, that means the existing attachment is kept.
- Drop the fake `url` from the location case in `neoment-events-attachments`. Add assertions that `url` alone (no `geo_uri`) gives no location attachment, and that a non-string `geo_uri` gives none either.
- Reword the `matrix-events` "Attachments" requirement: media types and stickers need an mxc `content.url`, and `m.location` needs a `geo_uri`.
- Out of scope: map providers other than Google Maps, parsing `geo:` URIs with altitude or `;u=` parameters beyond the current `lat,lon` prefix match, and location thumbnails (unchanged).

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `matrix-events`: the "Attachments" requirement states that a location needs `geo_uri`, not `content.url`.

## Impact

- `neoment-events.el`: `neoment-events--content-attachment` (location guard).
- `test/neoment-events-test.el`: `neoment-events-attachments` location case, plus new negative assertions.
- `openspec/specs/matrix-events/spec.md`: updated on archive. If `apply-attachment-from-edits` is archived first, this delta still applies cleanly, because it only modifies "Attachments".
