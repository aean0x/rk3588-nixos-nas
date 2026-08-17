# Browser: the CDP browser + noVNC phone handoff are provisioned by
# services.hermesPnP.browser (composer). This file only selects the site
# engine — we run Brave instead of the chromium default.
{pkgs, ...}: {
  services.hermesPnP.browser.package = pkgs.brave;
}
