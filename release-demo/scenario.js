// Scenario for the release "What's new" GIF. One file per release: edit the scenes,
// preview with `open release-demo/player.html`, render with scripts/render_release_gif.sh.
// Scene types: title, race, keys, apps. Durations are in ms.
window.SCENARIO = {
  version: "2.18",
  scenes: [
    { type: "title", duration: 2200, title: "Diduny 2.18", subtitle: "What's new" },
    {
      type: "race",
      duration: 5200,
      caption: "Parakeet V3: text 0.37 s after Stop, on your Mac",
      lanes: [
        { name: "Parakeet V3", tag: "On-device", seconds: 0.37, highlight: true },
        { name: "Apple", tag: "On-device", seconds: 0.80 },
        { name: "Whisper Large v3 Turbo", tag: "On-device", seconds: 2.29 },
      ],
    },
    {
      type: "keys",
      duration: 4600,
      caption: "Force submit: press ⌘↩ while recording to paste and send",
      keys: ["⌘", "↩"],
      text: "Ship the release candidate today",
    },
    {
      type: "apps",
      duration: 4000,
      caption: "New About screen: Diduny, Papuga and AppCat",
      apps: [
        { name: "Diduny", tagline: "Dictation and transcription", glyph: "🎙", here: true },
        { name: "Papuga", tagline: "Fixes text typed in the wrong layout", glyph: "🦜" },
        { name: "AppCat", tagline: "Opens links where you want", glyph: "🐈" },
      ],
    },
    { type: "title", duration: 2400, title: "Update now", subtitle: "Diduny → Check for Updates…" },
  ],
};
