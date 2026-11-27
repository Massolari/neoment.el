# Proposal

## Why

In a GUI Emacs whose default font is not a Nerd Font (for example Iosevka), the room icon `󰮧` (U+F0BA7) in the room list shows up as a hex box reading `0F0BA7`. A Nerd Font with that glyph is installed (`Symbols Nerd Font Mono`, `JetBrainsMono Nerd Font`), but Emacs never chooses it. Glyphs in the Basic Multilingual Plane, such as the bubble edges U+E0B6, still resolve through Emacs's normal font fallback. The Material Design glyphs in plane 15 (U+F0001–U+F1AF0) don't, and neither Neoment nor the user's config maps that range to a font. The same affects every other plane-15 default icon: `buffer`, `space`, `low_priority`, `bell`, `image`, `file` and `location`.

Today the only advice is the README's "install a Nerd Font or use the plain preset". That doesn't help a user who already has the Nerd Font installed. A user who has no Nerd Font gets boxes until they find the preset by hand.

## What Changes

- In a GUI frame, Neoment SHALL route the private-use code points of its icons and bubble edges to an installed Nerd Font. It does this by adding the font to the default fontset as a lower-priority (appended) entry, so fonts the user already set for those characters still win. The family comes from a new option, `neoment-icon-font-family` (default `"Symbols Nerd Font Mono"`, `nil` disables it). Nothing happens when that family is not installed.
- In a GUI frame, a default icon that still can't be displayed SHALL fall back to its plain Unicode counterpart, in the same way the bubble edges fall back today. Icons the user sets in `neoment-icons` are used as written.
- The README's plain icon preset becomes a constant, `neoment-plain-icons`, that both the fallback and users (`(setq neoment-icons neoment-plain-icons)`) can use.
- The README "Icons and fonts" and "Troubleshooting" sections are updated.

No breaking changes. Terminal frames behave as before.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `client-configuration`: adds two requirements next to "Icons". "Nerd Font routing for icons" covers the fontset mapping and the `neoment-icon-font-family` option. "Plain icon fallback" covers per-icon fallback in GUI frames and the `neoment-plain-icons` preset. The existing "Icons" requirement is unchanged.

## Impact

- `neoment-config.el`: `neoment-plain-icons`, `neoment-icon-font-family`, and fallback-aware `neoment-icon`.
- `neoment-faces.el`: fontset setup function, called before GUI rendering alongside the existing bubble-edge selection.
- `neoment-rooms.el`, `neoment-room.el`, `neoment-space.el`, `neoment-room-info.el`: call sites that already compute bubble edges per frame also trigger the font setup. Icon call sites are unchanged.
- `README.md`, `test/neoment-foundation-test.el`.
- The global default fontset gets appended entries for a few dozen code points at most. It needs no new dependencies.
