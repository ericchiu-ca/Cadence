# Releasing Cadence on TestFlight / the App Store

Signing and submission need your Apple Developer account, so these steps happen in Xcode and App Store Connect, not in this repository.

## 1. Developer account

- Join the Apple Developer Program (USD 99/year) with the Apple ID that should appear as the publisher.
- In *Certificates, Identifiers & Profiles*, register these identifiers (or let Xcode create them on first signing):

| Identifier | Type |
|:--|:--|
| `io.github.ericchiuca.cadence` | App ID (main app) |
| `io.github.ericchiuca.cadence.PlayerWidget` | App ID (widget extension) |
| `io.github.ericchiuca.cadence.Share` | App ID (share extension) |
| `io.github.ericchiuca.cadence.SiriIntentsExtension` | App ID (Siri extension) |
| `group.io.github.ericchiuca.cadence` | App Group |
| `iCloud.io.github.ericchiuca.cadence` | iCloud container |

- Enable the capabilities each target uses: App Groups, iCloud (iCloud Documents) and Siri.
- **CarPlay**: the CarPlay audio entitlement has to be [requested from Apple](https://developer.apple.com/contact/carplay/). The project ships without it so it can be signed by any team; once granted, add `com.apple.developer.carplay-audio = YES` back to `Cosmos Music Player.entitlements`. The CarPlay scene code is already in the app.

## 2. Project settings

- The project is set to team `A9A5LS66BT`; to build your own copy, select your team on all four targets.
- Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` for every upload.
- Optional: add Spotify / Discogs keys through a `.env` file bundled at build time. Note that any key shipped inside an app can be extracted from it; prefer leaving online artist info disabled, or proxying it through your own server.

## 3. App Store Connect

Everything that goes into the listing - name, texts in English and Simplified Chinese, keywords, review notes, privacy answers - is in [APPSTORE.md](APPSTORE.md); screenshots are in [appstore/](appstore/) and the privacy policy is [PRIVACY.md](PRIVACY.md).

- Create the app record with the name **Cadence** (the LICENSE forbids using the name "Cosmos Music Player" or its branding).
- Privacy: the app works offline and collects no data. If you enable online artist lookups, declare that artist names are sent to Spotify/Discogs, and that lyric lookups send title, artist, album and duration to lrclib.net.
- Provide a **link to the source code** (this GitHub repository) in the description or support URL. The GPL requires recipients to be able to get the corresponding source.
- Attribution: mention "Based on Cosmos Music Player" in the description. Nominative references like this are explicitly allowed by the license exception.

## 4. Upload

1. Xcode → *Product › Archive* (scheme "Cosmos Music Player", any iOS device).
2. *Distribute App › App Store Connect*.
3. Test through TestFlight, then submit for review.

## Licence checklist for every release

- [ ] LICENSE (GPLv3 + App Store exception) unchanged in the repository
- [ ] Source for the exact released version pushed and tagged (`git tag v<version>`)
- [ ] App name and icon are Cadence's own, not Cosmos'
- [ ] Original copyright notices kept
