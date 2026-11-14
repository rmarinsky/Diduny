// Release "What's new" montage. Stills are screenshots of the Diduny TEST build with demo data only
// (copied into the untracked release-demo/frames/) + camera moves, screen transitions and big UA/EN subtitles.
// Preview: open release-demo/player.html. Render: python3 scripts/render_release_gif.py
//
// Rects are [x, y, w, h] in the 1000×712 window space of the frames. "full" = whole window.
window.SCENARIO = {
  title: "Diduny",
  scenes: [
    {
      frame: "typing", duration: 4200,
      camera: [[0, "full"], [500, [240, 40, 760, 300]]],
      highlight: { rect: [252, 166, 736, 30], at: 1200 },
      uk: "Papuga тепер у Diduny", en: "Papuga is now part of Diduny",
      uk2: "текст, набраний не в тій розкладці, виправляється сам", en2: "text typed in the wrong layout fixes itself",
    },
    {
      frame: "typing", duration: 3400, enter: "fade",
      camera: [[0, [240, 40, 760, 300]]],
      uk: "Виділіть текст і двічі натисніть ⌥⇧", en: "Select text and press ⌥⇧ twice",
      uk2: "і він перейде в іншу розкладку", en2: "to turn it into the other layout",
    },
    {
      frame: "vocabulary", duration: 4000, enter: "slide",
      camera: [[0, "full"], [500, [240, 30, 760, 300]]],
      highlight: { rect: [262, 154, 698, 112], at: 1200 },
      masks: [[275, 162, 120, 18]],
      uk: "Слова, які ви часто набираєте, йдуть у словник", en: "Words you keep typing go to Vocabulary",
      uk2: "заміни чекають на ваш клік", en2: "replacements wait for your click",
    },
    {
      frame: "clipboard", duration: 4000, enter: "slide",
      camera: [[0, "full"], [500, [240, 40, 760, 440]]],
      highlight: { rect: [262, 200, 698, 270], at: 1200 },
      uk: "Історія буфера обміну", en: "Clipboard history",
      uk2: "тексти, скриншоти і все, що вставив Diduny", en2: "texts, screenshots and everything Diduny pasted",
    },
    {
      frame: "overview", duration: 3600, enter: "slide",
      camera: [[0, "full"], [400, [240, 90, 760, 160]]],
      highlight: { rect: [547, 113, 128, 108], at: 1000 },
      uk: "Виправлення розкладки на Overview", en: "Layout fixes on Overview",
      uk2: "і оновлення ставиться саме", en2: "and updates install themselves",
    },
    { end: true, duration: 2600, uk: "Typing → Layout fixes", en: "Typing → Layout fixes" },
  ],
};
