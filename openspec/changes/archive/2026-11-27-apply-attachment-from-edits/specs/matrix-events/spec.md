# Spec Delta

## ADDED Requirements

### Requirement: Edits carry attachments
When an applied `m.replace` edit has an `m.new_content` whose `msgtype` is an attachment type (image, video, audio, file or location) with an mxc `url` (or, for a location, a `geo_uri` of the form `geo:lat,lon` as defined in Attachments), the target message's attachment SHALL become the one it describes, built as for a normal message of that type. This SHALL hold for live, pending and embedded (`unsigned["m.relations"]["m.replace"]`) edits.

#### Scenario: Notice edited into a video
- **WHEN** an `m.notice` message `$n` from `@alice:s` is edited by `@alice:s` with `m.new_content` of `msgtype` `m.video`, `url` `mxc://s/vid`, `filename` `video.mp4` and `info` `{duration: 12000, w: 480, h: 864, size: 2726771, mimetype: "video/mp4"}`
- **THEN** message `$n` has a video attachment with that url, duration, size and mimetype, and its content is the edit's `body`

#### Scenario: Edit embedded in the original event
- **WHEN** the original event arrives with an `unsigned["m.relations"]["m.replace"]` from the same sender whose `m.new_content` is a video
- **THEN** the message has the video attachment

#### Scenario: Pending edit with an attachment
- **WHEN** an edit with a video `m.new_content` arrives before its target, and the target then arrives from the same sender
- **THEN** the target has the video attachment

### Requirement: Edits keep or ignore attachments
An edit whose `m.new_content` has no attachment MUST leave the target's existing attachment unchanged. An edit that is ignored (other sender, state target, redacted target, older edit) MUST NOT change the attachment.

#### Scenario: Text edit keeps the attachment
- **WHEN** a message with an image attachment is edited with a plain `m.text` `m.new_content`
- **THEN** the message shows the new text and keeps its image attachment

#### Scenario: Ignored edit does not add an attachment
- **WHEN** `@mallory:s` sends an `m.replace` with a video `m.new_content` for a text message from `@alice:s`
- **THEN** the message has no attachment

### Requirement: Location messages have an attachment
A message with `msgtype` `m.location` and a `geo_uri` of the form `geo:lat,lon` (as defined in Attachments) SHALL have a location attachment, even though it has no `url`.

#### Scenario: Regular location message
- **WHEN** a message with `msgtype` `m.location` and `geo_uri` `geo:1.5,2.5` arrives
- **THEN** it has a location attachment whose url is `https://maps.google.com/?q=1.5,2.5`

#### Scenario: Message edited into a location
- **WHEN** a text message is edited by its sender with an `m.new_content` of `msgtype` `m.location` and `geo_uri` `geo:1.5,2.5`
- **THEN** the message has the location attachment
