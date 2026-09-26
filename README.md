# TWiT Go

TWiT Go is an independent Android and iOS companion for discovering, listening to, and watching TWiT's public shows. This repository contains a Kotlin Multiplatform media spike: shared Compose controls with native playback and offline-download adapters. The public RSS catalog UI follows in the next iteration.

## Project layout

- `shared/` — Kotlin Multiplatform code and shared Compose UI.
- `androidApp/` — Android launcher.
- `iosApp/` — iOS launcher and Xcode project.

## Build

- Android: with JDK 17 and Android SDK Platform 37 installed, run `./gradlew :androidApp:assembleDebug`.
- iOS: open `iosApp/TWiTGo.xcodeproj` in Xcode 26.4.x, select the `TWiTGo` scheme and a signing team, then run the app. The build phase compiles the shared Kotlin framework.

Dependency versions are pinned in `gradle/libs.versions.toml`; CI build commands are in `.github/workflows/build.yml`. The `com.example.twitgo` app ID is a placeholder and must be replaced before distribution.
