#!/usr/bin/env bash
set -euo pipefail

RSYNC_SOURCE="${RSYNC_SOURCE:-gutenberg.pglaf.org::gutenberg-epub}"
RUN_TARGET_MIB="${RUN_TARGET_MIB:-2800}"
REPO_TARGET_GIB="${REPO_TARGET_GIB:-8}"
MAX_FILE_MIB="${MAX_FILE_MIB:-90}"
PUSH_BATCH_MIB="${PUSH_BATCH_MIB:-450}"
STATE_FILE="${STATE_FILE:-epub-continuation-state.json}"
INDEX_FILE="${INDEX_FILE:-epub-index.tsv}"
SKIPPED_FILE="${SKIPPED_FILE:-epub-skipped-large.tsv}"
OUT_DIR="${OUT_DIR:-generated_epubs}"

RUN_TARGET_BYTES=$((RUN_TARGET_MIB * 1024 * 1024))
REPO_TARGET_BYTES=$((REPO_TARGET_GIB * 1024 * 1024 * 1024))
MAX_FILE_BYTES=$((MAX_FILE_MIB * 1024 * 1024))
PUSH_BATCH_BYTES=$((PUSH_BATCH_MIB * 1024 * 1024))

for c in rsync python3 git; do command -v "$c" >/dev/null 2>&1 || { echo "$c is required"; exit 1; }; done

mkdir -p "$OUT_DIR"

readarray -t STATE < <(python3 - "$STATE_FILE" <<'PY'
import json,sys
p=sys.argv[1]
try:
    d=json.load(open(p,encoding='utf-8'))
except Exception:
    d={}
print(d.get('last_path',''))
print(int(d.get('total_bytes_repo',0)))
print(int(d.get('total_files_repo',0)))
PY
)
LAST_PATH="${STATE[0]:-}"
TOTAL_BYTES="${STATE[1]:-0}"
TOTAL_FILES="${STATE[2]:-0}"

if (( TOTAL_BYTES >= REPO_TARGET_BYTES )); then
  echo "Repository target already reached: $TOTAL_BYTES bytes"
  exit 0
fi

REMAINING=$((REPO_TARGET_BYTES - TOTAL_BYTES))
if (( RUN_TARGET_BYTES > REMAINING )); then RUN_TARGET_BYTES="$REMAINING"; fi

echo "Listing EPUB files from $RSYNC_SOURCE ..."
rsync -r --list-only --timeout=600 "$RSYNC_SOURCE" > /tmp/rsync-list.txt

python3 - "$LAST_PATH" "$RUN_TARGET_BYTES" "$MAX_FILE_BYTES" <<'PY'
import sys,re
last=sys.argv[1]; target=int(sys.argv[2]); maxf=int(sys.argv[3])
items=[]
for line in open('/tmp/rsync-list.txt',encoding='utf-8',errors='replace'):
    parts=line.split()
    if len(parts)<5: continue
    try: size=int(parts[1])
    except: continue
    path=parts[-1]
    if not re.search(r'/pg\d+\.epub$',path): continue
    items.append((path,size))
items.sort()
sel=[]; skipped=[]; total=0
for path,size in items:
    if last and path<=last: continue
    if size>maxf:
        skipped.append((path,size)); continue
    if sel and total+size>target: break
    sel.append((path,size)); total+=size
with open('/tmp/selected.tsv','w',encoding='utf-8') as f:
    for p,s in sel: f.write(f'{s}\t{p}\n')
with open('/tmp/selected.paths','w',encoding='utf-8') as f:
    for p,_ in sel: f.write(p+'\n')
with open('/tmp/skipped.tsv','w',encoding='utf-8') as f:
    for p,s in skipped: f.write(f'{s}\t{p}\n')
print(f'selected={len(sel)} bytes={total} last={sel[-1][0] if sel else ""}')
PY

if [[ ! -s /tmp/selected.paths ]]; then
  python3 - "$STATE_FILE" "$RSYNC_SOURCE" "$LAST_PATH" "$TOTAL_BYTES" "$TOTAL_FILES" <<'PY'
import json,sys
p,src,last,b,f=sys.argv[1:]
json.dump({'collection':'Project Gutenberg generated EPUB without images','rsync_source':src,'last_path':last,'total_bytes_repo':int(b),'total_files_repo':int(f),'complete':True},open(p,'w',encoding='utf-8'),indent=2)
PY
  git add "$STATE_FILE"
  git commit -m "Mark generated EPUB collection complete" || true
  git push origin HEAD:main
  exit 0
fi

rsync -avR --timeout=600 --files-from=/tmp/selected.paths "$RSYNC_SOURCE" "$OUT_DIR/"

[[ -f "$INDEX_FILE" ]] || printf 'bytes\tpath\n' > "$INDEX_FILE"
[[ -f "$SKIPPED_FILE" ]] || printf 'bytes\tpath\n' > "$SKIPPED_FILE"
cat /tmp/skipped.tsv >> "$SKIPPED_FILE" || true

batch_bytes=0; batch_files=0; batch_no=1; current_last="$LAST_PATH"
while IFS=$'\t' read -r size path; do
  [[ -z "${path:-}" ]] && continue
  git add --sparse "$OUT_DIR/$path"
  printf '%s\t%s\n' "$size" "$path" >> "$INDEX_FILE"
  batch_bytes=$((batch_bytes + size)); batch_files=$((batch_files + 1)); current_last="$path"

  if (( batch_bytes >= PUSH_BATCH_BYTES )); then
    TOTAL_BYTES=$((TOTAL_BYTES + batch_bytes)); TOTAL_FILES=$((TOTAL_FILES + batch_files))
    python3 - "$STATE_FILE" "$RSYNC_SOURCE" "$current_last" "$TOTAL_BYTES" "$TOTAL_FILES" <<'PY'
import json,sys
p,src,last,b,f=sys.argv[1:]
json.dump({'collection':'Project Gutenberg generated EPUB without images','rsync_source':src,'last_path':last,'total_bytes_repo':int(b),'total_files_repo':int(f),'complete':False},open(p,'w',encoding='utf-8'),indent=2)
PY
    git add "$STATE_FILE" "$INDEX_FILE" "$SKIPPED_FILE"
    git commit -m "Add generated EPUB batch ${batch_no} (${batch_files} files)"
    git push origin HEAD:main
    batch_bytes=0; batch_files=0; batch_no=$((batch_no+1))
  fi
done < /tmp/selected.tsv

if (( batch_files > 0 )); then
  TOTAL_BYTES=$((TOTAL_BYTES + batch_bytes)); TOTAL_FILES=$((TOTAL_FILES + batch_files))
  python3 - "$STATE_FILE" "$RSYNC_SOURCE" "$current_last" "$TOTAL_BYTES" "$TOTAL_FILES" <<'PY'
import json,sys
p,src,last,b,f=sys.argv[1:]
json.dump({'collection':'Project Gutenberg generated EPUB without images','rsync_source':src,'last_path':last,'total_bytes_repo':int(b),'total_files_repo':int(f),'complete':False},open(p,'w',encoding='utf-8'),indent=2)
PY
  git add "$STATE_FILE" "$INDEX_FILE" "$SKIPPED_FILE"
  git commit -m "Add generated EPUB batch ${batch_no} (${batch_files} files)"
  git push origin HEAD:main
fi

echo "Checkpoint: $current_last"
echo "Repository EPUB bytes: $TOTAL_BYTES"
echo "Repository EPUB files: $TOTAL_FILES"
