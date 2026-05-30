(function () {
    const root = document.documentElement;
    const buttons = Array.from(document.querySelectorAll("[data-theme-value]"));
    const systemScheme = window.matchMedia("(prefers-color-scheme: dark)");
    const storageKey = "theme";
    const themes = new Set(["system", "light", "dark"]);

    function readTheme() {
        try {
            const storedTheme = localStorage.getItem(storageKey);
            return themes.has(storedTheme) ? storedTheme : "system";
        } catch {
            return "system";
        }
    }

    function saveTheme(theme) {
        try {
            localStorage.setItem(storageKey, theme);
        } catch {
            // Browsers can deny storage in constrained privacy modes.
        }
    }

    function resolvedTheme(theme) {
        if (theme === "system") {
            return systemScheme.matches ? "dark" : "light";
        }
        return theme;
    }

    function setAttributeIfChanged(element, name, value) {
        if (!value || element.getAttribute(name) === value) {
            return false;
        }
        element.setAttribute(name, value);
        return true;
    }

    function themeValue(element, mode, name) {
        return element.getAttribute(`data-${mode}-${name}`);
    }

    function applyThemeMedia(theme) {
        const mode = resolvedTheme(theme);
        const videosToReload = new Set();
        const mediaElements = document.querySelectorAll("[data-light-src], [data-dark-src], [data-light-srcset], [data-dark-srcset], [data-light-poster], [data-dark-poster]");

        mediaElements.forEach((element) => {
            const srcset = themeValue(element, mode, "srcset");
            const poster = themeValue(element, mode, "poster");
            const src = themeValue(element, mode, "src");

            setAttributeIfChanged(element, "srcset", srcset);
            setAttributeIfChanged(element, "poster", poster);

            if (setAttributeIfChanged(element, "src", src) && element.tagName === "SOURCE" && element.parentElement?.tagName === "VIDEO") {
                videosToReload.add(element.parentElement);
            }
        });

        videosToReload.forEach((video) => {
            video.load();
            video.dispatchEvent(new CustomEvent("sdimport:mediareload"));
        });
    }

    function formatTime(value) {
        if (!Number.isFinite(value) || value < 0) {
            return "0:00";
        }

        const totalSeconds = Math.floor(value);
        const minutes = Math.floor(totalSeconds / 60);
        const seconds = String(totalSeconds % 60).padStart(2, "0");
        return `${minutes}:${seconds}`;
    }

    function setupVideoPlayer(player) {
        const video = player.querySelector("video");
        const playButton = player.querySelector("[data-video-play]");
        const overlayButton = player.querySelector("[data-video-overlay]");
        const scrubber = player.querySelector("[data-video-scrubber]");
        const progressFill = player.querySelector("[data-video-progress]");
        const currentTime = player.querySelector("[data-video-current]");
        const durationTime = player.querySelector("[data-video-duration]");

        if (!video || !playButton || !overlayButton || !scrubber || !progressFill || !currentTime || !durationTime) {
            return;
        }

        let isScrubbing = false;

        function duration() {
            return Number.isFinite(video.duration) && video.duration > 0 ? video.duration : 0;
        }

        function progressRatio() {
            const total = duration();
            return total > 0 ? Math.min(1, Math.max(0, video.currentTime / total)) : 0;
        }

        function updatePlaybackState() {
            const isPlaying = !video.paused && !video.ended;
            player.classList.toggle("is-playing", isPlaying);
            playButton.setAttribute("aria-label", isPlaying ? "Pause screencast" : "Play screencast");
            overlayButton.setAttribute("aria-label", isPlaying ? "Pause screencast" : "Play screencast");
        }

        function updateTimeline() {
            const ratio = progressRatio();
            const percent = `${ratio * 100}%`;
            progressFill.style.width = percent;
            scrubber.style.setProperty("--video-progress", percent);
            scrubber.setAttribute("aria-valuenow", String(Math.round(ratio * 1000)));
            scrubber.setAttribute("aria-valuetext", `${formatTime(video.currentTime)} of ${formatTime(duration())}`);
            currentTime.textContent = formatTime(video.currentTime);
            durationTime.textContent = formatTime(duration());
        }

        function seekToRatio(ratio) {
            const total = duration();
            if (total <= 0) {
                return;
            }
            const nextTime = Math.min(1, Math.max(0, ratio)) * total;
            video.currentTime = nextTime;
            currentTime.textContent = formatTime(nextTime);
            updateTimeline();
        }

        function seekFromPoint(clientX) {
            const rect = scrubber.getBoundingClientRect();
            const ratio = rect.width > 0 ? (clientX - rect.left) / rect.width : 0;
            seekToRatio(ratio);
        }

        function togglePlayback() {
            if (video.paused || video.ended) {
                video.play().catch(() => {
                    updatePlaybackState();
                });
            } else {
                video.pause();
            }
        }

        playButton.addEventListener("click", togglePlayback);
        overlayButton.addEventListener("click", togglePlayback);
        video.addEventListener("click", togglePlayback);

        scrubber.addEventListener("pointerdown", (event) => {
            event.preventDefault();
            isScrubbing = true;
            scrubber.setPointerCapture?.(event.pointerId);
            seekFromPoint(event.clientX);
        });

        scrubber.addEventListener("pointermove", (event) => {
            if (isScrubbing) {
                seekFromPoint(event.clientX);
            }
        });

        scrubber.addEventListener("pointerup", (event) => {
            if (!isScrubbing) {
                return;
            }
            seekFromPoint(event.clientX);
            scrubber.releasePointerCapture?.(event.pointerId);
            isScrubbing = false;
        });

        scrubber.addEventListener("pointercancel", () => {
            isScrubbing = false;
        });

        scrubber.addEventListener("keydown", (event) => {
            const total = duration();
            if (total <= 0) {
                return;
            }

            if (event.key === "ArrowLeft" || event.key === "ArrowDown") {
                event.preventDefault();
                video.currentTime = Math.max(0, video.currentTime - 5);
                updateTimeline();
            } else if (event.key === "ArrowRight" || event.key === "ArrowUp") {
                event.preventDefault();
                video.currentTime = Math.min(total, video.currentTime + 5);
                updateTimeline();
            } else if (event.key === "Home") {
                event.preventDefault();
                video.currentTime = 0;
                updateTimeline();
            } else if (event.key === "End") {
                event.preventDefault();
                video.currentTime = total;
                updateTimeline();
            }
        });

        video.addEventListener("play", updatePlaybackState);
        video.addEventListener("pause", updatePlaybackState);
        video.addEventListener("ended", updatePlaybackState);
        video.addEventListener("timeupdate", updateTimeline);
        video.addEventListener("loadedmetadata", updateTimeline);
        video.addEventListener("durationchange", updateTimeline);
        video.addEventListener("sdimport:mediareload", () => {
            currentTime.textContent = "0:00";
            updatePlaybackState();
            updateTimeline();
        });

        updatePlaybackState();
        updateTimeline();
        window.setTimeout(updateTimeline, 150);
        window.setTimeout(updateTimeline, 700);
    }

    function applyTheme(theme) {
        const nextTheme = themes.has(theme) ? theme : "system";
        root.setAttribute("data-theme", nextTheme);
        saveTheme(nextTheme);
        applyThemeMedia(nextTheme);

        buttons.forEach((button) => {
            const isActive = button.getAttribute("data-theme-value") === nextTheme;
            button.classList.toggle("active", isActive);
            button.setAttribute("aria-pressed", String(isActive));
        });
    }

    const initialTheme = readTheme();
    applyTheme(initialTheme);

    buttons.forEach((button) => {
        button.addEventListener("click", () => {
            applyTheme(button.getAttribute("data-theme-value") || "system");
        });
    });

    document.querySelectorAll("[data-video-player]").forEach(setupVideoPlayer);

    const systemThemeDidChange = () => {
        if (readTheme() === "system") {
            applyThemeMedia("system");
        }
    };

    if (typeof systemScheme.addEventListener === "function") {
        systemScheme.addEventListener("change", systemThemeDidChange);
    } else if (typeof systemScheme.addListener === "function") {
        systemScheme.addListener(systemThemeDidChange);
    }

    window.addEventListener("load", () => {
        document.body.classList.remove("preload");
    });
}());
