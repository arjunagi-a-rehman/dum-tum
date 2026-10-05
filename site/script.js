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

const installTabs = [...document.querySelectorAll("[data-install-tab]")];
const installPanels = [...document.querySelectorAll("[data-install-panel]")];
const installCount = document.querySelector("[data-install-count]");
const installPrevious = document.querySelector("[data-install-prev]");
const installNext = document.querySelector("[data-install-next]");
const installTabList = document.querySelector(".install-step-list");
const installMobile = window.matchMedia("(max-width: 700px)");

function setInstallOrientation() {
  installTabList.setAttribute("aria-orientation", installMobile.matches ? "horizontal" : "vertical");
  if (installMobile.matches) {
    const selected = installTabs.findIndex((tab) => tab.getAttribute("aria-selected") === "true");
    centerInstallTab(selected);
  }
}

function centerInstallTab(index) {
  installTabList.scrollLeft += installTabs[index].getBoundingClientRect().left
    - installTabList.getBoundingClientRect().left
    - (installTabList.clientWidth - installTabs[index].clientWidth) / 2;
}

setInstallOrientation();
installMobile.addEventListener("change", setInstallOrientation);

function selectInstallStep(index, moveFocus = false) {
  for (const [position, tab] of installTabs.entries()) {
    const active = position === index;
    tab.setAttribute("aria-selected", String(active));
    tab.tabIndex = active ? 0 : -1;
  }

  for (const panel of installPanels) {
    panel.hidden = panel.dataset.installPanel !== installTabs[index].dataset.installTab;
  }

  installCount.textContent = `${String(index + 1).padStart(2, "0")} / ${String(installTabs.length).padStart(2, "0")}`;
  installPrevious.disabled = index === 0;
  installNext.disabled = index === installTabs.length - 1;
  if (moveFocus) installTabs[index].focus();
  if (installMobile.matches) centerInstallTab(index);
}

for (const [index, tab] of installTabs.entries()) {
  tab.addEventListener("click", () => selectInstallStep(index));
  tab.addEventListener("keydown", (event) => {
    const next = event.key === "ArrowRight" || event.key === "ArrowDown"
      ? (index + 1) % installTabs.length
      : event.key === "ArrowLeft" || event.key === "ArrowUp"
        ? (index - 1 + installTabs.length) % installTabs.length
        : event.key === "Home"
          ? 0
          : event.key === "End"
            ? installTabs.length - 1
            : -1;

    if (next >= 0) {
      event.preventDefault();
      selectInstallStep(next, true);
    }
  });
}

installPrevious.addEventListener("click", () => {
  const current = installTabs.findIndex((tab) => tab.getAttribute("aria-selected") === "true");
  selectInstallStep(current - 1);
});

installNext.addEventListener("click", () => {
  const current = installTabs.findIndex((tab) => tab.getAttribute("aria-selected") === "true");
  selectInstallStep(current + 1);
});
