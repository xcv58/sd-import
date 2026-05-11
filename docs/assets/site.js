(function () {
    const root = document.documentElement;
    const buttons = Array.from(document.querySelectorAll("[data-theme-value]"));

    function applyTheme(theme) {
        root.setAttribute("data-theme", theme);
        localStorage.setItem("theme", theme);
        buttons.forEach((button) => {
            const isActive = button.getAttribute("data-theme-value") === theme;
            button.classList.toggle("active", isActive);
            button.setAttribute("aria-pressed", String(isActive));
        });
    }

    const initialTheme = localStorage.getItem("theme") || "system";
    applyTheme(initialTheme);

    buttons.forEach((button) => {
        button.addEventListener("click", () => {
            applyTheme(button.getAttribute("data-theme-value") || "system");
        });
    });

    window.addEventListener("load", () => {
        document.body.classList.remove("preload");
    });
}());
