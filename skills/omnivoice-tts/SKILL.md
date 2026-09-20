---
name: omnivoice-tts
description: How to use the local OmniVoice TTS REST API (OpenAI-compatible server installed by tasks/setup-omnivoice.sh as systemd service omnivoice). Synthesize speech to wav/pcm, register and manage cloned voices, and troubleshoot the service. Use when the user asks to generate speech or synthesize text with OmniVoice, register a voice, or where the TTS API/endpoint is.
---

# OmniVoice TTS

OmniVoice is an OpenAI-compatible, unauthenticated, plain-HTTP TTS server (single C++ binary) installed by `tasks/setup-omnivoice.sh` as the systemd service `omnivoice` (models in `/srv/omnivoice/models`). If the service is not installed yet, stop and recommend running `tasks/setup-omnivoice.sh` (see `AUTOMATIONS.md`) — this skill is for *using* an existing install, not installing one.

On activation, orient yourself immediately:

```bash
systemctl is-active omnivoice            # is the service running?
curl -s http://127.0.0.1:8977/health     # {"status":"ok"} => API is up
systemctl cat omnivoice                  # real --host/--port (verify, don't assume)
```

## Core facts

- Base URL defaults to `http://127.0.0.1:8977`. **The port is 8977, not the upstream default 8080** — always confirm the real host/port with `systemctl cat omnivoice`.
- **No auth, no TLS.** Loopback bind by default; remote agents must SSH-tunnel (`utilities/ssh-port-forward.sh`).
- Output formats: `wav` (one-shot file) or `pcm` (streamed, 16-bit signed LE, 24 kHz, mono). There is **no mp3** or any other format.
- **`response_format` defaults to `pcm`** — an agent that omits it gets a raw PCM byte stream, not a file. Always set `"response_format": "wav"` when saving to disk.
- **`instructions` is a strict closed vocabulary, not free text.** Every comma-separated item must be an exact English (or exact Chinese) term from the *Voice design vocabulary* below. Any free-form word (e.g. `cheerful`, `fast pace`, `young female`, `playful`) is rejected with a `server_error` (`...could not be resolved against the voice-design vocabulary`) and **nothing is generated**. If you have no specific style in mind, omit **both** `voice` and `instructions` to get the default voice — do not invent `instructions`.
- **Synthesis is serialized FIFO** (single GPU context) — one in-flight request at a time; do not parallelize or retry-storm.
- **Registered voices are in-memory only — wiped on every service restart.** Re-register after each (re)start (workflow in *Voice management*).
- Errors use the OpenAI envelope: `{"error": {"message": "...", "type": "invalid_request_error"}}`.

## Quick start

### 1. Synthesize to a WAV file

```bash
curl -s -X POST http://127.0.0.1:8977/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"input": "Hello world", "voice": "julian", "language": "English", "response_format": "wav"}' \
  -o output.wav
```

Without `"response_format": "wav"` you would get streamed PCM instead (see *Core facts*).

### 2. Stream PCM straight to speakers

```bash
curl -s -X POST http://127.0.0.1:8977/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"input": "Hello world", "voice": "julian", "response_format": "pcm"}' \
  | aplay -r 24000 -f S16_LE -t raw -c 1
```

### 3. Voice design (no reference voice)

Style via `instructions`, omit `voice`. **Every item must come from the [Voice design vocabulary](#voice-design-vocabulary)** — free text is rejected:

```bash
# One item per category: gender, age, pitch, style, accent.
curl -s -X POST http://127.0.0.1:8977/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{
    "input": "Hello world",
    "instructions": "male, young adult, moderate pitch, british accent",
    "language": "English",
    "response_format": "wav"
  }' \
  -o output.wav
```

No particular style? Omit **both** `voice` and `instructions` for the default voice:

```bash
curl -s -X POST http://127.0.0.1:8977/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"input": "Hello world", "language": "English", "response_format": "wav"}' \
  -o output.wav
```

## API reference

| Endpoint | Method | Purpose |
|---|---|---|
| `/health` | GET | liveness → `{"status":"ok"}` (always the first call) |
| `/v1/models` | GET | list the loaded model (sanity/inspection) |
| `/v1/audio/speech` | POST | synthesize text → `wav` or `pcm` |
| `/v1/audio/voices` | POST | register a cloned voice (`name`, `ref_text`, and exactly one of `wav_b64` / `rvq_b64`) |
| `/v1/audio/voices` | GET | list registered voices → `{"voices":[{"name":...}]}` |
| `/v1/audio/voices/{name}` | DELETE | remove a voice |

Speech request fields:

| Field | Type | Required | Description |
|---|---|---|---|
| `input` | string | yes | text to synthesize (UTF-8; pass raw text, no escaping) |
| `voice` | string | no | registered voice name (omit for voice design) |
| `language` | string | no | language label, e.g. `"English"`/`"German"` — one language per call |
| `instructions` | string | no | voice-design style, comma-separated items **from the fixed [Voice design vocabulary](#voice-design-vocabulary)** only (used when `voice` is omitted; free text is a `server_error`). Omit for the default voice |
| `response_format` | string | no | `wav` (one-shot) or `pcm` (streamed) — **default `pcm`** |
| `seed` | integer | no | positive = reproducible; absent/negative = random |

## Voice design vocabulary

`instructions` is **not** free text. It is a comma-separated list where each item must exactly match one term below. The server resolves each item case-insensitively against this fixed set; anything else is rejected (it even shows a `did you mean ...?` hint for near misses, but does **not** guess).

**English items** (use ASCII comma + space between items, e.g. `"male, indian accent"`):

| Category | Allowed values |
|---|---|
| gender | `male`, `female` |
| age | `child`, `teenager`, `young adult`, `middle-aged`, `elderly` |
| pitch | `very low pitch`, `low pitch`, `moderate pitch`, `high pitch`, `very high pitch` |
| style | `whisper` |
| accent | `american accent`, `british accent`, `australian accent`, `chinese accent`, `canadian accent`, `indian accent`, `korean accent`, `portuguese accent`, `russian accent`, `japanese accent` |

**Chinese dialect items** (Chinese speech only; use the full-width comma `，`, e.g. `"男，四川话"`): `河南话`, `陕西话`, `四川话`, `贵州话`, `云南话`, `桂林话`, `济南话`, `石家庄话`, `甘肃话`, `宁夏话`, `青岛话`, `东北话`

**Rules (violating any → `server_error`, no audio):**

- **Only English OR only Chinese** items in a single `instructions` — never mix. Dialects force Chinese, accents force English; a dialect + accent together is rejected.
- **At most one item per category** (gender, age, pitch, style, accent, dialect). `"male, female"` or `"high pitch, low pitch"` conflict.
- Common mistakes: `cheerful`, `fast pace`, `young female`, `playful`, `calm` are **not** valid — the only style is `whisper`, and age/gender/pitch must use the exact table strings. `young female` is invalid (use `female` + `young adult` separately).

## Voice management

### Register a voice (WAV)

```bash
WAV_B64=$(base64 -w0 /path/to/reference.wav)
curl -s -X POST http://127.0.0.1:8977/v1/audio/voices \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"julian\", \"ref_text\": \"Hi, my name is Julian\", \"wav_b64\": \"$WAV_B64\"}"
```

`ref_text` is the **transcript of the reference audio** and is required — clone quality depends on it. `wav_b64` and `rvq_b64` are mutually exclusive (exactly one).

### Register a voice (pre-encoded RVQ)

```bash
RVQ_B64=$(base64 -w0 /path/to/reference.rvq)
curl -s -X POST http://127.0.0.1:8977/v1/audio/voices \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"julian\", \"ref_text\": \"Hi, my name is Julian\", \"rvq_b64\": \"$RVQ_B64\"}"
```

Caveats: the setup script installs only `tts-server`, **not** the `omnivoice-codec` encoder — use the RVQ path only if a `.rvq` already exists (it must have been encoded once with the same tokenizer model the server runs). RVQ registration does not carry the reference loudness the WAV path does.

### List / delete

```bash
curl -s http://127.0.0.1:8977/v1/audio/voices
curl -s -X DELETE http://127.0.0.1:8977/v1/audio/voices/julian
```

### Re-register after restart (REQUIRED)

Voices live in server memory only. Persist the voice files in one dir (convention: `$HOME/omnivoice-voices/` with `<name>.rvq` or `<name>.wav` + `<name>.txt` transcript); after every service (re)start, once `/health` is ok, loop and re-register:

```bash
BASE=http://127.0.0.1:8977
for f in "$HOME/omnivoice-voices"/*.rvq; do
  name=$(basename "$f" .rvq)
  curl -s -X POST "$BASE/v1/audio/voices" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"$name\", \"ref_text\": \"$(cat "$HOME/omnivoice-voices/$name.txt")\", \"rvq_b64\": \"$(base64 -w0 "$f")\"}"
done
curl -s "$BASE/v1/audio/voices"   # verify all voices are back
```

(As written the loop covers `.rvq` voices; for `.wav` voices use the same pattern with the `.wav` glob and `wav_b64`. Assumes transcripts without double quotes; otherwise build the JSON with `jq`.)

## Access modes

- **Loopback (default):** `http://127.0.0.1:8977` — reachable only on the host itself. Remote agents: SSH-tunnel with `utilities/ssh-port-forward.sh`.
- **LAN direct:** set `OMNIVOICE_HOST=0.0.0.0` at setup time → `http://<server-ip>:8977`, gated only by the UFW rule the setup script adds. Still no TLS, no auth.
- **Traefik + TLS:** operator-managed, not automated by this repo. If Traefik is installed, `tasks/setup-traefik.sh` leaves a reference file at `/opt/traefik/dynamic/host-services.yml.example` — copy it, point a domain at `127.0.0.1:8977`, reload Traefik.

## Troubleshooting

- **`/health` connection refused / `000`:** `sudo systemctl status omnivoice` + `sudo journalctl -u omnivoice -n 50 --no-pager`. After a (re)start, model load can take up to ~10 min before `/health` answers.
- **`Unknown voice` right after a restart:** voices were wiped — run the re-registration loop (*Voice management*).
- **Requests appear stuck:** synthesis is serialized FIFO — wait for the in-flight request; don't fire parallel requests.
- **Garbled / wrong-accent output:** one language per call; set `language` explicitly and split mixed-language text.
- **`instructions ... could not be resolved against the voice-design vocabulary` (`server_error`):** an `instructions` item is not in the *Voice design vocabulary*. Free-form style words are rejected — use only the exact English/Chinese terms (or drop `instructions` for the default voice). Also check you didn't mix categories (e.g. two genders) or mix Chinese dialects with English accents.
- **Examples found online use port 8080:** that is the upstream default; the installed service uses 8977 — verify the unit with `systemctl cat omnivoice`.
- **Non-ASCII text:** pass raw UTF-8 in the JSON `input` — no escaping tricks needed (the upstream CJK bug was Windows/stdin-only; re-test CJK output if it sounds off).

## Links

- `tasks/setup-omnivoice.sh` — install/upgrade the service (env vars `OMNIVOICE_*`, health gate, `--check`)
- `AUTOMATIONS.md` → `setup-omnivoice.sh` — public setup summary
