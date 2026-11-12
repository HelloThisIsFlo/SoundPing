# Contributing to SoundPing

Thanks for wanting to help. A few things to know first.

## Licence and CLA

SoundPing is source-available under [PolyForm Shield 1.0.0](LICENSE).

Contributions require signing the [Contributor License Agreement](CLA.md). You keep the copyright to your work; the CLA lets the maintainer license it as part of SoundPing, and relicense the project later if needed.

You don't need to do anything up front. A bot (CLA Assistant) asks you to sign on your first pull request, and remembers your answer for the next ones.

## Build and test

You need macOS 15 or later and a Swift 6.2+ toolchain (Xcode 26.x works).

```sh
just test          # runs the unit tests
swift test         # same thing, without just
just cli --version # builds and runs the soundping CLI
```

## Formatting

```sh
just fmt
```

## Before you start

Open an issue before large changes, so we can agree on the direction before you spend the time.
