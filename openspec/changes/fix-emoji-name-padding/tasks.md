# Tasks

## 1. Regression tests (failing first)

- [x] 1.1 In `test/neoment-room-test.el`, add ERT tests for `neoment-room--pad-name` covering: twenty `❤️` (currently signals `wholenump`), twenty fullwidth characters (expect one space + nine characters, 18 columns), a run of ZWJ family emoji, and a 25-character ASCII name (expect its first 19 characters). Each test asserts `(string-width result)` = 19 and that the result's visible part is a prefix of whole glyphs from `string-glyph-split` of the input. Verify by running `make test` and seeing the `❤️` case fail with `wholenump`.

## 2. Fix name truncation

- [x] 2.1 Rewrite `neoment-room--pad-name` in `neoment-room.el`: when `(string-width name)` > `neoment-room-name-width`, build the name from leading `string-glyph-split` glyphs while `string-width` stays within the limit, and clamp the padding with `(max 0 …)`. Verify that the tests from 1.1 pass with `make test`.
- [x] 2.2 Verify that the existing header tests ("Short name alignment", "Long name truncation") still pass unchanged, and that `make compile` and `make lint` are clean.

## 3. Manual check

- [ ] 3.1 Open the room that showed `Error running timer 'neoment-ui-flush': (wrong-type-argument wholenump -5)` and confirm that it renders, `*Messages*` shows no such error, and the emoji sender's gutter lines up with the others.
