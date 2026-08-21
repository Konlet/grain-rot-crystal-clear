# CrystalClear

Grain Rot's audio settings only give you a **microphone threshold**: when the mic is considered open. They do not strip the hiss, fan, AC, and keyboard rattle that still ride along once you are talking.

CrystalClear turns on Unreal Engine's unused microphone noise gate and keeps it applied for the whole session. Background noise below the gate is silenced before it hits proximity chat. Your in-game threshold slider is left alone.

## Install

1. Open [r2modman](https://thunderstore.io/c/grain-rot/p/ebkr/r2modman/) or the Thunderstore Mod Manager.
2. Select **Grain Rot**.
3. Install **CrystalClear**. The manager pulls in [GrainRot UE4SS](https://thunderstore.io/c/grain-rot/p/Thunderstore/GrainRot_UE4SS/) for you.
4. Start the game modded.

## Config

Edit `config.ini` in the mod folder, then restart the game.

In r2modman: **Settings → Browse profile folder**, then open `shimloader/mod/` and find the CrystalClear folder.

```ini
Enabled = 1
Suppression = 60
Verbose = 0
```

| Key | Default | Range | What it does |
| --- | --- | --- | --- |
| `Enabled` | 1 | 0 or 1 | Master switch. `0` leaves the microphone untouched. |
| `Suppression` | 60 | 0–100 | How hard to push background noise down. `0` is off, `100` is aggressive. |
| `Verbose` | 0 | 0 or 1 | Extra re-apply lines in `UE4SS.log` |

Optional overrides, if you want to skip the `Suppression` mapping:

```ini
GateThreshold = 0.10
AttackTime = 0.02
ReleaseTime = 0.18
```

| Key | Default | Range | What it does |
| --- | --- | --- | --- |
| `GateThreshold` | derived | 0.0–1.0 | Linear amplitude for the gate. Higher = more noise cut. |
| `AttackTime` | 0.02 | 0–2 | Seconds for the gate to open when you start talking. |
| `ReleaseTime` | derived | 0–2 | Seconds for the gate to close after you stop. Raise this if word endings get clipped. |

Start at 60. If teammates still hear your keyboard, raise it. If the starts of words get eaten, lower it.

## Who needs it

| Player | Need the mod? |
| --- | --- |
| You (host or joiner) | Yes, for your own microphone |
| Friends in the lobby | No |

This is client-side. It only processes **your** mic before the game sends it. Friends hear the cleaned audio whether or not they install it. It does not clean anyone else's mic.

## Notes

- Does not change the in-game microphone threshold slider.
- Does not change enemy hearing, voice volume, or push-to-talk.
- Look for `[CrystalClear]` lines in `UE4SS.log` to confirm the gate applied.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
