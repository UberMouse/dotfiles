# Home Assistant MCP server (homeassistant-ai/ha-mcp), launched via uvx rather
# than packaged from source: it pulls ~70 PyPI deps (fastmcp & co.) that
# nixpkgs does not carry at the versions it pins. Instead the launch is made
# reproducible from both ends:
#   - `version` pins ha-mcp itself (a PyPI release is immutable once published);
#   - `excludeNewer` freezes the TRANSITIVE resolution to what existed on that
#     date, so a dependency release can't change what runs between bumps. This
#     thing holds an admin token for the house -- nothing in it floats.
# The interpreter is nixpkgs' python313 with uv's own downloads disabled: a
# uv-managed CPython is a generic-linux binary that NixOS can't be relied on
# to run. Verified 2026-10-02 that the native wheels (pydantic_core) load
# under it and the server answers initialize + tools/list over stdio.
#
# The token/URL are NOT handled here -- the op-cached wrapper in
# scriptBins/default.nix (opTools.ha-mcp) injects them and execs this.
{
  writeShellApplication,
  uv,
  python313,
}:
let
  version = "8.6.0";
  excludeNewer = "2026-10-02";
in
(writeShellApplication {
  name = "ha-mcp";
  runtimeInputs = [ uv ];
  text = ''
    export UV_PYTHON_DOWNLOADS=never
    exec uvx --python ${python313}/bin/python3 --exclude-newer ${excludeNewer} \
      --from ha-mcp==${version} ha-mcp "$@"
  '';
}).overrideAttrs
  { inherit version; }
