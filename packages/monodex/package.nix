{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  cmake,
  protobuf,
  openssl,
  onnxruntime,
}:

rustPlatform.buildRustPackage rec {
  pname = "monodex";
  version = "0.1.0-unstable-2026-04-26";

  src = fetchFromGitHub {
    owner = "microsoft";
    repo = "monodex";
    rev = "66bc38818cace6fb9a809f74486570b4a6329757";
    hash = "sha256-FHDOMoLkSRgE237rbDWN5g47mUUjrjBK5+fLTkpe5YQ=";
  };

  cargoPatches = [
    ./disable-download-binaries.patch
  ];

  cargoHash = "sha256-AEoMEKeIKJnHNV6J6VKfyrxYk8y5Hdp4sxyUhc4lF4U=";

  nativeBuildInputs = [
    pkg-config
    cmake
    rustPlatform.bindgenHook
    protobuf
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

  doCheck = false;

  meta = with lib; {
    description = "Semantic search indexer for monorepos using Qdrant vector database";
    homepage = "https://github.com/microsoft/monodex";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "monodex";
  };
}
