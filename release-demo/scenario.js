// Release "What's new" montage. Real app frames (release-demo/frames, captured from the Diduny TEST build
// with demo data only, through its UI-testing fixtures) + camera moves, screen transitions and big UA/EN
// subtitles. Preview: open release-demo/player.html. Render: python3 scripts/render_release_gif.py
//
// Rects are [x, y, w, h] in the 1000×712 window space of the frames. "full" = whole window.
// Panel frames show the live panel (300 pt wide, at x 640) over the dimmed Recordings window.
window.SCENARIO = {
  title: "Diduny 2.20",
  scenes: [
    {
      frame: "notes", duration: 3800,
      camera: [[0, "full"], [500, [520, 120, 480, 470]]],
      highlight: { rect: [530, 403, 465, 78], at: 1400 },
      uk: "Нотатки з кожної зустрічі", en: "Notes from every meeting",
      uk2: "підсумок, рішення, завдання й відкриті питання", en2: "summary, decisions, action items and open questions",
    },
    {
      frame: "notes_settings", duration: 3400, enter: "slide",
      camera: [[0, "full"], [400, [263, 370, 712, 330]]],
      highlight: { rect: [264, 396, 710, 90], at: 1100 },
      uk: "Пише модель, яку обираєте ви", en: "Written by the model you choose",
      uk2: "на цьому Mac або за вашою підпискою Claude, Codex чи Gemini", en2: "on this Mac, or your Claude, Codex or Gemini subscription",
    },
    {
      frame: "agents", duration: 3200, enter: "slide",
      camera: [[0, "full"], [400, [255, 292, 730, 212]]],
      highlight: { rect: [800, 331, 177, 25], at: 1000 },
      uk: "Ваші ШІ-агенти читають зустрічі", en: "Your AI agents can read your meetings",
      uk2: "команда diduny для Claude Code і Codex", en2: "the diduny command for Claude Code and Codex",
    },
    {
      frame: "slider", duration: 2800, enter: "fade",
      camera: [[0, "full"], [400, [255, 288, 730, 165]]],
      highlight: { rect: [799, 330, 137, 46], at: 900 },
      uk: "Нові повзунки звуку й відтворення", en: "New sliders for sound and playback",
    },
    { end: true, duration: 2600, uk: "Онови Diduny → Check for Updates…", en: "Update: Diduny → Check for Updates…" },
  ],
};
