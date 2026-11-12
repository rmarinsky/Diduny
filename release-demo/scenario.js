// Release "What's new" montage. Real app frames (release-demo/frames, captured from the Diduny DEV build
// with demo data only) + camera moves, screen transitions and big UA/EN subtitles.
// Preview: open release-demo/player.html. Render: python3 scripts/render_release_gif.py
//
// Rects are [x, y, w, h] in the 1000×712 window space of the frames. "full" = whole window.
window.SCENARIO = {
  title: "Diduny",
  scenes: [
    {
      frame: "vocabulary", duration: 3800,
      camera: [[0, "full"], [500, [250, 40, 740, 400]]],
      highlight: { rect: [262, 155, 714, 210], at: 1300 },
      uk: "Словник і контекст", en: "Vocabulary & context",
      uk2: "імена й терміни, які Diduny Cloud має чути правильно", en2: "names and terms Diduny Cloud should get right",
    },
    {
      frame: "vocabulary_glossary", duration: 3600, enter: "slide",
      camera: [[0, "full"], [400, [250, 400, 740, 300]]],
      highlight: { rect: [262, 447, 714, 225], at: 1000 },
      uk: "Глосарій перекладу і дані календаря", en: "Translation glossary and calendar context",
      uk2: "назва й учасники зустрічі з календаря", en2: "meeting title and attendees from the calendar",
    },
    {
      frame: "vocabulary", duration: 3200, enter: "fade",
      camera: [[0, "full"]],
      uk: "Кажіть «кома», «новий рядок», «скасуй це»", en: "Say \"comma\", \"new line\", \"scratch that\"",
      uk2: "і тиша більше не обриває запис зустрічі", en2: "and quiet moments no longer end a meeting recording",
    },
    { end: true, duration: 2600, uk: "Онови Diduny → Check for Updates…", en: "Update: Diduny → Check for Updates…" },
  ],
};
