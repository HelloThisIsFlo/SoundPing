# SoundPing

Find out where the latency in your music setup comes from.

SoundPing runs named tests ("recipes"). A recipe pairs a trigger with a listener:

- **Trigger:** a click, a MIDI note sent by the tool, or a real key press.
- **Listener:** the MacBook's microphone, or a loopback into your audio interface.

Each test fires many hits and shows a speed-test-style result: the median latency, the jitter and a graph. That lets you trace a laggy feel to its cause (MIDI transport, your DAW, the output chain, the speakers or headphones) instead of guessing.

## Test-sound loudness

The test sound may reach your ears, so it never goes above a ceiling.

- **SoundPing picks the ceiling from your output alone:** headphones -30 dBFS (any Bluetooth output, and a built-in output that does not clearly report its speakers), built-in speakers -12, everything else -18 (every interface, virtual device and loop).
- **No setup gets a louder ceiling on its own, loops included.** The ramp starts at -48 dBFS and stops at the first clearly heard probe, so a working loop locks far below -18.
- **`--listener`** tells SoundPing who listens. It picks the chirp band and can lower the ceiling, never raise it.
- **`--max-level`** is the only way to a louder test sound, for example `--max-level -18` for a Bluetooth speaker or `--max-level -6` for a loop that really needs it.
- **`--level`** picks a fixed level instead of the gentle ramp, and is still capped at the ceiling.

## Status

🚧 The engine and CLI are being built. There is no release yet.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Contributions require signing the [CLA](CLA.md).

## Licence

Free for anyone to use, including professionally. You may modify and share it, but not offer a competing product. Source-available under [PolyForm Shield 1.0.0](LICENSE).

The licence is deliberately strict for now and may be relaxed to a more open one later.
