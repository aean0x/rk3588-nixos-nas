(() => {
  if (window.__modelRouterExtLoaded) return;
  window.__modelRouterExtLoaded = true;

  const CMDS = [
    { cmd: "/auto", label: "Auto", title: "Resume per-turn routing" },
    { cmd: "/t1", label: "T1 Flash", title: "Pin DeepSeek Flash" },
    { cmd: "/t2", label: "T2 Pro", title: "Pin DeepSeek Pro" },
    { cmd: "/t3", label: "T3 Grok", title: "Pin Grok 4.5" },
  ];

  let lastCmd = "/auto";

  function $(id) {
    return document.getElementById(id);
  }

  async function runSlash(cmd) {
    lastCmd = cmd;
    paintPressed();
    const input = $("msg");
    if (input && typeof window.send === "function") {
      input.value = cmd;
      if (typeof window.autoResize === "function") window.autoResize();
      try {
        await window.send();
      } catch (err) {
        if (typeof window.showToast === "function") {
          window.showToast(`Model Router: ${err.message || err}`, 3200);
        }
      }
      return;
    }
    if (typeof window.showToast === "function") {
      window.showToast("Model Router: composer send() not available", 2800);
    }
  }

  function paintPressed() {
    document.querySelectorAll(".mr-btn").forEach((btn) => {
      btn.setAttribute("aria-pressed", btn.dataset.cmd === lastCmd ? "true" : "false");
    });
  }

  function mountBar(host) {
    if (!host || host.querySelector(".mr-bar")) return;
    const bar = document.createElement("div");
    bar.className = "mr-bar";
    bar.id = "model-router-bar";
    const label = document.createElement("span");
    label.className = "mr-label";
    label.textContent = "Router";
    bar.appendChild(label);
    for (const spec of CMDS) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "mr-btn";
      btn.dataset.cmd = spec.cmd;
      btn.textContent = spec.label;
      btn.title = spec.title;
      btn.onclick = (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        void runSlash(spec.cmd);
      };
      bar.appendChild(btn);
    }
    host.appendChild(bar);
    paintPressed();
  }

  function findHost() {
    return (
      $("composer") ||
      document.querySelector(".composer") ||
      document.querySelector("footer.composer") ||
      $("msg")?.closest("form") ||
      $("msg")?.parentElement
    );
  }

  function tryMount() {
    const host = findHost();
    if (host) mountBar(host);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", tryMount);
  } else {
    tryMount();
  }
  const obs = new MutationObserver(() => tryMount());
  obs.observe(document.documentElement, { childList: true, subtree: true });
})();
