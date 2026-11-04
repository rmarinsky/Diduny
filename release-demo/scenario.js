// Release "What's new" montage. Real app frames (release-demo/frames, cut from screen recordings of
// the app with demo notes only) + camera moves, screen transitions, an animated shortcut and big UA/EN
// subtitles. Preview: open release-demo/player.html. Render: python3 scripts/render_release_gif.py
//
// Rects are [x, y, w, h] in the 1000×712 window space of the frames. "full" = whole window.
window.SCENARIO = {
  title: "Diduny 2.18",
  scenes: [
    {
      frame: "setup", duration: 2800,
      masks: [[296, 256, 676, 190]], // older, non-demo notes
      camera: [[0, "full"], [250, [262, 20, 720, 250]]],
      tap: { x: 893, y: 47, at: 1900 },
      uk: "Бенчмарк: твої записи — через кілька рушіїв", en: "Benchmark: your recordings, several engines",
    },
    { frame: "running", duration: 1200, enter: "fade", camera: [[0, [255, 80, 730, 170]]], uk: "Бенчмарк: твої записи — через кілька рушіїв", en: "Benchmark: your recordings, several engines" },
    { frame: "partial", duration: 900, enter: "fade", camera: [[0, [255, 80, 730, 170]]] },
    {
      frame: "results", duration: 3000, enter: "fade",
      camera: [[0, [255, 80, 730, 170]]],
      highlight: { rect: [268, 160, 450, 38], at: 350 },
      uk: "Parakeet на твоєму Mac: 0,24 с від Stop до тексту", en: "Parakeet on your Mac: 0.24 s from Stop to text",
    },
    {
      frame: "shortcuts", duration: 4400, enter: "slide",
      camera: [[0, "full"], [450, [262, 420, 720, 130]]],
      highlight: { rect: [266, 489, 708, 46], at: 900 },
      keys: { keys: ["⌘", "↩"], at: 1700 },
      uk: "Force submit: тисни ⌘↩ під час запису", en: "Force submit: press ⌘↩ while recording",
      uk2: "текст вставиться і відправиться", en2: "the text is pasted and sent",
    },
    {
      frame: "elevenlabs", duration: 3600, enter: "slide",
      camera: [[0, "full"], [400, [262, 230, 714, 210]]],
      highlight: { rect: [278, 272, 684, 26], at: 900 },
      uk: "Свій ключ ElevenLabs: диктування, переклад, зустрічі", en: "Your own ElevenLabs key: dictation, translation, meetings",
      uk2: "ключ лишається в Keychain твого Mac", en2: "the key stays in your Mac's Keychain",
    },
    {
      frame: "about", duration: 3400, enter: "slide",
      masks: [[850, 140, 112, 46]], // update-check values
      camera: [[0, "full"], [400, [255, 70, 730, 340]]],
      uk: "Новий екран «Про апку»: Diduny, Papuga, AppCat", en: "New About screen: Diduny, Papuga, AppCat",
    },
    { end: true, duration: 2600, uk: "Онови Diduny → Check for Updates…", en: "Update: Diduny → Check for Updates…" },
  ],
};
