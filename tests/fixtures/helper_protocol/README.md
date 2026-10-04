# Helper protocol fixtures

Shared by the Swift app's tests (`macos/HASatellite`, `swift test`) and the Python
socket backends, so both sides of the contract in `plans/audio.md` section 6 read
and write the same bytes.

- `frames.json`: valid frames. `hex` is the whole frame (8-byte header, then the
  payload). JSON payloads are in `json`, encoded canonically:
  `json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`
  in Python, `JSONSerialization` with `.sortedKeys` and `.withoutEscapingSlashes`
  in Swift. `pcm_mic` has the `index` and `samples` of a `mic` PCM payload,
  `pcm_play_s16le` its raw payload in `payload_hex`. `from` is the sender:
  `client` (Python) or `helper` (the app).
- `errors.json`: byte streams a parser must refuse, with the error code sent in
  the `protocol_error` EVENT before the connection is closed (`truncated` is
  detected at end of stream).
- `hello.json`: client HELLOs and the outcome: the parsed `role` (and `format`
  for play roles) or the `refusal` reason of the HELLO reply.
- `sessions.json`: ordered exchanges per role (`steps` name frames of
  `frames.json`) and snapshot sequences on one control connection (`accepted`
  is whether each `rev` replaces the state shown; stale ones are ignored).
