{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  cmake,
  openssl,
  onnxruntime,
}:

rustPlatform.buildRustPackage rec {
  pname = "monodex";
  version = "0.1.0-unstable-2026-04-10";

  src = fetchFromGitHub {
    owner = "microsoft";
    repo = "monodex";
    rev = "8ec71b16328639332bacdf70b699dbaf8d02a382";
    hash = "sha256-TSFmRMsHKbPoYmAWXCBJ4jU0fRztbP6TV5Y+jm9CAVM=";
  };

  cargoPatches = [
    ./disable-download-binaries.patch
  ];

  cargoHash = "sha256-SoqWIKyDYBw/KV3tQ1jgahKuqZf5PtzK1k5r4V6rAUo=";

  nativeBuildInputs = [
    pkg-config
    cmake
    rustPlatform.bindgenHook
  ];

  buildInputs = [
    openssl
    onnxruntime
  ];

  env.ORT_LIB_LOCATION = "${onnxruntime}/lib";
  env.ORT_PREFER_DYNAMIC_LINK = "1";

  postFixup = ''
    patchelf --add-rpath ${onnxruntime}/lib $out/bin/monodex
  '';

  # Tests require qdrant running
  doCheck = false;

  meta = with lib; {
    description = "Semantic search indexer for monorepos using Qdrant vector database";
    homepage = "https://github.com/microsoft/monodex";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "monodex";
  };
}
