{ pkgs, ... }:

{
  home.packages = [
    (pkgs.writeScriptBin "koordinates-dev-protocol" ''
      #!/usr/bin/env bash
      curl -X POST -H 'Content-Type: application/json' -d "{\"url\": \"$1\"}" http://localhost:7281
    '')
  ]; 
}