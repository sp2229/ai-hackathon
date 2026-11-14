# Unplugged: private, offline AI note-taker

**Unplugged records meetings, lectures, and site visits, then writes structured notes for that kind of session. Everything runs on your Mac, even with Wi-Fi off.**

Built for the Cornell Commons Local AI Hackathon (theme: *Recreate*). It recreates cloud AI note-takers such as Otter and Fireflies to run entirely on-device:

| Step | What runs | Where |
|---|---|---|
| Speech → text | **Argmax WhisperKit** (Core ML) | Apple Neural Engine |
| Who said what | **Argmax SpeakerKit** (Pyannote diarization) | Apple Neural Engine |
| Transcript → notes | **PrismML Ternary Bonsai 2** (1.58-bit, 2B/4B/9B) via PrismML's `llama.cpp` | Apple GPU (Metal), `127.0.0.1` only |

## Hackathon requirements
| Requirement | How Unplugged meets it |
|---|---|
| Use **Bonsai** (2B/4B/9B) | Notes are written by **Ternary-Bonsai-2-4B** (`PQ2_0` GGUF), with 2B/9B selectable. It runs through PrismML's own `llama.cpp` fork on the Metal GPU. |
| Use **Argmax** | **WhisperKit** handles speech-to-text and **SpeakerKit** handles speaker diarization, both from Argmax's Swift SDK, built natively in **Swift/SwiftUI**. |
| Runs on a **Mac with Wi-Fi off** | Verified by running the full pipeline inside a macOS sandbox that blocks all outbound network traffic except localhost (see below). |
| Theme: **Recreate** | A fully on-device recreation of cloud AI note-takers (Otter, Fireflies, Notion AI notes, Goodnotes-style study notes). |

**Offline proof:**
```bash
P='(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip "localhost:*"))(allow network-outbound (remote unix-socket))'
sandbox-exec -p "$P" .build/arm64-apple-macosx/release/Unplugged --selftest audio.wav meeting --context slides.pptx
```

**Compatibility:** Apple Silicon M1 or newer, on macOS 14+. Bonsai 4B is a 1.15 GB file and fits on 8 GB Macs. On older or 8 GB machines, pick Bonsai 2B and Whisper Base in Settings to use less energy.

## Why local?
- **Engineering site visits:** basements, tunnels, and remote sites often have no signal.
- **Lectures and exams:** campus Wi-Fi can't be relied on, and some halls have no connection at all.
- **Confidential meetings:** client, legal, HR, and medical conversations never leave the laptop.
- **Travel:** works on planes.

## Six note templates
| Template | Best for | Looks like |
|---|---|---|
| **Meeting** | Calls, standups, project meetings | Summary, decisions, action items with owners (speaker labels via Argmax SpeakerKit) |
| **Lecture** | Classes, STEM, engineering | Handwritten-style notes on lined paper, equations in the Euler math font, **drawings**, worked example |
| **Cornell** | Studying (Pauk, 1962) | Two-column cue/notes layout with a summary strip |
| **Study Cards** | Exam prep (testing effect, Roediger & Karpicke 2006) | Click-to-flip flashcards |
| **Visual** | Visual learners (dual coding, Paivio 1971) | Big idea, a drawing, emoji concept cards, sticky notes |
| **Site Visit** | Field inspections | Dimensioned sketch, observations, hazards by severity, follow-ups |

Switch templates at any time. Switching only regenerates the notes and reuses the existing transcript.

## Drawings from speech
When the speaker describes something physical, such as *"an 18 × 18 in concrete column, 12 ft tall, on a spring with k = 500 kip/in, with a 200 kip axial load"*, Bonsai writes a tiny sketch description:
```sketch
column "18x18 in" height "12 ft"
support bottom spring "k = 500 kip/in"
load top "P = 200 kip"
```
Unplugged then lays it out and draws it natively: the member, the spring, the load arrow, a height dimension, and a cross-section inset with dimensions. Beams (pin/roller/fixed/spring supports, point and distributed loads, span) and process flows (`flow "A" -> "B" -> "C"`) work the same way. The parser tolerates the small variations a 4B model produces, and raw shapes (box, arrow, spring, dimension, and so on) are available for anything else. Drawings need no image model and no network.

## Record computer audio (Zoom, Teams, Meet, recordings)
Choose **Microphone**, **Computer audio**, or **Both** before recording:
- **Computer audio** captures anything playing on the Mac with ScreenCaptureKit, such as a Zoom recording you can't download playing in a browser. Audio is written directly at 16 kHz mono with no speaker-to-mic loss.
- **Both** records your microphone alongside the call and mixes the two tracks when you stop, so live calls include your own voice.

The first time, macOS asks for permission under *Privacy & Security › Screen & System Audio Recording*. Please only record calls when everyone on them has agreed.

## Attach slides, notes & handouts
Before or after recording, attach **PDFs, PowerPoint (.pptx), Word (.docx), text/Markdown/LaTeX, or photos** of a whiteboard or handwritten notes. You can drag and drop them too. Text is extracted on-device:
- **PDFKit** for PDFs, with Apple **Vision OCR** for scanned pages and photos.
- **XML parsing** for Office files.

Bonsai then uses the material to spell terms correctly, fill in derivation steps the lecturer referred to, and add precise definitions. The transcript stays the primary source, and attachments are capped (~6K tokens) to keep inference small.

## Sustainability: right-sized local inference
Each choice below cuts compute and energy. The **Impact** tab shows per-session numbers.

1. **Ternary 1.58-bit LLM.** Bonsai 4B is a ~1.2 GB file, and on an M-series Mac it generates about 100+ tokens/s.
2. **Reasoning off.** Summarizing doesn't need chain-of-thought, so Bonsai runs with `enable_thinking: false`, which avoids generating hidden thinking tokens.
3. **The LLM runs only on demand.** `llama-server` starts when notes are generated and shuts down after 90 s idle. No AI runs in the background.
4. **Batch, not streaming.** Audio is transcribed once after recording ends, so models aren't kept running for the whole meeting.
5. **Native-format audio.** Unplugged records 16 kHz mono PCM, Whisper's own input format, so nothing needs resampling.
6. **VAD chunking.** Silence is skipped and never sent through the model.
7. **Diarization only when useful.** It's on for meetings, site visits, and interviews, and off for single-speaker lectures.
8. **Transcribe once, summarize many times.** Changing templates never re-runs speech recognition.
9. **Right-sized model choices.** Whisper tiny/base/small/turbo and Bonsai 2B/4B/9B are selectable in Settings. Defaults are the smallest models that give good results.
10. **Small context window.** Unplugged uses a 16K window instead of the model's 262K. Long recordings are condensed chunk-by-chunk instead.

## Setup (internet needed once)
Requirements: Apple Silicon Mac, macOS 14+, Swift 5.9+ (Command Line Tools or Xcode).

```bash
./scripts/setup.sh                 # PrismML llama-server + Bonsai 4B (~1.2 GB)
BONSAI_MODEL=2B ./scripts/setup.sh # optional: smaller/greener model
./scripts/build_app.sh             # builds build/Unplugged.app
open build/Unplugged.app
```
On first launch, open **Settings (⌘,) › Download models** to fetch the Argmax Whisper and SpeakerKit models. After that you can **turn Wi-Fi off**.

Verify the whole pipeline headlessly (no UI):
```bash
.build/arm64-apple-macosx/release/Unplugged --selftest path/to/audio.wav site --context handout.docx --render notes.png
.build/arm64-apple-macosx/release/Unplugged --extract slides.pptx   # see what's extracted from an attachment
```

Using Xcode: open `Package.swift` and run the `Unplugged` scheme.

Models and recordings are stored in `~/Library/Application Support/Unplugged/`.

## Architecture
```
Sources/Unplugged/
  UnpluggedApp.swift       app entry, quits llama-server on exit
  AppModel.swift       pipeline: record → transcribe → diarize → summarize; export
  Transcriber.swift    Argmax WhisperKit + SpeakerKit (offline model loading)
  BonsaiEngine.swift   spawns PrismML llama-server on localhost, streams tokens, idle shutdown
  Models.swift         Session, compute stats, note templates (prompts)
  AudioRecorder.swift  16 kHz mono recorder + level meter
  ContentView / SessionView / MarkdownView / SettingsView   SwiftUI UI
scripts/setup.sh       one-time download of llama-server + Bonsai GGUF
scripts/build_app.sh   SwiftPM → signed .app bundle
```

## Upgrading to Argmax Pro SDK
The app currently uses Argmax's open-source SDK (`argmax-oss-swift`), which requires no key. To switch to the Pro SDK:
1. `swift package-registry login https://api.argmaxinc.com/v1/sdk/login --token <axst_… secret token>`
2. In `Package.swift`, replace the dependency with `.package(id: "argmaxinc.argmax-sdk-swift", upToNextMajor: "1.11.3")` and use the `Argmax` product.
3. Initialize the SDK with your `ax_…` API key in a git-ignored `Secrets.swift`. **Never commit keys.**

## Team
Sofia Melendrez & Angelina Vazquez
