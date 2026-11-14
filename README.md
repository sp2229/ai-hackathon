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

## Note templates (25, based on published note-taking methods)
Pick a template before recording, or switch afterwards. Switching only regenerates the notes and reuses the existing transcript.

| Category | Templates | Layout |
|---|---|---|
| **Study Methods** | Cornell Notes (Pauk, 1962) · Outline · Flashcards (testing effect, Roediger & Karpicke 2006) · Feynman Explainer · SQ3R (Robinson, 1946) · Comparison Chart | Cornell = two-column cue/notes + summary; Flashcards = click-to-flip cards; Chart = table |
| **Visual** | Mind Map (Buzan, 1974) · Sketchnote (Rohde 2012; dual coding, Paivio 1971) · Timeline | Branching map, icon cards + connections + sticky notes, vertical timeline |
| **Class Types** | Lecture · STEM Notebook (worked-example effect, Sweller & Cooper 1985) · Engineering Problem (Given/Find/Solution) · Case Brief (IRAC) · Research Talk · Language Class · Lab Session | STEM templates render **handwritten-style notes on lined paper**, with equations typeset in Zapf's *Euler* math font |
| **Work** | Meeting · Standup · Retrospective · Client Call · Site Visit · Interview · Brainstorm (KJ method) | Speaker labels via Argmax SpeakerKit |
| **Accessible** | Plain Language · TL;DR Focus (ADHD-friendly, chunking) · Quick Note | Short sentences, bold keywords, one next step |

Equations are written by Bonsai in LaTeX and drawn natively with [SwiftMath](https://github.com/mgriebling/SwiftMath). There's no web view and no network.

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
