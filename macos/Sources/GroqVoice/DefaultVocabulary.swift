import Foundation

/// Starter vocabulary.txt. Left side: how the word must be written. Right side:
/// what the recognizer tends to produce for it in Russian speech — whole-word,
/// case-insensitive matches are replaced by the left side.
enum DefaultVocabulary {
    static let text = """
    # GroqVoice vocabulary — one entry per line, case matters on the left side.
    #
    #   Term: alias, alias, …
    #
    # Left of the colon: the exact spelling you want pasted.
    # Right of the colon: what the recognizer actually writes for it (see "STT result" in the log),
    # separated by commas. Whole words only, case-insensitive. Lines starting with # are ignored.
    # A term without aliases just fixes its own casing ("github" → "GitHub") and, on the
    # on-device engine, is spotted acoustically.
    #
    # On-device (Parakeet): terms are Latin-script; Cyrillic misspellings go on the right as aliases.
    # Groq Whisper: the terms are also sent as the recognition prompt.

    # Own projects and company
    SitesPro: сайтспро, сайтс про, сайт спро
    Vadi: вади
    Keyo: кейо
    Emre: эмре

    # Hosting, deploy, infrastructure
    Coolify: кулифай, кулифи, кули фай, coolfi
    Vercel: версель, версел, верcель
    Supabase: супабейс, супабейз, супа бейс
    Hetzner: хетцнер, хецнер, хетзнер
    Cloudflare: клаудфлер, клауд флер, клаудфлэр
    Docker: докер, декер
    nginx: энджинкс, энжинкс, нгинкс
    Tailscale: тейлскейл, тэйлскейл
    SSH: эсэсэйч, ссш
    DNS: днс
    URL: урл
    API: апи
    JSON: джейсон
    README: ридми

    # Git and builds
    GitHub: гитхаб, гит хаб, гитхап
    GitLab: гитлаб, гит лаб
    git: гит
    push: пуш
    pull request: пул реквест, пулреквест, пул-реквест
    APK: апк, апэка
    npm: энпиэм, нпм
    Xcode: иксод, экскод, икс код
    Node.js: нод джиэс, node js, nodejs

    # Stack
    WordPress: вордпресс, ворд пресс, вордпрес
    WooCommerce: вукоммерс, ву коммерс, вукомерс
    Next.js: некст джиэс, некст джей эс, next js, nextjs
    React: реакт
    Tailwind: тейлвинд, тэйлвинд, тейл винд
    TypeScript: тайпскрипт, тайп скрипт
    JavaScript: джаваскрипт, джава скрипт
    PHP: пхп, пиэйчпи
    Kotlin: котлин
    Swift: свифт
    Postgres: постгрес, постгре
    Redis: редис

    # Platforms and services
    Telegram: телеграм, телеграмм
    WhatsApp: вотсап, воцап, ватсап
    Figma: фигма
    Slack: слак
    Notion: ноушен, ноушн
    Google: гугл
    Gmail: гмейл, джимейл
    YouTube: ютуб, ютьюб
    Instagram: инстаграм, инста
    Facebook: фейсбук, фэйсбук
    LinkedIn: линкедин, линкдин
    Stripe: страйп
    PayPal: пейпал, пэйпал
    Claude: клод
    ChatGPT: чат джипити, чатгпт, чат гпт
    OpenAI: опенэйай, опен эйай

    # Devices and OS
    iPhone: айфон
    iOS: айос, иос
    macOS: макос, мак ос
    Android: андроид
    Home Assistant: хоум ассистент, хом ассистент, хоум асистент
    Xiaomi: сяоми, ксиаоми, шаоми
    Wi-Fi: вайфай, вай фай
    Bluetooth: блютус, блютуз
    """
}
