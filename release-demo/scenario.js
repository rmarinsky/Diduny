// Release "What's new" montage. Stills are captures of the Diduny TEST build with demo data only
// (copied into the untracked release-demo/frames/) + camera moves, screen transitions and big UA/EN subtitles.
// Preview: open release-demo/player.html. Render: python3 scripts/render_release_gif.py
//
// Rects are [x, y, w, h] in the 1000×712 window space of the frames. "full" = whole window.
window.SCENARIO = {
  title: "Diduny",
  scenes: [
    {
      frame: "hint-oops", duration: 3600,
      camera: [[0, "full"], [400, [60, 60, 560, 120]]],
      highlight: { rect: [452, 92, 164, 54], at: 900 },
      uk: "Папуга тепер у Diduny", en: "Papuga is now part of Diduny",
      uk2: "не та розкладка? Виправляє саме: «Ой, виправив»", en2: "wrong layout? It fixes itself: \"Oops, fixed\"",
    },
    {
      frame: "hint-undo", duration: 3000, enter: "fade",
      camera: [[0, [60, 60, 560, 120]]],
      highlight: { rect: [452, 92, 164, 54], at: 300 },
      uk: "Не треба? Один клік: «Скасувати заміну»", en: "Didn't want it? One click: \"Undo fix\"",
    },
    {
      frame: "hint-undo", duration: 3200, enter: "fade",
      camera: [[0, [60, 60, 560, 120]]],
      keys: { keys: ["⌥", "⇧"], at: 300 },
      uk: "Виділіть текст і двічі ⌥⇧", en: "Select text, press ⌥⇧ twice",
      uk2: "і він переходить в іншу розкладку", en2: "and it switches to the other layout",
    },
    {
      frame: "copynew", duration: 4400, enter: "slide",
      camera: [[0, "full"], [1700, [500, 300, 500, 330]]],
      highlight: { rect: [536, 556, 206, 50], at: 2200 },
      uk: "На зустрічі: «Копіювати»…", en: "In a meeting: Copy…",
      uk2: "а далі «Копіювати нове»: лише сказане після", en2: "then Copy new: only what was said since",
    },
    {
      frame: "translate", duration: 4000, enter: "slide",
      camera: [[0, "full"], [500, [330, 190, 450, 250]]],
      highlight: { rect: [352, 205, 402, 215], at: 1100 },
      uk: "Переклад посеред зустрічі", en: "Translation mid-meeting",
      uk2: "Translate → пара мов, запис той самий", en2: "Translate → a language pair, same recording",
    },
    {
      frame: "models", duration: 3800, enter: "slide",
      camera: [[0, "full"], [500, [250, 140, 420, 320]]],
      highlight: { rect: [562, 156, 70, 300], at: 1100 },
      uk: "Видно, які моделі підписують спікерів", en: "See which models label speakers",
    },
    { end: true, duration: 2400, uk: "Оновіться і пробуйте", en: "Update and try it" },
  ],
};
