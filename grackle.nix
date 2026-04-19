{ config, pkgs, ... }:

{
  virtualisation.docker.enable = true;
  users.users.taylorl.extraGroups = [ "docker" ];

  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers.grackle = {
    image = "ghcr.io/nick-pape/grackle:nightly-20260419";
    autoStart = true;
    ports = [
      "3000:3000"   # Web UI
      "7434:7434"   # gRPC (CLI)
    ];
    volumes = [
      "grackle-data:/data"
      "/home/taylorl/.claude:/home/node/.claude:ro"
      "/home/taylorl/.grackle:/data/.grackle"
      "/home/taylorl/code/kawaka:/kawaka"
    ];
  };
}
