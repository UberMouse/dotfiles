# plannotator patches

Every `*.patch` here is applied to the upstream source, in filename order, by
`../package.nix`. Name them `NNNN-short-description.patch` (what
`git format-patch` emits) so the order is explicit.

Make and rebase them against a checkout of the pinned tag. The workflow is in
`../UPDATE.md`.
