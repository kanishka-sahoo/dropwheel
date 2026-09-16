#!/bin/zsh
# Headless smoke test: converts fixtures in $1 (default /tmp/dwfix) to every target and runs every tool.
set -u
FIX="${1:-/tmp/dwfix}"
BIN="$(cd "$(dirname "$0")/.." && swift build --show-bin-path)/Dropwheel"
WORK="$FIX/run-$(date +%s)"; mkdir -p "$WORK"; cp "$FIX"/*.* "$WORK"/ 2>/dev/null
cd "$WORK"
pass=0; fail=0
run() { # label, args...
  local label="$1"; shift
  if out=$("$BIN" "$@" 2>&1); then pass=$((pass+1)); printf "ok   %s\n" "$label"
  else fail=$((fail+1)); printf "FAIL %s\n     %s\n" "$label" "$(echo "$out" | tail -2)"; fi
}
typeset -A targets
targets=(
  photo.png "jpg webp heic tiff avif bmp pdf docx"
  photo.jpg "png"
  mk.svg    "png jpg pdf"
  song.mp3  "m4a wav flac ogg opus aiff wma"
  clip.mp4  "mov mkv webm avi wmv gif mp3"
  notes.txt "pdf jpg png srt vtt"
  notes.pdf "docx jpg png txt"
  subs.srt  "vtt txt"
  project.zip "tar gz rar"
)
for f in ${(k)targets}; do for t in ${=targets[$f]}; do run "$f -> $t" --convert "$f" "$t"; done; done
# Second-generation checks (round trips through produced files).
run "photo.heic -> png" --convert photo.heic png
run "photo.webp -> jpg" --convert photo.webp jpg
run "photo.avif -> png" --convert photo.avif png
run "clip.mkv -> mp4" --convert clip.mkv mp4
run "clip.gif -> mp4" --convert clip.gif mp4
run "song.flac -> mp3" --convert song.flac mp3
run "notes.docx -> pdf" --convert notes.docx pdf
run "notes.docx -> txt" --convert notes.docx txt
run "subs.vtt -> srt" --convert subs.vtt srt
run "project.tar -> zip" --convert project.tar zip
run "project.tar.gz -> zip" --convert project.tar.gz zip
run "project.rar -> zip" --convert project.rar zip
# Smart conversions (fixtures are optional).
[ -f doc.md ] && for t in pdf png docx html txt; do run "doc.md -> $t" --convert doc.md $t; done
[ -f people.csv ] && for t in pdf png json html docx; do run "people.csv -> $t" --convert people.csv $t; done
[ -f people.json ] && for t in csv pdf; do run "people.json -> $t" --convert people.json $t; done
[ -f sample.py ] && for t in pdf png html; do run "sample.py -> $t" --convert sample.py $t; done
[ -f page.html ] && for t in pdf png txt md docx; do run "page.html -> $t" --convert page.html $t; done
[ -f notes.png ] && run "notes.png -> txt (OCR)" --convert notes.png txt
# Tools
for tool in compress removeMetadata editImage frameImage cropImage redactImage annotateImage; do run "photo.jpg $tool" --tool $tool photo.jpg; done
run "createPDF" --tool createPDF photo.jpg photo.png mk.svg
run "createCollage" --tool createCollage photo.jpg photo.png mk.svg
for tool in compress removeMetadata normalizeAudio trimAudio audioChannels audioToVideo redactAudio; do run "song.mp3 $tool" --tool $tool song.mp3; done
for tool in compress removeMetadata muteVideo trimVideo cropVideo changeVideoSpeed videoSnapshots splitVideo redactVideo; do run "clip.mp4 $tool" --tool $tool clip.mp4; done
run "joinVideos" --tool joinVideos clip.mp4 clip.mov
for tool in compress removeMetadata splitPDF organizePDF; do run "notes.pdf $tool" --tool $tool notes.pdf; done
run "mergePDF" --tool mergePDF notes.pdf notes.pdf
run "extractArchive" --tool extractArchive project.zip
echo "----- $pass passed, $fail failed  (outputs in $WORK)"
