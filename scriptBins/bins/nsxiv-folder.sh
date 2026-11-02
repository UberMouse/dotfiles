# Default image opener (wired as the image handler in home.nix).
#
# xdg-open hands a viewer exactly ONE file, so a plain `nsxiv %F` shows that
# picture and nothing else -- no stepping to its neighbours. This opens the
# whole folder instead, starting at the file that was opened:
#
#   nsxiv-folder FILE      FILE's folder, starting at FILE (n/p, arrows)
#   nsxiv-folder [DIR]     DIR (default .) in thumbnail mode
#   nsxiv-folder A B ...   exactly those files, passed straight through
#
# In nsxiv, Enter toggles between the single image and the thumbnail grid.
#
# The sibling list is filtered by extension rather than handed over whole:
# nsxiv's --start-at is an index into the ARGUMENT list, and it drops
# unloadable files as it meets them, so non-images before FILE would still
# land the start correctly, but a folder of thousands of non-images would be
# probed one by one. Extensions mirror the MimeType list in nsxiv.desktop.

nsxiv_opts=(--animate --quiet)

if (($# == 0)); then
  exec nsxiv "${nsxiv_opts[@]}" --thumbnail .
fi

if (($# > 1)); then
  exec nsxiv "${nsxiv_opts[@]}" -- "$@"
fi

target=$1

if [[ -d $target ]]; then
  exec nsxiv "${nsxiv_opts[@]}" --thumbnail -- "$target"
fi

if [[ ! -f $target ]]; then
  echo "nsxiv-folder: no such file: $target" >&2
  exit 1
fi

dir=$(dirname -- "$target")
base=$(basename -- "$target")

shopt -s nullglob nocaseglob
siblings=()
for f in "$dir"/*.{png,jpg,jpeg,jpe,jfif,gif,bmp,tif,tiff,webp,avif,heic,heif,jxl,jp2,svg,tga,ppm,pgm,pbm,pnm,xpm,ico}; do
  [[ -f $f ]] && siblings+=("$f")
done
shopt -u nullglob nocaseglob

# One glob per extension yields each extension's files as its own sorted
# run; re-sort the union so the folder reads in name order. NUL-delimited so
# no filename can split the list.
sorted=()
if ((${#siblings[@]})); then
  while IFS= read -r -d '' f; do
    sorted+=("$f")
  done < <(printf '%s\0' "${siblings[@]}" | sort -z -V)
fi

# 1-based index of the opened file; if its extension wasn't in the list
# (an odd format, no extension), put it first so it still opens.
start=0
for i in "${!sorted[@]}"; do
  if [[ ${sorted[i]##*/} == "$base" ]]; then
    start=$((i + 1))
    break
  fi
done
if ((start == 0)); then
  sorted=("$target" "${sorted[@]}")
  start=1
fi

exec nsxiv "${nsxiv_opts[@]}" --start-at "$start" -- "${sorted[@]}"
