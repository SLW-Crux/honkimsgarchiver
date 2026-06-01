# iMessage Archiver by Honk

Archive your iMessage history before macOS's **"Keep Messages: 1 Year"** setting deletes it.

Website · **[honkimsgarchiver.com](https://honkimsgarchiver.com)**

---

## Download

### Mac app

The notarized DMG ships from this repo's GitHub Releases:

**[Latest release →](https://github.com/SLW-Crux/honkimsgarchiver/releases/latest)**

Direct download (always points at the most recent release):

```
https://github.com/SLW-Crux/honkimsgarchiver/releases/latest/download/HonkiMessageArchiver.dmg
```

System requirements: **macOS 26+** on Apple Silicon. Full Disk Access required on first launch.

### iPhone / iPad app

Install from the App Store *(listing goes live with v1.0.0)*:

[App Store — iMessage Archiver by Honk](https://apps.apple.com/) *(link will activate at launch)*

System requirements: **iOS 26+**.

---

## What's in this repo

- **GitHub Releases** — the signed, notarized Mac DMG.
- **Python extraction reference** *(coming with v1.0.0)* — the original Python implementation of the `chat.db` extraction algorithm, published as a code reference for developers who want to understand how the archive is built or write their own tool. MIT-licensed.

The production Mac and iOS apps are written in Swift; the Swift source is not published here.

---

## How it works

The Mac app:

1. Opens `~/Library/Messages/chat.db` **read-only and immutable**.
2. Snapshots it into a working directory (the live database is never touched).
3. Decodes every chat, message, and attachment into a portable `.imarchive` bundle.
4. SHA-256 verifies every attachment before atomically promoting the archive to its final location in **your own iCloud Drive**.
5. The iPhone app reads the same bundle from your iCloud — same UI, on the go.

No account. No server. No telemetry. The only network traffic is iCloud sync between your own Apple devices.

Full feature tour: **[honkimsgarchiver.com/features.html](https://honkimsgarchiver.com/features.html)**
Support / FAQ: **[honkimsgarchiver.com/support.html](https://honkimsgarchiver.com/support.html)**
Privacy: **[honkimsgarchiver.com/privacy.html](https://honkimsgarchiver.com/privacy.html)**

---

## License

MIT for the Python extraction reference (when published). The compiled Mac app in the DMG is distributed under the terms shown at install time.
