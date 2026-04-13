{
  lib,
  buildNpmPackage,
  fetchzip,
  makeWrapper,
  playwright-driver,
  playwright-test,
}:
buildNpmPackage (finalAttrs: {
  pname = "playwright-cli";
  version = "0.1.7";

  src = fetchzip {
    url = "https://registry.npmjs.org/@playwright/cli/-/cli-${finalAttrs.version}.tgz";
    hash = "sha256-irw1CARad6w4/tFbpi8pY4mDaQF191b+jxr8ZSkaQMc=";
  };

  npmDepsHash = "sha256-S0z7i5tU9rP1jBhrCR/yDsboWSmBWFqKHeQ/F4QYvvU=";

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  dontNpmBuild = true;

  # Don't let npm fetch browsers or run any lifecycle scripts.
  npmFlags = [ "--ignore-scripts" ];

  postInstall = ''
    pkgdir=$out/lib/node_modules/@playwright/cli

    # Replace the npm-bundled playwright / playwright-core with the ones from
    # the playwright-web-flake, so the CLI code (which only requires
    # playwright-core/lib/tools/cli-client/program) runs against the exact
    # playwright-core that matches the nix-provided browsers.
    rm -rf $pkgdir/node_modules/playwright $pkgdir/node_modules/playwright-core
    ln -s ${playwright-test}/lib/node_modules/playwright       $pkgdir/node_modules/playwright
    ln -s ${playwright-test}/lib/node_modules/playwright-core  $pkgdir/node_modules/playwright-core

    # Default to --browser=chromium so the CLI uses the nix-provided bundled
    # chromium. Upstream default is the "chrome" channel, which expects Google
    # Chrome at /opt/google/chrome/chrome (not the nix chromium). A later
    # --browser=... argument from the user still takes precedence.
    wrapProgram $out/bin/playwright-cli \
      --set PLAYWRIGHT_BROWSERS_PATH "${playwright-driver.browsers}" \
      --set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD "1" \
      --add-flags "--browser=chromium"
  '';

  nativeBuildInputs = [ makeWrapper ];

  meta = {
    description = "Official Playwright CLI (@playwright/cli)";
    homepage = "https://playwright.dev";
    license = lib.licenses.asl20;
    mainProgram = "playwright-cli";
  };
})
