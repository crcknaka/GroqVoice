# GroqVoice for macOS

Menu-bar наговаривалка для Mac: **удерживаешь Fn (🌐), говоришь, отпускаешь** — текст
вставляется в активное окно. Распознавание идёт **на самом Маке** (NVIDIA Parakeet TDT v3
через [FluidAudio](https://github.com/FluidInference/FluidAudio), CoreML / Neural Engine):
без аккаунтов, без сети, ~0.2 с на фразу. Groq (Whisper + Llama) остаётся опцией — как
облачный движок, фолбэк и мозг для task-режима.

Swift + AppKit, macOS 14+, Apple Silicon.

## Что умеет

| Действие | Что делает |
|---|---|
| **Hold Fn**, говори, отпусти | Push-to-talk: распознать → вставить в активное окно |
| **Double-tap Fn** | Lock: запись держится, любой следующий тап останавливает |
| **Fn + другая клавиша** | OS-шорткат работает как обычно, запись отбрасывается |
| Начать с `задание: …` / `task: …` | Ответ LLM вместо транскрипта (нужен Groq-ключ или Apple Intelligence) |
| **⌃⌥⌘R** | Запись активного экрана → .mov на Рабочий стол |

Граница «тап»/«hold» — 250 мс (`pttHoldMs`), окно двойного тапа — 400 мс (`doubleTapWindowMs`).
После отпускания клавиши запись продолжается ещё 250 мс (`releaseTailMs`), чтобы не срезать
последний слог. Записи короче 0.3 с (`minRecordingSeconds`) и тишина (`silencePeakPercent`)
отбрасываются молча. Аудиодвижок для выбранного микрофона держится подготовленным, поэтому
запись стартует практически мгновенно после нажатия.

Вся индикация — иконка в menu bar: 🎙 ready → 🔴 recording → 🟠 locked → ⏳ processing;
серый перечёркнутый микрофон = нет разрешения Accessibility, жёлтый треугольник на пару секунд =
ошибка (подробности в логе). Никаких окон и оверлеев.

### Меню

Сверху вниз: что делает хоткей → **Recent** → движок и его настройки → LLM-дополнения →
общие настройки → файлы → выход. Группа неактивного движка серая: при Parakeet недоступны
настройки Groq Whisper, и наоборот.

- **Recent** — последние 10 диктовок, клик копирует в буфер.
- **Engine: …** — какой движок распознаёт речь: `Parakeet v3 — on this Mac` (по умолчанию)
  или `Whisper via Groq — cloud`.
- **Parakeet Settings** — статус модели и её загрузка, статус словаря, *Edit Vocabulary…*,
  *Acoustic Term Spotting (experimental)*, галка *Fall Back to Groq Whisper if Parakeet Fails*
  (работает только при наличии ключа).
- **Groq Whisper Settings** — ключ API, *Fall Back to Parakeet When Offline or Rate-Limited*,
  цепочка моделей.
- **Groq LLM: Task Mode & Clean-Up** — независимо от движка: ключ API, *Clean Up Transcript*
  (пунктуация, «эээ», написания из словаря; ответ подозрительной длины отбрасывается),
  подсказка про task-режим, *Edit Snippets…*, цепочка моделей. Без ключа (или Apple
  Intelligence на macOS 26) эти функции просто неактивны.
- **Hotkey: …** — `Fn`, `Right ⌘`, `Right ⌥`, `Right ⌃`, `Left ⌃`. Для Fn нужно
  System Settings → Keyboard → *Press 🌐 key to* → **Do Nothing**. Right ⌥ на латышской
  раскладке занят под ā/ē.
- **Microphone: …** — конкретное устройство или системный default (AirPods становятся
  default автоматически, но их микрофон хуже встроенного).
- **Language: …** — Auto-detect или фиксированный язык. Для Parakeet фиксация только
  фильтрует алфавит (кириллица/латиница), для смешанной RU/EN речи оставляй Auto.
- **Sound Feedback** — звуки старта/стопа записи и ошибки.
- **Type Instead of Paste** — печатать клавишами вместо ⌘V (remote desktop и приложения,
  где ⌘V не вставка).
- **Launch at Login** — по умолчанию выключено.
- **Open Config File / Open Log**, **Record Screen (⌃⌥⌘R)**.

## Сборка и установка

```bash
cd macos
./build-app.sh            # нативная сборка → GroqVoice.app (ad-hoc подпись)
./build-app.sh --universal
./build-app.sh --dist     # Developer ID + нотаризация → zip и dmg
ditto GroqVoice.app /Applications/GroqVoice.app
open /Applications/GroqVoice.app
```

Нужны только Xcode Command Line Tools. Первая сборка тянет FluidAudio (~1–2 мин).

**Первый запуск.** Разреши Microphone и Accessibility (промпты откроются сами; Accessibility
нужна для глобального хоткея и синтеза ⌘V). Приложение предложит скачать модель Parakeet
(~500 МБ, один раз). Groq-ключ не обязателен.

**Если хоткей не реагирует** — открой меню: вместо «Hold Fn to talk» там будет
«Hotkey inactive — permission missing» и пункт *Enable Accessibility for GroqVoice…*,
который открывает нужную панель System Settings. Включи GroqVoice в списке; приложение
подхватит разрешение само в течение пары секунд и покажет «Hotkey active». Если тумблер
уже включён, а статус не меняется — удали GroqVoice из списка кнопкой «−», добавь заново
и нажми *Relaunch GroqVoice*.

**Про подпись.** Без Developer ID сборка подписывается ad-hoc. По умолчанию designated
requirement у такой подписи — `cdhash` бинарника, и каждая пересборка сбрасывала бы доверие
в Accessibility (тумблер при этом выглядит включённым). `build-app.sh` поэтому подписывает с
requirement `identifier "com.abirzgals.groqvoice"`, который не зависит от содержимого
бинарника — разрешение переживает пересборки. Если доверие всё же слетело:

```bash
tccutil reset Accessibility com.abirzgals.groqvoice   # снять старую запись
open /Applications/GroqVoice.app                      # приложение запросит доступ заново
```

## Движки

**Parakeet TDT 0.6B v3** (по умолчанию). 25 европейских языков (RU, EN, LV, UK, PL, DE…),
пунктуация и регистр из коробки, числа нормализуются («в 10 утра»). Модель качается с
Hugging Face в `~/Library/Application Support/GroqVoice/models/`, компилируется CoreML при первом
запуске (десятки секунд, один раз) и дальше держится в памяти тёплой — каждая фраза
распознаётся за доли секунды. Слабое место — англицизмы внутри русской фразы: «Coolify»
становится «кулифай», «Docker» — «декер». Лечится словарём (ниже).

**Whisper via Groq.** Лучше держит смешанную RU/EN речь и биасится словарём напрямую
(параметр `prompt`), но нужен ключ, сеть и лимиты API. Списки моделей в `config.json`
(`transcriptionModels`, `chatModels`) — приоритет с автоматическим фолбэком при 429.

## Словарь

У Parakeet нет параметра `prompt`, как у Whisper, поэтому словарь работает двумя механизмами:

1. **Алиасы → замена в тексте.** Строка `Coolify: кулифай, кулифи` заменяет в транскрипте
   любое из этих слов (целиком, без учёта регистра) на `Coolify`. Детерминированно, мгновенно,
   работает для обоих движков. Просто пиши в алиасы то, что распознаватель реально выдаёт
   (смотри `STT result` в логе). Файл создаётся со стартовым набором (~60 терминов: свои
   проекты, хостинг и деплой, git, стек, сервисы, устройства) — шаблон в
   `DefaultVocabulary.swift`, дополняй по образцу.
2. **Акустический бустинг (FluidAudio CTC word spotting), опционально.** Галка *Acoustic Term
   Spotting (experimental)* в Parakeet Settings. Докачивает вспомогательную модель Parakeet CTC
   110M (~106 МБ, в `~/Library/Application Support/FluidAudio/Models/`), которая ищет термины в
   звуке и подменяет похожие слова транскрипта. Плюс ~0.1–0.2 с на фразу. По умолчанию
   **выключено**: модель английская, и на русской речи с большим словарём она даёт ложные
   замены («смету по сайту» → «SitesPro сайту»). Акустический «rescue» без текстового сходства
   отключён всегда. Включай, если словарь маленький и термины латиницей.

Проверено на синтетической фразе «Нужно задеплоить на Coolify новый билд, проверить логи в
Docker и написать клиенту в Telegram»: без словаря — «кулифай», «декер», «Телеграм»; с
алиасами — все три названия правильные, русская и английская контрольные фразы не изменились.

Для Groq-движка канонические термины дополнительно уходят в `prompt` Whisper, а
*Clean Up Transcript with LLM* получает их как предпочтительные написания.

## Файлы

`~/Library/Application Support/GroqVoice/`:

- `config.json` — все настройки (см. поля в `Config.swift`); меню пишет туда же.
- `vocabulary.txt` — термины и имена, по строке, с алиасами: `Coolify: кулифай, кулифи`.
  См. раздел «Словарь».
- `snippets.txt` — голосовые шорткаты task-режима (`команда = текст или инструкция`).
- `history.jsonl` — последние 50 диктовок (меню Recent).
- `log.txt` — лог с ротацией на 1 МБ.
- `last.wav` — последняя запись (`"saveLastWav": false` чтобы не писать).
- `models/` — модель Parakeet.

## Отладка

```bash
GroqVoice.app/Contents/MacOS/GroqVoice --download-model      # скачать/прогреть модель, распознать last.wav
GroqVoice.app/Contents/MacOS/GroqVoice --transcribe file.wav [--vocab terms.txt] [--boost]  # распознать 16 kHz mono WAV локально
```

## Архитектура

| Файл | Что делает |
|---|---|
| `AppController.swift` | стейт-машина хоткея (tap/hold/lock), пайплайн запись → STT → paste, роутинг движков |
| `AppController+Menu.swift` | меню (строится при каждом открытии) и его действия |
| `HotkeyMonitor.swift` | listen-only CGEventTap, `HotkeyKey` (Fn / Right ⌘ / …) |
| `Recorder.swift` | AVAudioEngine → 16 kHz mono Int16 в памяти, выбор устройства |
| `AudioDevices.swift` | CoreAudio: список входов, default, UID → ID |
| `LocalSTT.swift` | Parakeet v3 через FluidAudio: загрузка, прогрев, распознавание, CTC-бустинг словаря |
| `GroqClient.swift` / `ModelChain.swift` | Groq STT + chat с фолбэком по моделям и cooldown |
| `Paster.swift` | ⌘V с полным восстановлением буфера или посимвольная печать |
| `History.swift` | history.jsonl + меню Recent |
| `TaskRouter.swift` | детект task-режима, системные промпты (task, clean-up) |
| `LocalLLM.swift` | Apple Foundation Models (macOS 26) как офлайн-LLM |
| `Vocabulary.swift` | словарь: термины, алиасы → замена, prompt для Whisper, hot-reload |
| `Snippets.swift` | голосовые шорткаты task-режима, hot-reload |
| `ScreenRecorder.swift` | ⌃⌥⌘R запись экрана |

## Privacy

Аудио не покидает Мак, пока движок — Parakeet. С Groq-движком (или фолбэком, или task-режимом,
или LLM-чисткой) данные уходят только на `api.groq.com`. Ключ хранится локально. Телеметрии нет.

## License

MIT
