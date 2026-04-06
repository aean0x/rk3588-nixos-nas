let
  lib = import <nixpkgs/lib>;
  step = {
    name = "playwright";
    env = {
      PLAYWRIGHT_BROWSERS_PATH = "/ms-playwright";
    };
    post = "npx playwright install --with-deps chromium && chown -R 1000:1000 /ms-playwright";
  };
in
  "ENV ${lib.concatStringsSep " " (lib.mapAttrsToList (n: v: "${n}=${v}") step.env)}\nRUN npm install -g --force playwright\nRUN ${step.post}"
