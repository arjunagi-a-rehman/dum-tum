const copyButton = document.querySelector("[data-copy]");

if (copyButton) {
  copyButton.addEventListener("click", async () => {
    const command = copyButton.dataset.copy;
    try {
      await navigator.clipboard.writeText(command);
      copyButton.textContent = "Copied!";
      copyButton.setAttribute("aria-label", "Install command copied");
      window.setTimeout(() => {
        copyButton.textContent = "Copy";
        copyButton.setAttribute("aria-label", "Copy install command");
      }, 2000);
    } catch {
      copyButton.textContent = "Copy failed";
      window.setTimeout(() => { copyButton.textContent = "Copy"; }, 2000);
    }
  });
}
