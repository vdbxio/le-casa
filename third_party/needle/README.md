# Cactus Needle 3 + Whistle

On-device tool calling (Needle 3) and speech-to-text (Whistle) from Cactus Compute,
Apache-2.0 (see `LICENSE`, byte-identical in both Hugging Face repos). Only the C header
and this list are committed. The static libraries and `.cact` weights are fetched from
Hugging Face and checked against the sha256 below.

One `libneedle` runs both models: call `needle_load` once per `.cact`. The C API is in
`needle.h` (identical for every platform). The model is process-global and not
thread-safe, so every call has to go through a single isolate or thread.

## Files we would ship

All files were downloaded on 2026-10-27. The sizes and sha256 values match the LFS oids in the
HF tree listing for the revision named here.

| File | HF repo | HF commit | Path in repo | Size (bytes) | sha256 |
|---|---|---|---|---|---|
| needle3.cact | Cactus-Compute/needle3 | d6c7d6a2e9655505e0f8e23339356dd1705900eb | `needle3.cact` | 35335380 | c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38 |
| whistle.cact | Cactus-Compute/whistle | 741118687e1f008f06d1351a402a731274789790 | `whistle.cact` | 16919407 | b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb |
| libneedle.a (android-arm64) | Cactus-Compute/needle3 | d6c7d6a2e9655505e0f8e23339356dd1705900eb | `android-arm64/libneedle.a` | 2177676 | 7aa6de6132a22bf45f5e903425feb66f159ad46f47fa558921bc4fd02c3a2fa0 |
| libneedle.a (android-armv7) | Cactus-Compute/needle3 | d6c7d6a2e9655505e0f8e23339356dd1705900eb | `android-armv7/libneedle.a` | 1700760 | 9f559a287b201c213e5c753d3cd1076a1849c73f94b445c85d11e4969422a135 |
| libneedle.a (ios-arm64) | Cactus-Compute/needle3 | d6c7d6a2e9655505e0f8e23339356dd1705900eb | `ios-arm64/libneedle.a` | 1501688 | 3e931f1d52319c1396901f3a16244ea47776d18acbf28543b62da408de45158a |
| libneedle.a (ios-sim-arm64) | Cactus-Compute/needle3 | d6c7d6a2e9655505e0f8e23339356dd1705900eb | `ios-sim-arm64/libneedle.a` | 1535472 | 75f836ada53fc55cd27a30e0edaea8bf5dcbcca6e30c9f0202fa192db20cea80 |
| libneedle.a (macos-arm64) | Cactus-Compute/needle3 | d6c7d6a2e9655505e0f8e23339356dd1705900eb | `macos-arm64/libneedle.a` | 1534472 | 7d1368a4a42a745aba055f310913c3ed6d929dee98a89dcb955b9032b2335700 |

Download URL pattern: `https://huggingface.co/<repo>/resolve/<commit>/<path>`.

The PRITOM M10 runs a 32-bit userspace only (`ro.product.cpu.abilist` = `armeabi-v7a,armeabi`),
so it needs the android-armv7 build.

The engine libraries contain no networking: `strings` finds no URLs or socket names, and their
undefined imports are only libc, libm, the C++ ABI, pthread, mmap and stdio. Telemetry exists
only in the `cactus-needle` Python package, not in the C engine.

## Exact C call arguments

These are the strings and buffers passed through ctypes to the package's own engine build
(`libneedle.dylib`, engine 3.3.3, macOS arm64). `needle_load` returned 0 for both models and
`needle_models()` returned 3 (`NEEDLE_TEXT | NEEDLE_SPEECH`).

```
needle_load(<bytes of needle3.cact>, 35335380)  -> 0
needle_load(<bytes of whistle.cact>, 16919407)  -> 0
needle_init(system_prompt, tools_json, NULL)    -> 114   (static prefix tokens)
needle_reset()
needle_complete(input, pcm, samples, 512, out, 65536)
```

`system_prompt` is what `Needle(system=None)` sends: the local date fact only.

```
date: 2026-10-27 Tue 19:27
```

`tools_json`:

```json
[{"name": "set_light", "description": "Set a light's power, brightness and color.", "parameters": {"type": "object", "properties": {"name": {"type": "string", "enum": ["Kitchen strip", "Bed strip"], "description": "Which light"}, "power": {"type": "boolean", "description": "On or off"}, "brightness": {"type": "integer", "description": "Brightness 0-100"}, "color": {"type": "string", "description": "Color name or hex"}}, "required": ["name"]}}]
```

There is no separate options JSON. Audio options for `needle_complete` are set with
`needle_set_audio(language, keywords, word_timestamps)`. It was not called here, so the
defaults applied: detect the language, no keywords, no word timestamps.

Audio: `say -o cmd.aiff "turn the kitchen lights blue"` then
`afconvert -f WAVE -d LEF32@16000 -c 1 cmd.aiff cmd.wav`. That gives 26935 float32 samples
(1.68 s, 16 kHz mono, range [-1, 1]), passed as `pcm` with `input = NULL`.

### Raw `needle_complete` output: audio call

`input = NULL`, `pcm` = the 26935 samples. rc = 52, 48 ms on an M4.

```json
{"type":"call","success":true,"error":null,"error_code":null,"reason":null,"function_calls":[{"name":"set_light","arguments":{"name":"Kitchen strip","color":"blue"}}],"suppressed_calls":[],"reasoning":"'kitchen lights' -> name 'Kitchen lights'; 'blue' -> color 'blue'; brightness not specified so omitted.","confidence":0.2013,"prefill_tps":3061.0,"decode_tps":1568.8,"peak_ram_mb":149.7,"validation":{"ungrounded":[],"negation":false},"audio_text":"Turn the kitchen lights blue.","audio_language":"en","audio_ttft_ms":3.2,"audio_decode_tps":1228.4}
```

### Raw `needle_complete` output: text call

`input = "turn the kitchen lights blue"`, `pcm = NULL`, `samples = 0`. rc = 52, 37 ms.

```json
{"type":"call","success":true,"error":null,"error_code":null,"reason":null,"function_calls":[{"name":"set_light","arguments":{"name":"Kitchen strip","color":"blue"}}],"suppressed_calls":[],"reasoning":"'kitchen lights' -> name 'Kitchen lights'; 'blue' -> color 'blue'; brightness not specified so omitted.","confidence":0.1931,"prefill_tps":3605.5,"decode_tps":1578.8,"peak_ram_mb":150.1,"validation":{"ungrounded":[],"negation":false}}
```

On error `rc < 0`; read `needle_last_error()`. The Python package reads the out buffer as
the error detail for `needle_complete`.

Known model misses on the Mac:

- "switch off the bed strip" returned `set_light(name="Bed strip")` without `power: false`.
- Confidence for the kitchen-blue call is about 0.2 even though the call is right.

Plan for a rule fallback or a confirmation step.

## How the Python package (cactus-needle 3.2.8) builds the C calls

The package never passes PCM to `needle_complete`. `Whistle.transcribe` calls
`needle_transcribe`, and `Needle.complete` calls `needle_complete` with text only. The audio
path in `needle_complete` was exercised directly through ctypes above.

`needle/__init__.py`: library binding, base weight load, init and complete:

```python
def _load_base(lib, generation):
    if generation < 3 or _loaded_base.get(generation):
        return
    path = _base_weights_path(generation)
    with open(path, "rb") as handle:
        data = handle.read()
    if lib.needle_load(data, len(data)) < 0:
        raise RuntimeError(f"needle_load failed for {path}")

def _lib(generation=2):
    ...
        lib.needle_init.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
        lib.needle_init.restype = ctypes.c_int
        lib.needle_complete.restype = ctypes.c_int
        if generation < 3:
            lib.needle_complete.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
        else:
            lib.needle_complete.argtypes = [
                ctypes.c_char_p, ctypes.POINTER(ctypes.c_float), ctypes.c_int,
                ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
        ...
        lib.needle_load.argtypes = [ctypes.c_char_p, ctypes.c_uint64]

class Needle:
    def __init__(self, tools=None, system=None, weights=None, tool_index_path=None, buffer_size=65536,
                 auto_date=True, generation=None, stateless=False):
        ...
        self._system_text = _with_date_fact(system or "") if auto_date else (system or "")
        self._system = self._system_text.encode("utf-8")
        tools_json = tools if isinstance(tools, str) else json.dumps(self._resolve(tools))
        self._tools_json = tools_json.encode("utf-8")
        ...
        self._buffer = ctypes.create_string_buffer(buffer_size)

    def _bind(self):
        ...
        lib = _lib(generation)
        _load_base(lib, generation)
        if _active.get(generation) is self:
            return
        if lib.needle_init(self._system, self._tools_json, self._tool_index_path) < 0:
            raise RuntimeError("needle_init failed")

    def complete(self, text: str = "", max_new_tokens: int = 512) -> dict:
        if self._stateless:
            self.reset()          # -> lib.needle_reset()
        ...
        return self._complete(text, max_new_tokens)

    def _complete(self, text, max_new_tokens=512, ground=True):
        self._bind()
        ...
            audio = (None, 0) if self._generation >= 3 else ()
            rc = lib.needle_complete(
                text.encode("utf-8"), *audio, int(max_new_tokens), self._buffer,
                len(self._buffer))
            if rc < 0:
                detail = self._buffer.value.decode("utf-8", "replace")
                raise RuntimeError(detail or f"needle_complete failed (code {rc})")
            raw = self._buffer.value.decode("utf-8")
        response = json.loads(raw)
        ...  # then Python-side _annotate_ungrounded() edits response["validation"]

def _with_date_fact(system: str) -> str:
    """Prefix the local date fact unless the caller already supplied one."""
    if _DATE_KEY.search(system) or _ISO_STAMP.search(system):
        return system
    now = datetime.datetime.now()
    fact = now.strftime("date: %Y-%m-%d %a %H:%M")
    if not system.strip():
        return fact
    if system.lstrip().startswith("{"):
        return system
    return fact + "; " + system
```

Tools given as dicts go through unchanged (`_resolve` appends the dict), so `tools_json` is
`json.dumps(list_of_tool_dicts)`. `tool_index_path` defaults to `None` (NULL).

`needle/agent/whistle.py`: speech (`SAMPLE_RATE = 16000`, `OUTPUT_BYTES_PER_SECOND = 4096`,
default buffer `1 << 18` bytes):

```python
lib.needle_transcribe.argtypes = [samples, ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int,
                                  ctypes.c_char_p, ctypes.c_int]
lib.needle_stream_transcribe_process.argtypes = [samples, ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
                                                 ctypes.c_int]
lib.needle_stream_transcribe_stop.argtypes = [ctypes.c_char_p, ctypes.c_int]

def _options(language, keywords):
    if keywords is not None and not isinstance(keywords, str):
        keywords = "\n".join(keywords)
    return language.encode("utf-8") if language else None, keywords.encode("utf-8") if keywords else None

def _samples(audio):   # WAV path -> mono float32 in [-1, 1] (int PCM divided by 2^(bits-1))
    ...
    return (ctypes.c_float * len(data)).from_buffer(data) if len(data) else (ctypes.c_float * 1)(), len(data)

class Whistle:
    def __init__(self, weights=None, buffer_size=1 << 18):
        self._buffer = ctypes.create_string_buffer(buffer_size)
        ...  # _bind(): lib.needle_load(<bytes of whistle.cact>, len)

    def transcribe(self, audio, language=None, keywords=None, word_timestamps=False) -> dict:
        lib = self._bind()
        samples, count = _samples(audio)
        language, keywords = _options(language, keywords)
        self._reserve(count // SAMPLE_RATE * OUTPUT_BYTES_PER_SECOND)
        return self._result(lib.needle_transcribe(samples, count, language, keywords, int(bool(word_timestamps)),
                                                  self._buffer, len(self._buffer)))
```

`needle_transcribe` output for the same clip (parsed by the package and re-serialized, so the whitespace differs from the raw buffer):

```json
{"text": "Turn the kitchen lights blue.", "language": "en", "ttft_ms": 2.5, "decode_tps": 1126.6}
```
