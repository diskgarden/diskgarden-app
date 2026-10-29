# DiskGarden

A free disk space analyzer for macOS. It maps every folder on your disk as an
interactive chart, so you can see what is taking up space and clear it safely.

Website and downloads: <https://diskgarden.app>

Requires macOS 15.0 or later. Universal (Apple silicon and Intel).

## About this repository

This is the published source of the released DiskGarden app. Day-to-day
development and the signed release pipeline live in a private repository, and
this one is refreshed at each release — so it has no long commit history, and
release tooling, signing scripts and internal planning notes are not part of it.

Bug reports and feature requests are welcome in the issue tracker. If you want
to send a patch, open an issue first: changes have to be replayed into the
private repository by hand, so it is worth agreeing on the shape of a change
before you write it.

## Layout

| Path | What it is |
| --- | --- |
| `App/` | The SwiftUI app target |
| `Packages/ScanEngine/` | The scanning engine, as a local Swift package, plus the `dgscan` CLI |
| `Helper/` | `DiskGardenHelper`, the privileged helper used for admin-only scans |
| `Tools/` | Icon generation utilities |
| `Releases/notes/` | Release notes, one file per shipped version |
| `project.yml` | XcodeGen project definition — the Xcode project is generated, not tracked |

## Building

```sh
brew install xcodegen
make build     # regenerate the Xcode project and build Debug
make run       # build and launch
make test      # scan engine tests
```

The Xcode project is generated from `project.yml`; edit that rather than the
project file. The app is not sandboxed — it needs to read the whole filesystem
to measure it.

`project.yml` pins DiskGarden's own Apple team, so `make build` as-is only works
with that team's signing identity. To build your own copy, either put your team
ID in `DEVELOPMENT_TEAM` in `project.yml`, or skip signing altogether:

```sh
make build XCB_EXTRA='CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='
```

An unsigned build runs locally but macOS will treat it as unidentified software.

Firebase (Crashlytics and Remote Config) is configured by default:
`App/GoogleService-Info.plist` and its `-Debug` twin are tracked here (client
identifiers only, no server secret), so a fresh clone builds with Firebase on.
A build without that file runs with Firebase off.

## What DiskGarden records

Reading the source is the point of publishing it, so here is what to look for
rather than leaving you to find it in a grep.

**Nothing about what is on your disk ever leaves your Mac.** Scan results, file
names, directory listings and the saved scan archives stay local. DiskGarden has
no account, no sign-in, and links no analytics SDK — there is no event tracking
in this codebase.

Two things do talk to the network, both Firebase and both off entirely in a
build without `GoogleService-Info.plist` (see `App/AppServices.swift`):

- **Crashlytics** — crashes, plus handled errors the app chose to report. Each
  carries a short context label (`"scan"`, `"csv-export"`, …) and a breadcrumb
  log. Note honestly: the underlying system error is attached as-is, and a macOS
  file-system error can include the path of the file it failed on. So a crash
  report can contain a path, though never a listing of your disk.
- **Remote Config** — fetches a handful of settings (for example the kill switch
  for the occasional "share DiskGarden" nudge, and a minimum-version floor used
  to tell very old installs to update). It sends no data about you.

**One local record deserves calling out,** because it is the kind of thing that
looks alarming when you find it yourself. `App/InstallHistory.swift` keeps, on
this Mac only, the date you first opened DiskGarden, the date you last opened
it, the first version you ran, and a launch count. It is stored twice — in
`UserDefaults` and in the app's keychain item — and the keychain copy is there
specifically so the first-open date **survives deleting and reinstalling the
app**.

That is deliberate, and it is not tracking: the reason to keep it is so that if
DiskGarden ever has a paid version, people who used it early can be recognised
as early users, which only works if the date cannot be lost by a reinstall. It
is never transmitted — `InstallHistory` is read by nothing but itself, which you
can check in one grep. You can see it with:

```sh
defaults read app.diskgarden.DiskGarden installHistory
```

and delete it along with the keychain item (service
`app.diskgarden.install-history`) in Keychain Access if you would rather not
keep it.

## Releases and updates

Official builds are signed with Apple Developer ID, notarized, and delivered
through Sparkle from <https://diskgarden.app>. A build you make yourself is not
signed with that identity and will not receive those updates.

## License

DiskGarden is licensed under the Apache License, Version 2.0. The full text is
in [`LICENSE`](LICENSE); copyright and attribution are in [`NOTICE`](NOTICE).

The licences of the third-party components DiskGarden redistributes — Sparkle
(MIT), the Firebase Apple SDK (Apache-2.0) and their dependencies — are
reproduced in [`docs/THIRD-PARTY-LICENSES.md`](docs/THIRD-PARTY-LICENSES.md).

"DiskGarden" is the name of this project and of the application. Section 6 of
the Apache License grants no trademark rights, so the licence lets you use,
modify and redistribute the source but not the name.
