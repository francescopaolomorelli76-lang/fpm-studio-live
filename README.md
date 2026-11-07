# FPM Studio Live

**Karaoke · DJ Automix · Piano Studio · AI Studio** in un'unica app per Mac,
con il logo e i colori FPM (ciano → viola → magenta).

Funziona su **Mac Intel (macOS 12 Monterey o successivo)** e su **Apple Silicon (M1/M2/M3/M4)**: la build è universale.

---

## Come compilarla (una volta sola, 10 minuti)

1. Installa **Xcode** dall'App Store (gratuito).
   - Su macOS 12 Monterey l'App Store propone l'ultima versione compatibile; se non la trovi, scarica **Xcode 14.2** da <https://developer.apple.com/download/all/> (serve un Apple ID gratuito).
2. Scarica questo progetto (pulsante verde **Code → Download ZIP** su GitHub) e scompattalo.
3. Apri **`FPMStudioLive.xcodeproj`** con doppio clic.
4. In alto scegli lo schema **FPMStudioLive** e la destinazione **My Mac**.
5. Premi **⌘R** (Product → Run). L'app si avvia.
6. Per avere l'app nella cartella Applicazioni: **Product → Archive → Distribute App → Copy App**, poi trascina *FPM Studio Live.app* in Applicazioni.
   La stessa .app funziona sia sul Mac Intel sia sull'M1 dello studio.

> Al primo avvio da un Mac diverso, macOS può dire che lo sviluppatore non è verificato:
> tasto destro sull'app → **Apri** → **Apri**.

Se Xcode mostra errori di compilazione, copiali e incollali nella chat: li correggo.

---

## I suoni (SoundFont di Win Live)

L'app suona i MIDI con il sintetizzatore General MIDI di macOS, che carica i **SoundFont .sf2**.
Per usare i suoni di Win Live (hai la licenza originale):

1. Trova il file `.sf2` di Win Live (di solito nella cartella dei suoni di Win Live sul PC; copialo sul Mac con una chiavetta o il cloud).
2. In FPM Studio Live: **FPM Studio Live → Impostazioni → Suoni → Scegli .sf2…**
   (oppure **Cerca SoundFont sul Mac** per trovarlo da solo).

Il file resta sul tuo disco e non viene incluso nell'app: così la licenza è rispettata.
Senza SoundFont l'app usa i suoni Apple; in alternativa vanno bene SoundFont gratuiti come *GeneralUser GS*.

In più, sulle basi MIDI l'app applica l'EQ "professionale" della tua app (bassi pieni, alti chiari), un riverbero di sala e, nell'export, mastering a −14 LUFS con limiter.

---

## Le sezioni

### 🎤 Karaoke (come Win Live)
- Basi **MIDI / KAR**, **MP3/M4A/WAV** e **video MP4/MOV**.
- Testo colorato sillaba per sillaba, **accordi sopra il testo** (Do Re Mi o C D E, si sceglie nelle impostazioni), conto alla rovescia, sezione corrente.
- **Schermo esterno** (TV/proiettore) a tutto schermo con un clic (⌘⇧E).
- **Tono** ±12 semitoni e **tempo** 60–140% anche su MP3 e video (senza cambiare l'intonazione).
- **Mixer tracce MIDI**: volume, mute e solo per canale; **melodia guida** on/off (⌘⇧M).
- **Microfono** con riverbero, eco ed EQ voce.
- **Archivio** con ricerca, **scaletta** della serata, passaggio automatico al brano successivo con conto alla rovescia.
- **Editor testo e accordi** per MIDI, MP3 e video:
  - scrivi o incolla il testo, accordi tra parentesi: `[Lam]Nel blu di[Re]pinto di blu`, sillabe con `/`: `can/ta/re`;
  - **Sincronizza**: il brano parte e premi **SPAZIO** su ogni sillaba (← annulla, ↵ fine riga, ESC ferma);
  - importa/esporta `.lrc`; il testo si salva accanto al brano (`nome.mp3.fpm.json`).
- Sugli MP3 senza testo gli **accordi vengono riconosciuti automaticamente** (BPM, battiti e accordi, dall'algoritmo della tua app).

### 🎧 DJ Automix (come Atomix)
- Due deck con forma d'onda, BPM, CUE, SYNC, pitch ±16% con key lock, EQ a 3 bande, volume.
- **AUTOMIX con un pulsante**: alla fine di ogni brano parte il successivo con dissolvenza (2–20 s), allineando il BPM e saltando silenzi iniziali e finali.
- **Mix di basi MIDI con gli MP3**: i MIDI vengono convertiti in audio con il tuo SoundFont (una volta sola, poi restano in cache).

### 🎹 Piano Studio (la tua app integrata)
- Dal MIDI ricava **accordi** (stesso algoritmo della tua app, migliorato) e **struttura**: INTRO, VERSE, PRE-CHORUS, CHORUS, BRIDGE, SOLO, OUTRO (correggibili a mano).
- Crea un **accompagnamento pianistico a due mani, senza melodia**: condotta delle voci, pedale, dinamiche per sezione, umanizzazione, rallentando finale.
  Stili: automatico per sezione, ballata, pop ritmico, arpeggiato, accordi tenuti.
- Opzioni: basso e batteria originali, triadi semplici, suono (gran coda, brillante, Rhodes).
- **Export**: MP3 320 kbps, WAV 24 bit, M4A, MIDI — **brano intero, parti scelte unite, oppure ogni parte in un file** (per esempio solo i ritornelli).

### ✨ AI Studio (gratis, illimitato, offline)
Procedura guidata in 5 passi come quella di Win Live AI Studio, ma **senza crediti**:
1. **Sorgente e durata**: *Ho una traccia* (MIDI o MP3: tiene accordi, tempo, struttura e testo e la riarrangia) oppure *Da zero*; durata Auto / 15 s / 30 s / 1–3 minuti.
2. **Voce o strumentale**: melodia guida sincronizzata al testo, oppure solo base.
3. **Stile e musica**: stile scritto o a tag (Pop, Rock, Piano Ballad, Dance, House, Lo-fi, Jazz, Bossa Nova, Latin, Reggaeton, Soul, Country, Cinematic, Valzer, Liscio…), BPM auto o manuale, varietà, Qualità Studio; avanzate: tag negativi (strumenti da escludere), peso stile, stranezza, peso audio, tonalità.
4. **Testi**: le strofe ripetute diventano il ritornello (oppure scrivi `[Ritornello]`, `[Strofa]`, `[Bridge]`).
5. **Riepilogo → Crea il brano**: MIDI multitraccia (batteria, basso, piano/chitarra, archi, pad, fiati, melodia) + testo karaoke sincronizzato, pronto da cantare o da esportare in MP3/WAV.

> Onestamente: l'AI Studio di Win Live usa un modello che genera audio e voce cantata sui loro server (per questo costa crediti).
> FPM Studio Live compone **sul tuo Mac** con regole musicali (armonia, stili, arrangiamento): è gratuito e illimitato,
> ma non produce una voce umana cantata; il risultato suona con il SoundFont che scegli.

### 🎛️ Funzioni avanzate (dal capitolato Win Live 16)
Tutte in **Funzioni avanzate**; lo stato reale di ogni requisito è nella scheda *Stato funzioni* e in [`docs/REQUISITI.md`](docs/REQUISITI.md) (25 implementati, 12 limitati, 9 non ancora disponibili).
- **Marker** (10 per brano), **loop** con numero di ripetizioni, marker veloce durante l'esecuzione (tasto K).
- **Eventi sulla timeline**: KEY CHANGE, TEMPO CHANGE, SONG VOLUME, FADE OUT, MESSAGGIO a schermo, PDF PAGNUM, CUSTOM SAMPLE, START MIX, METRONOMO on/off, SALTA A MARKER. Dopo salti e loop lo stato si ricalcola senza eseguire due volte gli eventi.
- **Metronomo e pre-count** sincronizzati al campione (basi MIDI); modalità canali **M U B D A N** (melodia, solo melodia, basso+batteria, solo batteria, tutti, reset).
- **Chord Bar** con accordi successivi, **tastiera di pianoforte** e **diagramma per chitarra**.
- **Leggio PDF/TXT/RTF** per brano, cambio pagina da evento, tastiera o pedale Bluetooth.
- **Campionatore** da 100 slot (5 banchi), loop, gruppi di stop, volume.
- **Multitraccia** fino a 16 stem sincronizzate, gain/pan/mute/solo, **"non trasporre"** (batteria e click esclusi da soli), progetto aperto `progetto.stageproj.json`.
- **Medley Creator** fino a 6 brani: taglio, fade, incroci, gain, export WAV/MP3/M4A.
- **Musica di sottofondo** automatica a palco fermo, con dissolvenza quando parte un brano.
- **Karaoke Web Monitor** con QR: il pubblico legge il testo sul telefono (rete locale) e sceglie carattere, dimensione e colori; **telecomando** dal telefono con PIN.
- **Registrazione della voce** sulla base (WAV 24 bit).
- **Scorciatoie rimappabili** con conflitti evidenziati (Spazio, O, Fine, Invio, Q, +/−, PagSu/PagGiù, T, M, U, D, B, A, N, K, frecce, Z, C) e **Show lock**.

Non ancora disponibili (dichiarati, senza pulsanti finti): database SQLite con 39 scalette, 4 uscite audio separate, gestione dispositivi MIDI e MIDI learn, piano roll/drum editor, separazione stem con AI, songbook PDF, CDG, cloud.

---

## Scorciatoie
| Tasto | Azione |
|---|---|
| Spazio | Play/Pausa (nel karaoke) |
| ⌘↑ / ⌘↓ | Tono +1 / −1 |
| ⌘← / ⌘→ | −5 s / +5 s |
| ⌘⇧N | Brano successivo della scaletta |
| ⌘⇧E | Schermo esterno |
| ⌘⇧M | Melodia guida on/off |
| ⌘O | Apri brano |

---

## Per sviluppatori
- Swift 5.7 + SwiftUI, AVAudioEngine, DLSMusicDevice (SoundFont), Accelerate (FFT), JavaScriptCore (encoder MP3 LAME/lamejs, LGPL).
- `FPMStudioLive/Core` è Swift puro (MIDI, accordi, struttura, piano, generatore) ed è verificato da `Tests/CoreSelfTest.swift`.
- Il progetto Xcode si rigenera con `python3 tools/gen_xcodeproj.py` dopo aver aggiunto file.
