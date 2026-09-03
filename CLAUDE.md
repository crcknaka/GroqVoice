# GroqVoice — наговаривалка для Mac

Форк [abirzgals/GroqVoice](https://github.com/abirzgals/GroqVoice) (remote `upstream`); свой репо —
`origin` = github.com/crcknaka/GroqVoice (private). Корень репо — оригинальное Windows-приложение на C# (не трогаем),
**вся наша работа — в `macos/`** (Swift Package, AppKit, без Xcode-проекта).

- Движок по умолчанию — Parakeet TDT v3 через FluidAudio (локально, Neural Engine).
  Groq — облачная опция/фолбэк и LLM для task-режима и чистки транскрипта.
- Сборка: `cd macos && ./build-app.sh` → `GroqVoice.app`; установка — `ditto` в `/Applications`.
  Только Command Line Tools, без Xcode (`xcodebuild` недоступен).
- Подпись ad-hoc, но с designated requirement `identifier "com.abirzgals.groqvoice"`
  (см. `build-app.sh`), чтобы TCC-разрешения переживали пересборки. Если Accessibility всё же
  слетело: `tccutil reset Accessibility com.abirzgals.groqvoice` и перезапуск.
- Обратная связь только иконкой в menu bar — никаких оверлеев (так решил пользователь). Настройки — окно
  Settings (`SettingsWindow.swift`, AppKit программно, NSGridView), история — `HistoryWindow.swift`.
- LLM для перевода/task/чистки: любой OpenAI-совместимый endpoint (`chatBaseURL`), по умолчанию Groq.
- Свой репозиторий: origin = github.com/crcknaka/GroqVoice (private), upstream = abirzgals/GroqVoice.
  Коммиты — английские императивные, без упоминания AI.
- Словарь: `Term: alias1, alias2` в vocabulary.txt → детерминированная замена алиасов в тексте
  (всегда). CTC-бустинг FluidAudio (helper-модель 106 МБ в
  `~/Library/Application Support/FluidAudio/Models/`) — опция `vocabularyBoosting`, по
  умолчанию off: на русской речи с большим словарём даёт ложные замены.
- Стартовый словарь — `DefaultVocabulary.swift`; у пользователя файл уже заполнен им.
- Данные приложения: `~/Library/Application Support/GroqVoice/` (config.json, history.jsonl,
  vocabulary.txt, snippets.txt, log.txt, models/).
- Headless-режимы для отладки: `--transcribe file.wav [--vocab terms.txt] [--boost]`, `--download-model`,
  `--snapshot-ui dir` (PNG окон Settings/History без Screen Recording — свои окна можно снимать).
- Подробности и меню — `macos/README.md`.
