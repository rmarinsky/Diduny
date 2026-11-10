// Release "What's new" montage. Real app frames (release-demo/frames, captured from the Diduny TEST build
// with demo data only, through its UI-testing fixtures) + camera moves, screen transitions and big UA/EN
// subtitles. Preview: open release-demo/player.html. Render: python3 scripts/render_release_gif.py
//
// Rects are [x, y, w, h] in the 1000×712 window space of the frames. "full" = whole window.
// Panel frames show the live panel (300 pt wide, at x 640) over the dimmed Recordings window.
window.SCENARIO = {
  title: "Diduny 2.19",
  scenes: [
    {
      frame: "recordings", duration: 3600,
      camera: [[0, "full"], [500, [250, 170, 740, 420]]],
      highlight: { rect: [305, 230, 666, 50], at: 1300 },
      uk: "Записи тепер — календар твого дня", en: "Recordings is now a calendar of your day",
      uk2: "зустрічі, голосові нотатки й переклади поруч", en2: "meetings, voice notes and translations side by side",
    },
    {
      frame: "meeting_local", duration: 2800, enter: "slide",
      camera: [[0, "full"], [400, [580, 120, 400, 470]]],
      highlight: { rect: [700, 200, 172, 32], at: 1100 },
      uk: "Нова панель запису", en: "A new recording panel",
      uk2: "живий текст на цьому Mac чи в хмарі", en2: "live text on this Mac or in the cloud",
    },
    {
      frame: "meeting_cloud", duration: 3000, enter: "fade",
      camera: [[0, [580, 120, 400, 470]]],
      highlight: { rect: [652, 255, 276, 48], at: 300 },
      uk: "Зміни рушій посеред зустрічі", en: "Switch the engine mid-meeting",
      uk2: "без зупинки, сказане лишається", en2: "no stop, nothing said is lost",
    },
    {
      frame: "dictation", duration: 2600, enter: "slide",
      camera: [[0, [580, 170, 400, 380]]],
      highlight: { rect: [770, 255, 160, 42], at: 700 },
      uk: "Диктування й переклад: рушій на льоту", en: "Dictation and translation: switch engines on the fly",
    },
    {
      frame: "meeting_translate", duration: 3000, enter: "slide",
      camera: [[0, [580, 150, 400, 420]]],
      highlight: { rect: [652, 218, 276, 52], at: 600 },
      uk: "Переклад зустрічі в обидва боки", en: "Meeting translation, both directions",
      uk2: "мову й рушій змінюєш просто в панелі", en2: "change language and engine right in the panel",
    },
    {
      frame: "command", duration: 2200, enter: "slide",
      camera: [[0, [580, 190, 400, 340]]],
      uk: "Командна панель: усе одним кліком", en: "Command panel: every mode in one click",
    },
    {
      frame: "modes", duration: 2800, enter: "slide",
      camera: [[0, "full"], [500, [170, 50, 820, 300]]],
      uk: "Налаштування перероблено", en: "Settings, redesigned",
      uk2: "кожен режим, рушій і шорткат в одному місці", en2: "each mode, engine and shortcut in one place",
    },
    {
      frame: "general", duration: 3000, enter: "fade",
      camera: [[0, "full"], [400, [170, 200, 520, 240]]],
      highlight: { rect: [176, 280, 500, 32], at: 900 },
      uk: "Після «Стоп» текст вставляється, де ти друкуєш", en: "After Stop, the text lands where you type",
      uk2: "а зависла на «Finalizing» панель більше не висить", en2: "and the panel no longer hangs on Finalizing",
    },
    { end: true, duration: 2600, uk: "Онови Diduny → Check for Updates…", en: "Update: Diduny → Check for Updates…" },
  ],
};
