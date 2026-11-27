# Spec Delta

## MODIFIED Requirements

### Requirement: Attachments
Messages with msgtype `m.image`, `m.file`, `m.audio` or `m.video`, and `m.sticker` events (as image), all with an mxc `content.url`, SHALL carry an attachment. `m.location` messages SHALL carry one only when `content.geo_uri` is a string starting with `geo:lat,lon` (numeric `lat` and `lon`, optionally followed by `,altitude` or `;parameters`), regardless of `content.url`; any other `geo_uri` gives no attachment. The media download URL is `<hs>/_matrix/client/v1/media/download/<server>/<id>`. Video and location thumbnails come from `info.thumbnail_url`/`thumbnail_info`. A location `geo:lat,lon` maps to `https://maps.google.com/?q=lat,lon`.

#### Scenario: Image attachment
- **WHEN** an `m.image` has url `mxc://s/abc`
- **THEN** the attachment url is `<hs>/_matrix/client/v1/media/download/s/abc` and `mxc_url` is `mxc://s/abc`

#### Scenario: Location with geo_uri and no url
- **WHEN** an `m.location` message has `geo_uri` `geo:-23.5,46.6` and no `url`
- **THEN** it has a location attachment whose url is `https://maps.google.com/?q=-23.5,46.6`

#### Scenario: Location with url but no geo_uri
- **WHEN** an `m.location` message has `url` `mxc://s/l` and no `geo_uri`
- **THEN** it has no attachment

#### Scenario: Location geo_uri with altitude and parameters
- **WHEN** an `m.location` message has `geo_uri` `geo:1.5,-2,30;u=10`
- **THEN** it has a location attachment whose url is `https://maps.google.com/?q=1.5,-2`

#### Scenario: Location with an unusable geo_uri
- **WHEN** an `m.location` message has `geo_uri` `5`, `""`, `foo`, `geo:`, `geo:-,-` or `xgeo:1,2`
- **THEN** it has no attachment

#### Scenario: Edit with an unusable geo_uri keeps the location
- **WHEN** a location message with `geo_uri` `geo:1.5,2.5` is edited by its sender with an `m.new_content` of msgtype `m.location` and `geo_uri` `5` or `""`
- **THEN** the edit is applied and the message keeps its attachment with url `https://maps.google.com/?q=1.5,2.5`
