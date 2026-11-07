# Requisiti — Funzioni avanzate (capitolato Win Live 16)

Stato reale delle funzioni del master prompt "PLAYER LIVE WINLIVE16" in FPM Studio Live.
Regola seguita: nessuna funzione fittizia; ciò che manca è dichiarato anche nell'app (Funzioni avanzate → Stato funzioni).

| ID | Area | Requisito | Stato | Note |
|---|---|---|---|---|
| REQ-A01 | Player | MIDI/KAR, MP3/WAV/M4A, MP4/MOV, MP3+G (CDG e ZIP), LRC/SRT/TXT, testi ID3 | 🟡 Limitata | Mancano AVI/FLV, WMA e link YouTube |
| REQ-A02 | Player | File picker, drag & drop, cartelle, archivio | ✅ Implementata |  |
| REQ-A03 | Player | Transport, tempo trascorso/rimanente, BPM, tonalità, pre-count, metronomo | 🟡 Limitata | Metronomo e pre-count solo sulle basi MIDI |
| REQ-A04 | Player | Tono, tempo indipendente, volumi, mute/solo, EQ, compressore | 🟡 Limitata | Compressore solo nell'export |
| REQ-A05 | Player | Prenotazione brano successivo | ✅ Implementata | Scaletta con avanti automatico |
| REQ-A06 | Player | Comportamenti fine brano (stop, auto, casuale) | 🟡 Limitata | Stop o avanti automatico; casuale non ancora |
| REQ-A07 | Player | Preferiti, cronologia, ripristino sessione, schermo palco | 🟡 Limitata | Ripristino scaletta e impostazioni; preferiti/cronologia in roadmap |
| REQ-B01 | Archivio | Database SQLite completo | 🟡 Limitata | Archivio JSON + file .fpm.json per brano |
| REQ-B02 | Archivio | 39 SongList + F10 + F11/F12 | ⬜ Non ancora disponibile | Oggi: una scaletta serata + playlist automix |
| REQ-B07 | Archivio | Backup incrementale e sync | ⬜ Non ancora disponibile |  |
| REQ-C01 | Karaoke | Karaoke a sillaba, LRC, offset | ✅ Implementata | SRT non ancora |
| REQ-C02 | Karaoke | Editor testo con sincronizzazione | 🟡 Limitata | Sincronizzazione da tastiera; senza waveform |
| REQ-C03 | Karaoke | Editor accordi, notazione latina/internazionale, riconoscimento MIDI | ✅ Implementata |  |
| REQ-C04 | Karaoke | Chord Bar + tastiera + diagrammi chitarra | ✅ Implementata |  |
| REQ-C05 | Karaoke | Struttura Intro/Verse/Chorus/Bridge/Outro, marker, loop | ✅ Implementata |  |
| REQ-C06 | Karaoke | Doppio monitor con overlay testi/accordi su video | ✅ Implementata |  |
| REQ-C07 | Karaoke | Karaoke Web Monitor con QR, font/colori per spettatore | 🟡 Limitata | Solo rete locale (LAN), non via Internet |
| REQ-C08 | Karaoke | Messaggi a schermo, leggio PDF con pedale | ✅ Implementata | Slideshow sfondi in roadmap |
| REQ-C09 | Karaoke | Songbook stampabile | ⬜ Non ancora disponibile |  |
| REQ-D01 | Multitraccia | Fino a 16 stem sincronizzate, gain/pan/mute/solo | ✅ Implementata | Senza waveform per traccia |
| REQ-D02 | Multitraccia | "Non trasporre" per stem (batteria/click esclusi di default) | ✅ Implementata |  |
| REQ-D04 | Multitraccia | 4 uscite indipendenti (FOH, click, monitor, cue) | ⬜ Non ancora disponibile | Richiede routing multicanale CoreAudio |
| REQ-D06 | Multitraccia | Progetto aperto (.stageproj.json) | ✅ Implementata | WMT/MP3+/WEVN non supportati (formati proprietari) |
| REQ-E01 | MIDI | Parser SMF/KAR, tempo map, testi | ✅ Implementata |  |
| REQ-E02 | MIDI | Synth GM con SoundFont SF2/DLS | ✅ Implementata | SFZ non supportato |
| REQ-E03 | MIDI | Mixer canali: volume, mute/solo | 🟡 Limitata | Pan/effetti per canale in roadmap |
| REQ-E04 | MIDI | Device manager MIDI, MIDI learn, clock | ⬜ Non ancora disponibile |  |
| REQ-E05 | MIDI | Piano roll / drum editor | ⬜ Non ancora disponibile |  |
| REQ-E08 | MIDI | Melodia on/off, solo melodia, basso+batteria, solo batteria, reset | ✅ Implementata | Tasti M U B D A N |
| REQ-E09 | MIDI | MIDI → WAV/MP3 offline | ✅ Implementata | Piano Studio e AI Studio |
| REQ-F01 | Eventi | Timeline eventi (KEY, TEMPO, VOLUME, FADE, MSG, PDF PAGNUM, SAMPLE, START MIX, metronomo) | ✅ Implementata | Tempo in secondi; SysEx non inviato |
| REQ-F02 | Eventi | Replay deterministico dopo seek/loop | ✅ Implementata | Verificato nei test |
| REQ-F03 | Eventi | 10 marker, loop con ripetizioni, quick save | ✅ Implementata |  |
| REQ-F04 | Eventi | Pedale/tastiera mappabili | 🟡 Limitata | Pedali Bluetooth "tastiera" sì; pedali MIDI no |
| REQ-G01 | Mix | Crossfade automatico/manuale, curve | ✅ Implementata | Nella sezione DJ |
| REQ-G03 | Mix | Medley Creator fino a 6 brani con export | ✅ Implementata |  |
| REQ-G04 | Mix | Musica di sottofondo automatica | ✅ Implementata |  |
| REQ-G05 | Mix | Sample player 100 slot | ✅ Implementata | Hotkey per slot in roadmap |
| REQ-H01 | AI | Separazione stem con AI | ⬜ Non ancora disponibile | Serve un modello (es. Demucs) o un servizio a pagamento |
| REQ-H02 | AI | Stima tonalità, BPM, accordi | ✅ Implementata | Algoritmi locali, risultati modificabili |
| REQ-I03 | Registrazione | Registrazione voce sulla base | 🟡 Limitata | Voce in WAV separato; mixdown con la base in roadmap |
| REQ-I04 | Registrazione | Screen/video capture | ⬜ Non ancora disponibile |  |
| REQ-L01 | Rete | Telecomando LAN con PIN | 🟡 Limitata | HTTP su rete locale, senza TLS |
| REQ-L03 | Rete | Cloud backup | ⬜ Non ancora disponibile |  |
| REQ-N01 | Scorciatoie | Profilo rimappabile con conflitti evidenziati | ✅ Implementata |  |
| REQ-O05 | Live | Show lock | ✅ Implementata |  |

**Totale:** 46 requisiti principali · 25 implementati · 12 limitati · 9 non ancora disponibili.

## Test eseguiti (riproducibili con `Tests/CoreSelfTest.swift`)

| Test | Esito |
|---|---|
| Parser MIDI/KAR con testo, tempo map, metrica | ✅ superato |
| Accordi dal MIDI (Do Sol Lam Fa…) senza falsi rivolti | ✅ superato |
| Struttura INTRO/VERSE/CHORUS/BRIDGE/OUTRO su brano di prova | ✅ superato (confini esatti) |
| Accompagnamento piano: estensione Fa1–Do5, basso originale | ✅ superato |
| Editor testo/accordi: andata e ritorno con tempi conservati | ✅ superato |
| Timeline eventi: stato dopo salto, nessun evento doppio dopo loop | ✅ superato |
| File .fpm.json vecchi letti senza i campi nuovi | ✅ superato |
| Diteggiature chitarra (Fa 133211, Sib x13331, Do#m7 x46454) | ✅ superato |
| AI Studio: 5 stili, durata, tag negativi, testo sincronizzato | ✅ superato |
| Encoder MP3 320 kbps (lamejs) | ✅ superato (in Node) |
| Interfaccia, audio, rete (codice macOS) | ⚠️ da verificare alla prima compilazione in Xcode |

## Prossime milestone proposte

1. Database SQLite, 39 SongList + F10/F11/F12, preferiti e cronologia (B01–B05, A07).
2. Uscite audio multiple (FOH/click/monitor/cue) con routing per stem (D04–D05).
3. MIDI device manager, MIDI learn e pedaliere MIDI (E04, F04).
4. Editor testo con waveform, SRT, songbook PDF (C02, C09).
5. Piano roll e drum editor (E05); mix voce registrata + base (I03).
6. Separazione stem AI con modello locale (Demucs) come modulo opzionale (H01).
