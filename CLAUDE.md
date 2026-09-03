# GroqVoice — наговаривалка для Mac

Форк [abirzgals/GroqVoice](https://github.com/abirzgals/GroqVoice) (origin указывает туда,
своего remote пока нет). Корень репо — оригинальное Windows-приложение на C# (не трогаем),
**вся наша работа — в `macos/`** (Swift Package, AppKit, без Xcode-проекта).

- Движок по умолчанию — Parakeet TDT v3 через FluidAudio (локально, Neural Engine).
  Groq — облачная опция/фолбэк и LLM для task-режима и чистки транскрипта.
- Сборка: `cd macos && ./build-app.sh` → `GroqVoice.app`; установка — `ditto` в `/Applications`.
  Только Command Line Tools, без Xcode (`xcodebuild` недоступен).
- Подпись ad-hoc, но с designated requirement `identifier "com.abirzgals.groqvoice"`
  (см. `build-app.sh`), чтобы TCC-разрешения переживали пересборки. Если Accessibility всё же
  слетело: `tccutil reset Accessibility com.abirzgals.groqvoice` и перезапуск.
- Обратная связь только иконкой в menu bar — никаких окон/оверлеев (так решил пользователь).
- Словарь: `Term: alias1, alias2` в vocabulary.txt → детерминированная замена алиасов в тексте
  (всегда). CTC-бустинг FluidAudio (helper-модель 106 МБ в
  `~/Library/Application Support/FluidAudio/Models/`) — опция `vocabularyBoosting`, по
  умолчанию off: на русской речи с большим словарём даёт ложные замены.
- Стартовый словарь — `DefaultVocabulary.swift`; у пользователя файл уже заполнен им.
- Данные приложения: `~/Library/Application Support/GroqVoice/` (config.json, history.jsonl,
  vocabulary.txt, snippets.txt, log.txt, models/).
- Headless-режимы для отладки: `--transcribe file.wav [--vocab terms.txt]`, `--download-model`.
- Подробности и меню — `macos/README.md`.
