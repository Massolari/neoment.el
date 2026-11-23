# Design

## Context

See proposal.md (Why) for the symptom. What I observed on the reporting machine:

- The default face is `Iosevka` (`~/emacs/init.el`). It is not a Nerd Font.
- `fc-list ":charset=f0ba7"` lists `Symbols Nerd Font Mono` and `JetBrainsMono Nerd Font`, so the glyph is installed. An old v2 `JetBrains Mono … Nerd Font Complete.ttf` is also installed; v2 has no glyphs in plane 15.
- `nerd-icons` is loaded, but its `nerd-icons-set-font`, which maps `#xf0001–#xf1af0` to the Nerd Font, is never called. Emacs's automatic fallback still finds fonts for the BMP private-use glyphs (bubble edges, `people`, `invite`…), so those render. It does not find one for the plane-15 Material Design glyphs, so those show as hex boxes.
- The running daemon reachable via `emacsclient` only had a tty frame. A GUI frame wasn't available for inspection, so the "BMP works, plane 15 doesn't" split is inferred from the report plus the fontset state. I didn't measure it directly.

Today `neoment-icon` (`neoment-config.el:129`) is a plain alist lookup. Bubble edges already have a per-frame displayability fallback: `neoment-faces-bubble-edges` checks `char-displayable-p` in GUI frames, and its result is bound to `neoment--bubble-edges` by each renderer (`neoment-rooms.el:441`, `neoment-room.el:548`, `neoment-space.el:135,157`, `neoment-room-info.el:186`).

## Goals / Non-Goals

**Goals:**
- Default icons render as Nerd glyphs whenever a Nerd Font is installed, whatever the default face font is.
- When no font can draw a default glyph, show a readable one-column plain icon instead of a box.
- No change in terminal frames and no change for users who set their own icons.

**Non-Goals:**
- Detecting the v2 vs v3 Nerd Font codepoint layout or remapping old v2 codepoints.
- Making the user's other packages' icons (`nerd-icons`, doom-modeline) work. The fontset entries are limited to Neoment's own code points.
- Choosing a font automatically from several candidates. One configurable family is enough.

## Decisions

### 1. Route Neoment's code points through the default fontset with `append`

`neoment-faces-setup-icon-font` (new, in `neoment-faces.el`) does the following once per session, the first time it is called while the selected frame is graphical:

1. Returns immediately when `neoment-icon-font-family` is `nil`, or when `(find-font (font-spec :family F))` is `nil`.
2. Collects every character in `#xE000–#xF8FF` or `#xF0000–#xFFFFD` from the values of `neoment-icons`, `neoment-default-icons`, and the two bubble edge glyphs.
3. Calls `(set-fontset-font t CHAR (font-spec :family F) nil 'append)` for each one.
4. Clears the icon fallback cache (decision 3).

A guard variable records which family was applied. If the option changes, the function runs again (`:set` on the defcustom resets the guard).

Why the default fontset `t` and `append`: frame fontsets fall back to the default fontset, so one call covers every current and future GUI frame, including daemon frames. `append` puts our entry after any the user configured for that character, so it only fills gaps.

Why only Neoment's code points, not whole ranges like `nerd-icons-set-font`: it is a smaller global side effect, and it doesn't change how other packages' glyphs are resolved.

Alternatives considered:
- **Call `nerd-icons-set-font`.** Rejected: it adds a dependency, uses `prepend` on whole ranges of the frame fontset, and does nothing for users without nerd-icons.
- **Only document the fix in the README.** Rejected: the user already has the font installed, so Neoment should just work.
- **`prepend`.** Rejected: it would override a font the user deliberately chose.

### 2. Call the setup where bubble edges are computed

`neoment-faces-bubble-edges` is already called before every GUI render, per frame. It will call `neoment-faces-setup-icon-font` first, which makes the call cheap and idempotent. That puts the fontset routing in place before both the bubble edge check and any icon check, with no new hooks at the call sites. The pickers (`neoment-rooms.el:890`) render without bubbles, so `neoment-pick-room` also calls the setup directly.

### 3. Per-icon fallback inside `neoment-icon`

`neoment-plain-icons` (new defconst in `neoment-config.el`) is the README preset, verbatim. `neoment-icon` becomes:

- Look up the value as today.
- If the selected frame is graphical, the value is `equal` to the key's entry in `neoment-default-icons`, and the value contains a character that `char-displayable-p` rejects, return the plain icon for that key. Otherwise return the value.

The "still default" check means a user's own choice is never replaced, which matches the spec. Displayability results are cached in a hash table keyed by character. The table is cleared by `neoment-faces-setup-icon-font` and by `neoment-faces--update` (theme/font changes), so the room list (hundreds of lines) doesn't repeat font lookups. `char-displayable-p` is the same predicate the bubble edges already rely on.

Alternative considered: a single global switch to the plain preset when any icon fails. Rejected, because one missing glyph would downgrade icons that render fine.

### 4. Terminal frames

Terminal frames skip both the routing and the fallback, as the bubble edges do today. In a tty, `char-displayable-p` reports the terminal coding system rather than actual glyph coverage, so the check would be meaningless there.

## Risks / Trade-offs

- [`char-displayable-p` can return non-nil for a font that lacks the glyph (for example, the v2 Nerd Font claiming the PUA range)] → Routing to a v3 family by default reduces this. A user can still set `neoment-icons` to `neoment-plain-icons`.
- [Mutating the global default fontset is a side effect outside Neoment] → Entries are limited to Neoment's own code points and appended, and `neoment-icon-font-family nil` opts out.
- [The cache is stale after the user installs a font mid-session] → It is cleared on theme or face updates and when the font option changes. Restarting Emacs also fixes it.
- [Mixed frames (GUI + tty in one daemon)] → The decision uses the selected frame at render time, the same as the bubble edges. A buffer rendered in a GUI frame and later shown in a tty might keep Nerd glyphs, which matches the current bubble behaviour.

## Migration Plan

No migration is needed. Users who copied the README preset keep it, and it is now also available as `(setq neoment-icons neoment-plain-icons)`. To roll back, revert the commit. The fontset entries vanish on restart.
