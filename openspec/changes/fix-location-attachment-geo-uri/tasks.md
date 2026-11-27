# Tasks

## 1. Location attachments depend on geo_uri only

- [x] 1.1 In `test/neoment-events-test.el`, `neoment-events-attachments`: remove `(url . "mxc://s/l")` from the `m.location` case so it uses only `geo_uri` `geo:-23.5,46.6`, keeping the map-URL assertion. Add `(should-not (att "m.location" '((url . "mxc://s/l"))))` (url without `geo_uri`) and `(should-not (att "m.location" '((geo_uri . 5))))` (non-string `geo_uri`). Run `make test` and confirm that only the non-string assertion fails.
- [x] 1.2 In `neoment-events.el`, `neoment-events--content-attachment`: change the location guard from `(alist-get 'geo_uri content)` to `(stringp (alist-get 'geo_uri content))`, and update the docstring to say "a string `geo_uri'". Verify that `make test` passes, including the assertions from 1.1.
- [x] 1.3 In `neoment-events-edit-attachment-keep-and-location`, after the edit into a location, apply a second edit of `$t` from the same sender with `m.location` `m.new_content` `((geo_uri . 5))` at ts 5. Assert that the attachment still has url `https://maps.google.com/?q=1.5,2.5`, then verify with `make test`.

- [x] 1.4 Review follow-up: an unparseable string `geo_uri` (`""`, `foo`) still produced a URL-less location. Add `neoment-events--geo-url` (anchored `geo:lat,lon` with numeric coordinates, optional `,alt`/`;params`), use it in `neoment-events--attachment` and as the location guard in `neoment-events--content-attachment`. Test `5`, `""`, `foo`, `geo:`, `geo:-,-`, `geo:1.,2`, `xgeo:1,2`, `geo:1,2x` give no attachment, `geo:1.5,-2,30;u=10` maps to `?q=1.5,-2`, and edits with `5`, `""`, `foo` are applied (edit timestamp advances) but keep the location URL.

## 2. Integration check

- [x] 2.1 Run the full `make` (byte-compile with warnings as errors, lint, test) and verify it is green.

## Workflow follow-up

- Archive after review. It modifies the "Attachments" requirement in `openspec/specs/matrix-events/spec.md` and is independent of `apply-attachment-from-edits`, which can be archived before or after it.
- Close issue #21 with the PR (`Fixes #21`).
