{
  lib,
  stdenv,
  fetchFromGitHub,
  libpcap,
  versionCheckHook,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "whatpulse-pcap-service";
  version = "1.5.1";

  src = fetchFromGitHub {
    owner = "whatpulse";
    repo = "linux-external-pcap-service";
    tag = "v${finalAttrs.version}";
    hash = "sha256-YeUqY9n2EN/LNn2eQyisJld8wwCkF5A96tkvCIlaapc=";
  };

  # MODIFIED from upstream (the license's attribution terms require saying so):
  # the hard `geteuid() != 0` refusal is removed, so the service can run as an
  # unprivileged DynamicUser holding only the capabilities pcap actually needs
  # (see the unit in nixos.nix) instead of as full root. Nothing else changes;
  # the protocol to WhatPulse is untouched. --replace-fail makes a bump that
  # moves this check fail the build rather than silently keep the root gate.
  postPatch = ''
    substituteInPlace captureservice.cpp \
      --replace-fail 'if (geteuid() != 0)' 'if (false)'
  '';

  buildInputs = [ libpcap ];

  makeFlags = [ "CC=${stdenv.cc.targetPrefix}c++" ];

  installPhase = ''
    runHook preInstall
    install -Dm755 whatpulse-pcap-service -t $out/bin
    runHook postInstall
  '';

  # A hash bump is otherwise accepted with zero evidence the binary runs.
  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];

  meta = {
    description = "WhatPulse External PCap Service by WhatPulse: network stats capture for the AppImage client";
    homepage = "https://github.com/whatpulse/linux-external-pcap-service";
    changelog = "https://github.com/whatpulse/linux-external-pcap-service/releases";
    # CC BY-NC 4.0 plus WhatPulse-specific additional terms -- unfree.
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "whatpulse-pcap-service";
  };
})
