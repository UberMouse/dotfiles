{
  lib,
  buildNpmPackage,
  fetchzip,
  makeWrapper,
  jq,
  playwright-driver,
}:
buildNpmPackage (finalAttrs: {
  pname = "agent-browser";
  version = "0.15.0";

  src = fetchzip {
    url = "https://registry.npmjs.org/agent-browser/-/agent-browser-${finalAttrs.version}.tgz";
    hash = "sha256-8TATfBNRsXTyIlmdgfOd5s5hWo3b4etZFF4M/lQR1f8=";
  };

  npmDepsHash = "sha256-yuzKwOFKmkjN2iw04GFqtu8My2zvjUXj0rF/dz2tZOQ=";

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
    # Strip devDependencies to avoid peer dep conflicts (e.g. claude-agent-sdk wants zod ^4)
    ${jq}/bin/jq 'del(.devDependencies)' package.json > package2.json && mv package2.json package.json
  '';

  dontNpmBuild = true;

  # Skip postinstall — it tries to download binaries from GitHub,
  # but the tarball already ships prebuilt native binaries.
  npmFlags = [ "--ignore-scripts" ];

  postInstall = ''
    # Ensure the native linux binary is executable
    chmod +x $out/lib/node_modules/agent-browser/bin/agent-browser-linux-x64

    # Wrap the binary with PLAYWRIGHT_BROWSERS_PATH so it finds nix browsers
    wrapProgram $out/bin/agent-browser \
      --set PLAYWRIGHT_BROWSERS_PATH "${playwright-driver.browsers}" \
      --set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD "1"
  '';

  nativeBuildInputs = [ makeWrapper ];

  meta = {
    description = "CLI tool for browser automation with AI agents";
    homepage = "https://github.com/vercel-labs/agent-browser";
    license = lib.licenses.asl20;
    mainProgram = "agent-browser";
  };
})
