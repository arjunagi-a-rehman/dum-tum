const copyButtons = document.querySelectorAll("[data-copy]");

for (const button of copyButtons) {
  const originalText = button.textContent;
  let resetTimer;
  let clickVersion = 0;

  button.addEventListener("click", async () => {
    const version = ++clickVersion;
    window.clearTimeout(resetTimer);
    let message;
    let label;
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
      message = "[ copied ]";
      label = "Install command copied";
    } catch {
      message = "[ copy failed ]";
      label = "Install command copy failed";
    }

    if (version !== clickVersion) return;
    button.textContent = message;
    button.setAttribute("aria-label", label);
    resetTimer = window.setTimeout(() => {
      button.textContent = originalText;
      button.setAttribute("aria-label", "Copy install command");
    }, 2000);
  });
}

const demoTabs = [...document.querySelectorAll("[data-demo-tab]")];
const demoPanels = [...document.querySelectorAll("[data-demo-panel]")];

function selectDemoTab(tab, moveFocus = false) {
  for (const item of demoTabs) {
    const active = item === tab;
    item.setAttribute("aria-selected", String(active));
    item.tabIndex = active ? 0 : -1;
  }

  for (const panel of demoPanels) {
    panel.hidden = panel.dataset.demoPanel !== tab.dataset.demoTab;
  }

  if (moveFocus) tab.focus();
}

for (const tab of demoTabs) {
  tab.addEventListener("click", () => selectDemoTab(tab));
  tab.addEventListener("keydown", (event) => {
    const current = demoTabs.indexOf(tab);
    const next = event.key === "ArrowRight"
      ? (current + 1) % demoTabs.length
      : event.key === "ArrowLeft"
        ? (current - 1 + demoTabs.length) % demoTabs.length
        : event.key === "Home"
          ? 0
          : event.key === "End"
            ? demoTabs.length - 1
            : -1;

    if (next >= 0) {
      event.preventDefault();
      selectDemoTab(demoTabs[next], true);
    }
  });
}
