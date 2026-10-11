# Deepler

Flutter-Desktop-App zum Übersetzen mit DeepL und zur lokalen Textextraktion aus
Video- und Audiodateien.

Unter **Zielsprache** stehen **Deutsch**, **Englisch** (britisch),
**Italienisch** und **Spanisch** zur Auswahl. Die Auswahl gilt für Text und
Medienabschnitte und wird für den nächsten Start gespeichert. MP3- und
Videoexport bieten passende Stimmen zur Sprache der fertigen Übersetzung;
die neue Videotonspur trägt die entsprechende Sprachkennzeichnung.
Eine geänderte Zielsprache wird erst bei der nächsten Übersetzung angewendet.
Gespeicherte Übersetzungen behalten ihre Sprache; ältere Speicherstände
werden weiterhin als Deutsch geladen.

## Video / MP3 → Text

Die Extraktion übernimmt `transcribe.py` aus dem Nachbarprojekt `DmitrysVideo`:
`faster-whisper`, CPU/int8, Beam Size 5 und Sprachaktivitätserkennung. Videos
werden direkt mit PyAV gelesen; separates FFmpeg ist nicht erforderlich.
Das Python-Skript wird als Flutter-Asset auch in Desktop-Builds mitgeliefert.

Deepler sucht in den übergeordneten Ordnern des Arbeitsverzeichnisses und der
ausführbaren Datei nach `DmitrysVideo/.venv` und verwendet dessen Python und
Modellcache (`models`). Ein gespeicherter Python-Pfad hat Vorrang. Das Feld
kann geleert werden, um automatisch suchen zu lassen.

Ohne Nachbarprojekt eine eigene Umgebung einrichten:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r python/requirements.txt
```

Den vollständigen Pfad zu `.venv\Scripts\python.exe` unter **Python executable**
eintragen und speichern. Ohne Nachbarprojekt liegen Modelle im
Anwendungsdatenverzeichnis von Deepler. Neue Modelle benötigen beim ersten
Einsatz einen Download.

1. **Select media**: Video oder Audio auswählen.
2. **Language: Russian** für Russisch oder **auto** zur Spracherkennung wählen.
3. Modell wählen; neue Einstellungen verwenden wie DmitrysVideo **small**.
   Bereits gespeicherte Einstellungen bleiben erhalten.
4. **Extract text** starten. Der Fortschritt erscheint im Protokoll.
5. **Zielsprache** wählen und den übernommenen Originaltext mit **Translate** übersetzen.

Die Extraktion läuft lokal. Erst die separate DeepL-Übersetzung sendet den Text
an DeepL und benötigt einen API-Schlüssel. Zeitstempel und Statusmeldungen
werden nicht in den Übersetzungstext übernommen. Temporäre Transkriptdateien
werden nach der Übernahme entfernt; der Modellcache bleibt erhalten.

## Übersetzung als MP3

Unter der Übersetzung **Als MP3 speichern** auswählen. Im Dialog stehen
passende Stimmen für die Übersetzungssprache sowie ein Sprechtempo von −30 %
bis +30 % zur Verfügung. Für Deutsch sind Katja, Conrad, Seraphina und Florian
verfügbar, für Englisch Sonia und Ryan, für Italienisch Elsa und Diego sowie
für Spanisch Elvira und Alvaro. Anschließend den Speicherort wählen. Erst wenn die
Sprachausgabe vollständig erzeugt wurde, wird die Zieldatei geschrieben.

Bei einer abschnittsweise übersetzten Mediendatei ist im MP3-Dialog
**Ursprüngliche Startzeiten berücksichtigen** vorausgewählt. Die MP3 beginnt
mit den ursprünglichen Pausen und setzt jeden Abschnitt bei
`max(ursprünglicher Start, Ende des vorherigen gesprochenen Abschnitts)` ein.
Das gewählte Sprechtempo bleibt unverändert, es entstehen keine Überschneidungen.
Die MP3 dauert mindestens so lange wie die Originaldatei; Sprache über deren Ende
hinaus wird vollständig angehängt. Dafür muss die Originaldatei noch verfügbar sein.
Diese Ausgabe benötigt FFmpeg/FFprobe und verwendet denselben Sprachcache sowie
dieselben Wiederholungsversuche wie der Videoexport. Wird die Option abgewählt
oder fehlen Zeitstempel, wird der Text wie bisher fortlaufend vorgelesen.

Die Ausgabe verwendet das kostenlose Community-Paket `edge-tts` mit Microsofts
Online-Sprachdienst. Dafür wird der Übersetzungstext an Microsoft übermittelt;
Internet ist erforderlich, ein API-Schlüssel nicht. Die Anbindung ist keine
offizielle Microsoft-API und kann sich durch Änderungen am Dienst ändern.

`edge-tts` ist in `python/requirements.txt` enthalten und muss in der unter
**Python executable** gewählten Umgebung installiert sein. Auf diesem Rechner
ist es bereits in der vorhandenen DmitrysVideo-Umgebung eingerichtet.

## Video mit übersetzter Tonspur

Das Video mit **Select media** auswählen, **Extract text** ausführen und danach
die **Zielsprache** und **Translate** wählen. Die Übersetzung verarbeitet jeden erkannten Abschnitt
einzeln und behält dessen Zeitstempel. Unter der Übersetzung erscheint
**Video mit deutscher/englischer/italienischer/spanischer Tonspur**, je nach
Übersetzungssprache. Stimme, Tempo und den Namen der neuen MP4 wählen.

Jeder Abschnitt wird mit dem eingestellten Tempo gesprochen. Sein tatsächlicher
Start ist `max(ursprünglicher Start, Ende des vorherigen gesprochenen Abschnitts)`.
Die Stimme wird weder gedehnt noch zusätzlich beschleunigt. Pausen werden mit
Stille gefüllt. Es entstehen keine Überschneidungen, und nach einer ausreichenden
Pause kann die Sprache wieder zum ursprünglichen Zeitplan aufschließen.
Läuft die Sprache über das Videoende hinaus, bleibt das letzte Bild stehen,
bis alles gesprochen ist. Das Originalvideo wird nicht überschrieben.

Im Videoexport ist **Originalton leise im Hintergrund (25 %)** vorausgewählt.
Damit enthält die Standardtonspur die Übersetzung in normaler Lautstärke und
gleichzeitig den auf 25 % gedämpften Originalton. Die Übersetzung bleibt auch
bei einer Verlängerung des Videos vollständig hörbar. Ein Spitzenbegrenzer
verhindert Übersteuerung durch die Mischung.
Ohne Häkchen enthält die Standardtonspur ausschließlich die Übersetzung.
In beiden Fällen steht der gedämpfte Originalton zusätzlich als getrennt
auswählbare Spur **Original (25 %)** zur Verfügung. Hat das Ausgangsvideo
keinen Ton, wird nur die Übersetzung ausgegeben. Die ursprüngliche Videodatei
bleibt unverändert.
Die zeitliche Ausrichtung gilt für erkannte Sprachabschnitte und ist keine
Lippensynchronisation. Die Erkennung liefert nicht immer exakt einen Satz je Abschnitt.

FFmpeg und FFprobe müssen im PATH verfügbar sein; auf diesem Rechner sind sie
bereits installiert. Bei einer Verlängerung wird das Bild für die neue MP4
neu kodiert. Ohne Verlängerung wird die Videospur nach Möglichkeit kopiert.
Der Fortschritt zeigt die vertonten Abschnitte und den abschließenden Videoexport.

Bei HTTP 403 versuchen MP3- und Videoexport die Spracherzeugung ohne feste
Versuchsgrenze weiter. Die Wartezeiten steigen von 2 über 5 auf maximal
10 Sekunden zwischen den Versuchen. Das Protokoll zeigt den nächsten
Versuch. **MP3-Export abbrechen** bzw. **Videoexport abbrechen** beendet auch
eine laufende Wartepause. Andere vorübergehende Fehler (Verbindung, HTTP 408,
429 oder 5xx) führen nach vier aufeinanderfolgenden Fehlschlägen zum Abbruch.
Eine dauerhafte Ablehnung durch Microsoft kann auch durch Wiederholen nicht
behoben werden. Fertige Sprachabschnitte bei Exporten mit Zeitstempeln bleiben
im Unterordner `speech_cache` des Anwendungsdatenverzeichnisses gespeichert;
ein erneuter Export verwendet sie wieder. Text, Stimme und Sprechtempo bestimmen,
welche Aufnahme passt. Der Cache enthält die gesprochenen Texte als Audiodateien
und kann bei geschlossener Anwendung gelöscht werden. Zwischen neuen Abschnitten
liegt eine kurze Pause, um den Dienst weniger schnell hintereinander anzufragen.

**Load Saved** lädt künftig auch die Zeitzuordnung. Ältere gespeicherte Texte
ohne Zeitstempel müssen einmal neu extrahiert und übersetzt werden.
Beim Bearbeiten des Textes eine Zeile pro Abschnitt beibehalten; zusätzliche,
gelöschte oder leere Zeilen heben die Zuordnung auf und erfordern eine erneute
Abschnittsübersetzung. Wurde dabei die Zeilenzahl im Originaltext geändert,
ist zuvor eine erneute Extraktion nötig. Importierter Fließtext hat keine
zuverlässige Zeitzuordnung.
