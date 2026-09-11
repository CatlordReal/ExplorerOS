# Phone integrations

The Phone tab provides local notes, phone status, calendar/reminder cards, and
Shortcut setup. Mail integration is intentionally absent: the public interfaces
used here do not expose an inbox that can be read on Glass.

## Add Shortcuts

Tap **Add** beside a preset to share its signed `.shortcut` file. Open the file
in Shortcuts and confirm **Add Shortcut**. If Shortcuts is absent from the share
sheet, use **Save to Files**, then open the saved file. Import is user-controlled;
the app does not silently create shortcuts or report that import succeeded.

**Run** uses the preset's exact name. **Custom Shortcut names** lets you substitute
an existing shortcut. The Focus presets use Do Not Disturb; edit the Set Focus
action in Shortcuts to choose another mode. Silent Mode availability depends on
the iPhone model and iOS. Configure the Action Button in iPhone Settings.

The encrypted link accepts only fixed `phone.action` identifiers: `focus.on`,
`focus.off`, `silent.on`, `silent.off`, `notes.create`, and `notes.browse`.
A received request queues for foreground review on iPhone. It never runs a
Shortcut automatically or claims Focus/ringer state changed. Pending requests
are de-duplicated, bounded, and cleared on disconnect. Opening Shortcuts proves
handoff only, not successful execution.

Apple documents [file sharing/import](https://support.apple.com/guide/shortcuts/apdf01f8c054/ios)
and [running an existing shortcut by URL](https://support.apple.com/guide/shortcuts/apd624386f42/ios).
The supported creation URL opens a blank editor; it is not a template installer.
Our Add buttons use files exported/signed for this project instead.

## Notes

**Quick Notes** belong to Explorer Link. Create them in the Phone tab or through
the Create quick note App Intent. They are stored locally with complete file
protection and excluded from backup. Limits: 500 notes, 512 UTF-8 bytes per title,
4,096 bytes per body. **Show on Glass** sends a selected note.

The Show quick notes on Glass App Intent starts browsing. An authenticated
Glass `notes.browse` request does the same when local notes exist and no route
is active. Swipe left/right to browse and down to leave. An active route has
priority. Local notes do not access Apple Notes or a remote database.

Apple Notes uses Shortcuts' own actions and permissions. The public handoff
`explorerlink://preview?text=...` places supplied text into a visible draft.
The user still taps **Send to Glass** or **Save note**. The latter writes only
to Explorer Link's local Quick Notes. The Create Note preset asks for text and
opens this draft; it does not create an Apple Notes record.

Browse Notes chooses an Apple Note and requests its text representation. Native
Notes metadata advertises text export, but whether this conversion includes the
complete body still needs an iPhone test. A title-only result must not be treated
as successful body transfer. Longer notes need shortening before this handoff.

The handler accepts at most 4,096 UTF-8
bytes and rejects extra parameters, alternate commands, credentials, and URLs
with unexpected paths/fragments. It never connects, transmits, or saves a note
as a side effect of opening the URL.

## Weather and music

The Weather preset obtains current conditions and temperature. Recognize Music
uses the Shazam action and formats the title and artist. Each URL-encodes its
result into the same draft for review and explicit sending to Glass. Shortcuts
controls location, microphone access and availability. These actions were signed
and statically checked, not executed against real location or audio during
development. They do not add a background weather service or streaming player.

## Phone, Calendar, and Reminders

**Send phone status** reports battery level/charging state and local time. A
missing battery reading is labelled unavailable.

**Send next events** asks for calendar access only when pressed, then sends up
to three events in progress or in the next 24 hours. **Send reminders** similarly
asks for reminder access and sends up to five incomplete reminders, due-first.
These features do not create, modify, or complete Calendar/Reminders records.
Requests cancel on disconnect or leaving the screen; permission and send failures
are displayed. Automated tests use synthetic data, never personal records.

## Voice and notifications

Glass consumes ANCS and AMS directly. Notification actions only execute when
iOS advertises the corresponding action. ANCS does not carry arbitrary dictated
reply text; the generic notification reply-and-send workflow is not implemented.

See [FEASIBILITY-HFP.md](FEASIBILITY-HFP.md) for the stock Glass headset Siri
adapter and its real-device gates. App dictation is separate from Siri, and
global Siri transcripts remain unavailable. A Bluetooth voice-audio indicator
must not be interpreted as proof of Siri's exact listening or speaking phase.
