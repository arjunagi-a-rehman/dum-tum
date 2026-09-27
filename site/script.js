const copyButtons = document.querySelectorAll("[data-copy]");

for (const button of copyButtons) {
  button.addEventListener("click", async () => {
    const originalText = button.textContent;
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
      button.textContent = "[ copied ]";
      button.setAttribute("aria-label", "Install command copied");
    } catch {
      button.textContent = "[ copy failed ]";
    }
    window.setTimeout(() => {
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
