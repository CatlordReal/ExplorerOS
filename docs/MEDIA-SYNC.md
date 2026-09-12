# Camera media sync

Camera sync is optional and off by default on both devices. It uses the existing
authenticated Explorer Link TCP session, never BLE. On Glass, turn on **Setup >
Camera sync**. On iPhone, open **Glass media** and turn on **Receive media from
Glass**. The iPhone must remain foregrounded on observed Wi-Fi and advertise
`media.receive.tcp.v1`; Glass sends only after that capability is present.

Glass discovers a bounded set of API 19 MediaStore entries below `DCIM/Camera`.
It accepts only regular JPEG, PNG, MP4, and 3GPP files with matching headers. It
does not delete, rename, or edit original captures. Each transfer has a random
wire ID, SHA-256, fixed 3,072-byte chunks, one outstanding acknowledgement, and
a 30-second idle limit. Images are limited to 50 MiB, videos to 250 MiB, and one
authenticated session to 500 MiB.

The iPhone writes chunks only after all protocol gates pass, acknowledges after a
successful write, verifies byte count and streaming SHA-256, then records media
under a locally generated name in a complete-file-protected, backup-excluded app
vault. The vault accepts at most 1,000 captures or 1 GiB; incomplete files are
removed on cancellation, disconnect, foreground loss, or integrity failure.
Completed verified hashes deduplicate. A failed index commit remains a
conservatively quota-counted private orphan rather than becoming a false in-memory
deduplication result. A corrupt, oversized, or otherwise unreadable index disables
receiving until the private vault is repaired; it never starts with an uncounted
quota.

Gallery browsing never reads the Photos library. **Preview** uses native Quick Look
and its system sharing controls. **Save to Photos** asks for add-only Photos
permission when pressed. No transfer
imports, deletes, or changes a Glass source. Host tests and simulator fixtures do
not prove physical Camera storage access, XE24 MediaStore behavior, iPhone Wi-Fi
delivery, or Photos export; test those on the intended Glass and iPhone.
