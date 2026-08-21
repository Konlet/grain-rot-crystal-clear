# Changelog

## 1.0.1

- `website_url` now points at the Konlet GitHub repo.

## 1.0.0

Initial release.

- Applies Unreal Engine's microphone noise gate automatically on launch.
- `config.ini` `Suppression` (0–100) controls how hard background noise is pushed down.
- Optional `GateThreshold`, `AttackTime`, and `ReleaseTime` for fine-tuning.
- Re-applies after voice starts and after the in-game mic threshold is changed, so the game cannot silently wipe the gate.
