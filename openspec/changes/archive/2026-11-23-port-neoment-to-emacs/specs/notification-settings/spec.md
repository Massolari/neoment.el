# Spec Delta

## Purpose

Lets the user view and change their Matrix push rules from Emacs: global levels for one-to-one and group rooms, and per-room overrides. Reads and writes follow the same rules as Element and the original Neoment.

## ADDED Requirements

### Requirement: Settings window
The settings SHALL open in a pop-up window with a title and a highlighted current line, with the cursor on the current option. RET applies the option and `q`/ESC close the window. While a save is in progress, the title SHALL end with ` (Saving…)` and further RET presses are ignored.

#### Scenario: Double RET while saving
- **WHEN** the user presses RET twice quickly
- **THEN** only one change is applied

### Requirement: Global settings
The global window, titled `Notification settings`, SHALL list `One-to-one rooms (2 members)` and `Group rooms (3+ members)`, each with `All messages` and `Mentions and replies only`. A category is `all` when its underride rule (`.m.rule.room_one_to_one` / `.m.rule.message`) exists, is enabled and contains `notify`. Otherwise it is `mentions`.

#### Scenario: Disabled message rule
- **WHEN** `.m.rule.message` exists but is disabled
- **THEN** Group rooms shows `Mentions and replies only` selected

### Requirement: Writing global settings
Setting a category SHALL handle each existing rule of that category in sequence: one-to-one is `.m.rule.room_one_to_one` and `.m.rule.encrypted_room_one_to_one`, group is `.m.rule.message` and `.m.rule.encrypted`. For each rule it PUTs `underride/<id>/actions` and then `enabled {enabled:true}`. The actions are `["notify",{set_tweak:"sound",value:"default"}]` for one-to-one `all`, `["notify"]` for group `all`, and `[]` for `mentions`. It SHALL stop at the first error.

#### Scenario: First PUT fails
- **WHEN** the first actions PUT fails
- **THEN** no further requests are sent and `Could not change the notification settings: <e>` is shown

### Requirement: Per-room level
The per-room window, titled `<Space/Name>`, SHALL offer `Global settings (<level>)`, `All messages`, `Mentions and replies only` and `None`. The level is `none` when an enabled override `<room_id>` has exactly one `event_match room_id` condition and no `notify`. Otherwise an enabled `room` rule `<room_id>` gives `all` (with `notify`) or `mentions`. Otherwise it is `global`.

#### Scenario: Muted room
- **WHEN** an enabled override `!r:s` matches room_id with empty actions
- **THEN** `None` is selected

#### Scenario: Global label for a DM
- **WHEN** the room has `joined_member_count` 2 (or no count yet and `is_direct`) and one-to-one rooms are at `all`
- **THEN** the first option reads `Global settings (All messages)`

### Requirement: Writing per-room settings
Setting a level SHALL create the new rule before deleting old ones:
- `none` → `PUT override/<room>` with the room_id condition and `[]`
- `all`/`mentions` → `PUT room/<room>` with notify+sound or `[]`

Then it enables a previously disabled rule, deletes the override if the new level is not `none`, and deletes the room rule if the new level is `none`/`global`. Rule ids in paths MUST be percent-encoded.

#### Scenario: From none to global
- **WHEN** a room at `none` is set to Global settings
- **THEN** the override rule `%21r%3As` is deleted and no new rule is created

### Requirement: Reload after change
After any change, successful or not, the client SHALL `GET /pushrules/` and re-render. If only the reload failed it shows `Saved, but could not reload the notification settings: <e>`. If rules are not loaded when the window opens, it fetches them first, and on failure shows `Could not load the notification settings: <e>`.

#### Scenario: Reload fails
- **WHEN** the change succeeds but the reload fails
- **THEN** `Saved, but could not reload the notification settings: <e>` is shown
