{
  lib,
  buildNpmPackage,
  fetchurl,
}:
buildNpmPackage rec {
  pname = "pi-coding-agent";
  version = "0.73.1";

  src = fetchurl {
    url = "https://registry.npmjs.org/@mariozechner/pi-coding-agent/-/pi-coding-agent-${version}.tgz";
    hash = "sha256-e/XUkmcMBP18WZ3ufm6qv/lkCEr/0hZ2YQfmdB33ouE=";
  };

  sourceRoot = "package";

  packageLock = ./package-lock.json;

  postPatch = ''
    cp ${packageLock} package-lock.json
  '';

  npmDepsHash = "sha256-8G5H4eQ5YkOUpP61Q1Ynq+5yDhgBbNOg2Z866+y5NNk=";

  dontNpmBuild = true;

  meta = {
    description = "Coding agent CLI with read, bash, edit, write tools and session management";
    homepage = "https://github.com/badlogic/pi-mono";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
    mainProgram = "pi";
  };
}
