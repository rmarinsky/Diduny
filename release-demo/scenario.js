// Release "What's new" montage. Stills rendered from Diduny's own SwiftUI views with demo data only
// (DidunyTests/ReleaseFramesRender, DIDUNY_RENDER_FRAMES=release-demo/frames) + camera moves,
// screen transitions and big UA/EN subtitles.
// Preview: open release-demo/player.html. Render: python3 scripts/render_release_gif.py
//
// Rects are [x, y, w, h] in the 1000×712 window space of the frames. "full" = whole window.
window.SCENARIO = {
  title: "Diduny",
  scenes: [
    {
      frame: "working_recordings", duration: 4000,
      camera: [[0, "full"], [500, [0, 60, 900, 320]]],
      highlight: { rect: [24, 90, 300, 140], at: 1300 },
      uk: "Хмара не чекає на Whisper", en: "Cloud no longer waits for Whisper",
      uk2: "кожен запис показує, що з ним зараз", en2: "each recording shows what is happening to it",
    },
    {
      frame: "working_notes", duration: 4000, enter: "slide",
      camera: [[0, "full"], [400, [0, 60, 900, 360]]],
      highlight: { rect: [24, 85, 475, 60], at: 1000 },
      uk: "Видно, яку зустріч транскрибують і для якої пишуть нотатки", en: "See which meeting is transcribed and which gets notes",
      uk2: "нотатки починаються одразу після транскрипції", en2: "notes start right after transcription",
    },
    {
      frame: "working_notes", duration: 3400, enter: "fade",
      camera: [[0, [0, 280, 900, 260]]],
      highlight: { rect: [24, 345, 400, 45], at: 800 },
      uk: "Агент доповнює нотатки на ваше прохання", en: "An agent adds to notes when you ask",
      uk2: "окремим блоком «Додав Claude»", en2: "as a separate \"Added by Claude\" block",
    },
    {
      frame: "organize", duration: 3600, enter: "slide",
      camera: [[0, "full"], [400, [0, 60, 600, 300]]],
      highlight: { rect: [24, 106, 380, 146], at: 900 },
      uk: "Проєкт, теги й люди", en: "Project, tags and people",
      uk2: "і ваші імена для спікерів", en2: "and your names for speakers",
    },
    {
      frame: "diagnostics", duration: 3800, enter: "slide",
      camera: [[0, "full"], [500, [20, 400, 860, 240]]],
      highlight: { rect: [24, 488, 840, 82], at: 1200 },
      uk: "Щось пішло не так? Експортуйте діагностику", en: "Something went wrong? Export diagnostics",
      uk2: "файл для підтримки, без аудіо й тексту", en2: "a file for support, no audio or text",
    },
    { end: true, duration: 2600, uk: "Онови Diduny → Check for Updates…", en: "Update: Diduny → Check for Updates…" },
  ],
};
