{
  lib,
  appimageTools,
  fetchurl,
}:
let
  pname = "whatpulse";
  version = "6.3.2";

  # Upstream publishes NO versioned download: the AppImage only ever lives at
  # this /latest/ path (the downloads page, the embedded zsync update info and
  # the flatpak all point at /latest/ too). So the hash is the only real pin,
  # and it goes stale the moment upstream ships. The failure is loud, not
  # silent: a rebuild that has to refetch (a nixpkgs bump changing
  # appimageTools, a GC'd source) dies with a hash mismatch, and the fix is
  # the UPDATE.md bump -- which must move `version` and `hash` together.
  src = fetchurl {
    url = "https://releases.whatpulse.org/latest/linux/whatpulse-linux-latest_amd64.AppImage";
    hash = "sha256-/XAFqiJD1NItaFkKQyA++hCSb/99UtUMltAFClvzqmQ=";
  };

  contents = appimageTools.extract { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  extraInstallCommands = ''
    install -Dm444 ${contents}/whatpulse.desktop -t $out/share/applications
    install -Dm444 ${contents}/whatpulse.png -t $out/share/icons/hicolor/512x512/apps
  '';

  # The unpacked AppImage, so UPDATE.md can read the real version out of the
  # binary -- the squashfs is compressed, so grepping the AppImage finds nothing.
  passthru.extracted = contents;

  meta = {
    description = "Keyboard, mouse, network and uptime statistics tracker";
    homepage = "https://whatpulse.org";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "whatpulse";
  };
}
