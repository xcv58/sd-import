(function () {
  // Keep native controls available if the enhanced player cannot initialize.
  const player = document.querySelector("[data-video-player]");
  if (
    player &&
    player.querySelector("[data-video-play]")?.hasAttribute("aria-label")
  ) {
    const video = player.querySelector("video");
    // Only replace native controls once the shared player has initialized.
    if (player.dataset.playerReady === "true") {
      video.controls = false;
      player.querySelector("[data-video-overlay]").hidden = false;
      player.querySelector(".lite-video-controls").hidden = false;
    }
  }

  const gallery = document.querySelector("[data-gallery]");
  if (!gallery) return;
  const choices = [...gallery.querySelectorAll("[data-gallery-choice]")];
  const source = gallery.querySelector(".gallery-picture source");
  const image = gallery.querySelector(".gallery-picture img");
  const openLink = gallery.querySelector("[data-gallery-open]");
  const title = gallery.querySelector("[data-gallery-title]");
  const caption = gallery.querySelector("[data-gallery-caption]");
  const counter = gallery.querySelector("[data-gallery-count]");
  const dialog = document.querySelector(".screenshot-dialog");
  const dialogImage = dialog.querySelector("[data-dialog-image]");
  const original = dialog.querySelector("[data-dialog-original]");

  function select(choice) {
    const index = choices.indexOf(choice);
    const base = `${window.SDWebsite.assetPrefix}images/sd-import-${choice.dataset.stem}-light-20260905`;
    choices.forEach((item) => {
      if (item === choice) item.setAttribute("aria-current", "true");
      else item.removeAttribute("aria-current");
    });
    source.srcset = `${base}-640.webp 640w, ${base}-1200.webp 1200w, ${base}-1920.webp 1920w`;
    image.src = `${base}.png`;
    image.alt = choice.dataset.caption;
    title.textContent = choice.dataset.title;
    caption.textContent = choice.dataset.caption;
    counter.textContent = `${String(index + 1).padStart(2, "0")} / 07`;
    openLink.href = choice.href;
    openLink.setAttribute(
      "aria-label",
      window.SDWebsite.message("enlarge", {title: choice.dataset.title}),
    );
    const strip = choice.parentElement;
    const offset =
      choice.getBoundingClientRect().left - strip.getBoundingClientRect().left;
    if (offset < 0 || offset + choice.offsetWidth > strip.clientWidth) {
      strip.scrollLeft += offset - (strip.clientWidth - choice.offsetWidth) / 2;
    }
  }

  choices.forEach((choice) => {
    // Keep normal new-tab and no-JavaScript links to the original images.
    choice.addEventListener("click", (event) => {
      if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)
        return;
      event.preventDefault();
      select(choice);
    });
    choice.addEventListener("keydown", (event) => {
      const index = choices.indexOf(choice);
      let next;
      if (event.key === "ArrowRight") next = (index + 1) % choices.length;
      else if (event.key === "ArrowLeft")
        next = (index - 1 + choices.length) % choices.length;
      else if (event.key === "Home") next = 0;
      else if (event.key === "End") next = choices.length - 1;
      else if (event.key === " ") next = index;
      if (next === undefined) return;
      event.preventDefault();
      choices[next].focus({ preventScroll: true });
      select(choices[next]);
    });
  });

  openLink.addEventListener("click", (event) => {
    if (
      event.metaKey ||
      event.ctrlKey ||
      event.shiftKey ||
      event.altKey ||
      typeof dialog.showModal !== "function"
    )
      return;
    event.preventDefault();
    dialogImage.src = openLink.href;
    dialogImage.alt = image.alt;
    original.href = openLink.href;
    dialog.querySelector("#dialog-title").textContent = title.textContent;
    dialog.showModal();
  });
  const closeButton = dialog.querySelector("[data-gallery-close]");
  closeButton.addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () =>
    openLink.focus({ preventScroll: true }),
  );
  dialog.addEventListener("keydown", (event) => {
    if (event.key !== "Tab") return;
    if (event.shiftKey && document.activeElement === closeButton) {
      event.preventDefault();
      original.focus();
    } else if (!event.shiftKey && document.activeElement === original) {
      event.preventDefault();
      closeButton.focus();
    }
  });
  dialog.addEventListener("click", (event) => {
    const rect = dialog.getBoundingClientRect();
    if (
      event.target === dialog &&
      (event.clientX < rect.left ||
        event.clientX > rect.right ||
        event.clientY < rect.top ||
        event.clientY > rect.bottom)
    )
      dialog.close();
  });
})();
