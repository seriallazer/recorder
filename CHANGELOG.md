# Changelog

All notable user-visible changes will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project intends to use semantic versioning once public releases begin.

## [Unreleased]

### Added

- Public architecture, privacy, security, testing, contribution, and release documentation.
- Source CI for Swift tests, app assembly, and static bundle checks.
- Apache License 2.0 project terms and expanded third-party attribution.

### Changed

- Clarified the boundary between the pinned Swift dependency and mutable runtime model artifacts.
- Made the app build script configurable for public bundle identifiers, versions, signing identities, and signing timestamps.

### Security

- Removed a personal device name from the current test fixture.
- Added ignore rules for common environment and Apple signing files.
