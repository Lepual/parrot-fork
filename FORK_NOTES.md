# Note su questo fork

Fork personale di [`digimata/parrot`](https://github.com/digimata/parrot), un demone di dettatura push-to-talk per macOS (WhisperKit on-device). Questo file documenta cosa è stato cambiato rispetto all'originale e com'è il flusso di build/installazione — leggilo prima di toccare qualunque cosa, risparmia di riscoprire a tentoni le stesse cose.

## Cosa è cambiato rispetto a upstream

L'upstream (v0.0.5, "M0-M5 complete") aveva `config.toml` **completamente inerte** — nessuna libreria TOML tra le dipendenze, nessun codice che lo leggesse. La doc lo descriveva (è la milestone M7, mai scritta) ma non faceva nulla. Questo fork implementa la fetta di M7 che serve, più altre feature:

- **`Config.swift`** — parser/writer minimale per `config.toml` (no dipendenza TOML, il formato è troppo semplice per giustificarla: solo `key = "value"`)
- **`Input/HotkeyMonitor.swift`** — enum `Hotkey` (`fn`, `right-shift`), con distinzione sinistra/destra via keycode fisico (CGEventFlags da solo non la fa)
- **`Input/DictationTrigger.swift`** — due modalità contemporaneamente: *hold* (tieni premuto, parla, rilascia) e *doppio-tap* (due pressioni rapide avviano la registrazione hands-free, una pressione la ferma)
- **`Transcription/WhisperKitTranscriber.swift`** — controlla se il modello è già scaricato localmente (`HubApi.localRepoLocation`) e passa `download: false` in quel caso. L'upstream telefona sempre a casa all'avvio anche col modello già sul disco, e fallisce a freddo senza rete. Qui funziona offline.
- **`LaunchAgent.swift`** — gestione programmatica di `launchctl`/plist (avvio automatico, riavvio dopo un cambio config)
- **`UI/PreferencesWindow.swift`** — pannello Preferenze (SwiftUI) dal menu bar: scelta modello con download e barra di progresso, scelta hotkey, toggle avvio automatico, diagnostica live, **trascrizione di file audio** con esportazione in TXT/PDF (riusa il modello già caricato in memoria, offline)
- **`Doctor.swift` / `Parrot.swift` / `Models/TranscriptionModel.swift` / `UI/MenuBarController.swift`** — adattati per collegare tutto quanto sopra

## Build

```bash
swift build -c release
```

Prima build: lenta (~30-40 min, scarica e compila WhisperKit e le sue dipendenze — CoreML, transformers, ecc.). Build successive: pochi secondi, tutto in cache.

## Installazione / aggiornamento

`/usr/local/bin` è di `root`, quindi ogni volta che cambia il binario serve `sudo` — **da terminale vero**, non automatizzabile da un agente:

```bash
launchctl bootout gui/$(id -u)/com.digimata.parrot    # ferma il demone, se già in esecuzione
sudo cp /usr/local/bin/parrot /usr/local/bin/parrot.bak-$(date +%Y%m%d)   # backup, se già installato
sudo cp .build/release/parrot /usr/local/bin/parrot
sudo chown root:wheel /usr/local/bin/parrot && sudo chmod 755 /usr/local/bin/parrot
```

## Primo avvio

Non serve più scrivere plist a mano: lancia `parrot` una volta a mano da terminale (anche solo `/usr/local/bin/parrot`, si ferma con Ctrl+C), poi dall'icona uccellino nella barra menu apri **Preferenze**:

1. **Modello**: scegli `whisper-large-v3-turbo` (multilingua) e scarica (barra di progresso, ~1.5GB)
2. **Hotkey**: Fn o Shift destro
3. **Avvia automaticamente al login**: attiva il toggle — scrive e carica da solo il LaunchAgent
4. **Salva e riavvia**

## ⚠️ La fregatura: Accessibilità va riconcessa a ogni sostituzione del binario

macOS lega il permesso di Accessibilità alla firma del codice. Il binario qui è firmato solo **ad-hoc** (nessun certificato Developer ID), quindi **ogni volta che ricompili e sostituisci `/usr/local/bin/parrot`, macOS considera il file "nuovo" e revoca il permesso.** Sintomo nei log (`/tmp/parrot.err.log`):

```
accessibility not granted — system prompt opened. Grant access, then quit and relaunch parrot.
failed to register hotkey tap: tapCreateFailed
```

Fix, ogni volta:
1. `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"`
2. Trova "parrot" nella lista, spegni/riaccendi il toggle (o togli con **–** e riaggiungi con **+** → Cmd+Shift+G → `/usr/local/bin/parrot`)
3. Ricarica il demone: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.digimata.parrot.plist` (o `launchctl kickstart -k gui/$(id -u)/com.digimata.parrot` se è già caricato)
4. A volte il primo riavvio fallisce comunque (propagazione TCC non istantanea) — riprova con un secondo `kickstart -k` se serve

Niente panico se succede al primo giro: è normale, capita sempre al primo avvio dopo ogni build.

## Permessi macOS necessari

- **Accessibilità** — per intercettare l'hotkey globale (vedi sopra)
- **Microfono** — richiesto automaticamente al primo utilizzo del tasto
