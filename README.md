# SoundPing

Find out where the latency in your music setup comes from.

SoundPing runs named tests ("recipes"). A recipe pairs a trigger with a listener:

- **Trigger:** a click, a MIDI note sent by the tool, or a real key press.
- **Listener:** the MacBook's microphone, or a loopback into your audio interface.

Each test fires many hits and shows a speed-test-style result: the median latency, the jitter and a graph. That lets you trace a laggy feel to its cause (MIDI transport, your DAW, the output chain, the speakers or headphones) instead of guessing.

## Status

🚧 The engine and CLI are being built. There is no release yet.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Contributions require signing the [CLA](CLA.md).

## Licence

Free for anyone to use, including professionally. You may modify and share it, but not offer a competing product. Source-available under [PolyForm Shield 1.0.0](LICENSE).

The licence is deliberately strict for now and may be relaxed to a more open one later.
