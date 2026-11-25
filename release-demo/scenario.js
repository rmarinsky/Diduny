// Release "What's new" montage. Card scenes need no screenshots.
// Preview: open release-demo/player.html. Render: python3 scripts/render_release_gif.py
window.SCENARIO = {
  title: "Diduny",
  scenes: [
    {
      card: "Календар із браузера", duration: 3400,
      uk: "Outlook або Google, включно з робочим профілем", en: "Outlook or Google, including a work profile",
      uk2: "перевіряє сторінку раз на хвилину", en2: "checks the page about once a minute",
    },
    {
      card: "Дві зустрічі в один час", duration: 3000, enter: "fade",
      uk: "Обидві лишаються на дні і в меню", en: "Both stay on the day and in the menu",
    },
    {
      card: "Менший Diduny", duration: 2800, enter: "fade",
      uk: "Застосунок приблизно втричі менший", en: "The app is about a third of the size",
    },
    { end: true, duration: 2200, uk: "Оновіться і пробуйте", en: "Update and try it" },
  ],
};
