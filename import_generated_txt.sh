#!/usr/bin/env bash
set -euo pipefail

RSYNC_SOURCE="${RSYNC_SOURCE:-gutenberg.pglaf.org::gutenberg-epub}"
RUN_TARGET_MIB="${RUN_TARGET_MIB:-2500}"
REPO_TARGET_GIB="${REPO_TARGET_GIB:-8}"
MAX_FILE_MIB="${MAX_FILE_MIB:-90}"
PUSH_BATCH_MIB="${PUSH_BATCH_MIB:-400}"
STATE_FILE="${STATE_FILE:-txt-continuation-state.json}"
INDEX_FILE="${INDEX_FILE:-txt-index.tsv}"
OUT_DIR="${OUT_DIR:-generated_txt}"

RUN_TARGET_BYTES=$((RUN_TARGET_MIB * 1024 * 1024))
REPO_TARGET_BYTES=$((REPO_TARGET_GIB * 1024 * 1024 * 1024))
MAX_FILE_BYTES=$((MAX_FILE_MIB * 1024 * 1024))
PUSH_BATCH_BYTES=$((PUSH_BATCH_MIB * 1024 * 1024))

for c in rsync python3 git; do command -v "$c" >/dev/null 2>&1 || { echo "$c is required"; exit 1; }; done
mkdir -p "$OUT_DIR"

readarray -t STATE < <(python3 - "$STATE_FILE" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:
    d={}
print(int(d.get('last_id',0)))
print(int(d.get('total_bytes_repo',0)))
print(int(d.get('total_files_repo',0)))
PY
)
LAST_ID="${STATE[0]:-0}"
TOTAL_BYTES="${STATE[1]:-0}"
TOTAL_FILES="${STATE[2]:-0}"

if (( TOTAL_BYTES >= REPO_TARGET_BYTES )); then
  echo "Repository target already reached: $TOTAL_BYTES bytes"
  exit 0
fi
REMAINING=$((REPO_TARGET_BYTES - TOTAL_BYTES))
if (( RUN_TARGET_BYTES > REMAINING )); then RUN_TARGET_BYTES="$REMAINING"; fi

echo "Listing generated TXT collection from $RSYNC_SOURCE ..."
rsync -r --list-only --timeout=600 "$RSYNC_SOURCE" > /tmp/rsync-list.txt

python3 - "$LAST_ID" "$RUN_TARGET_BYTES" "$MAX_FILE_BYTES" <<'PY'
import re,sys
last_id=int(sys.argv[1]); target=int(sys.argv[2]); max_file=int(sys.argv[3])
items=[]
for line in open('/tmp/rsync-list.txt',encoding='utf-8',errors='replace'):
    parts=line.split()
    if len(parts)<5: continue
    try: size=int(parts[1])
    except: continue
    path=parts[-1]
    m=re.search(r'/pg(\d+)\.txt$',path)
    if not m: continue
    gid=int(m.group(1))
    items.append((gid,size,path))
items.sort(key=lambda x:x[0])
sel=[]; total=0
for gid,size,path in items:
    if gid<=last_id: continue
    if size>max_file: continue
    if sel and total+size>target: break
    sel.append((gid,size,path)); total+=size
with open('/tmp/selected.tsv','w',encoding='utf-8') as f:
    for gid,size,path in sel: f.write(f'{gid}\t{size}\t{path}\n')
with open('/tmp/selected.paths','w',encoding='utf-8') as f:
    for _,_,path in sel: f.write(path+'\n')
print(f'selected={len(sel)} bytes={total} last_id={sel[-1][0] if sel else last_id}')
PY

if [[ ! -s /tmp/selected.paths ]]; then
  python3 - "$STATE_FILE" "$LAST_ID" "$TOTAL_BYTES" "$TOTAL_FILES" <<'PY'
import json,sys
p,last,b,f=sys.argv[1:]
json.dump({'collection':'Project Gutenberg generated TXT','last_id':int(last),'total_bytes_repo':int(b),'total_files_repo':int(f),'complete':True},open(p,'w',encoding='utf-8'),indent=2)
PY
  git add "$STATE_FILE"
  git commit -m "Mark generated TXT collection complete" || true
  git push origin HEAD:main
  exit 0
fi

rsync -avR --timeout=600 --files-from=/tmp/selected.paths "$RSYNC_SOURCE" "$OUT_DIR/"
[[ -f "$INDEX_FILE" ]] || printf 'gutenberg_id\tbytes\tpath\n' > "$INDEX_FILE"

batch_bytes=0; batch_files=0; batch_no=1; current_id="$LAST_ID"
while IFS=$'\t' read -r gid size path; do
  [[ -z "${path:-}" ]] && continue
  git add "$OUT_DIR/$path"
  printf '%s\t%s\t%s\n' "$gid" "$size" "$path" >> "$INDEX_FILE"
  batch_bytes=$((batch_bytes + size)); batch_files=$((batch_files + 1)); current_id="$gid"
  if (( batch_bytes >= PUSH_BATCH_BYTES )); then
    TOTAL_BYTES=$((TOTAL_BYTES + batch_bytes)); TOTAL_FILES=$((TOTAL_FILES + batch_files))
    python3 - "$STATE_FILE" "$current_id" "$TOTAL_BYTES" "$TOTAL_FILES" <<'PY'
import json,sys
p,last,b,f=sys.argv[1:]
json.dump({'collection':'Project Gutenberg generated TXT','last_id':int(last),'total_bytes_repo':int(b),'total_files_repo':int(f),'complete':False},open(p,'w',encoding='utf-8'),indent=2)
PY
    git add "$STATE_FILE" "$INDEX_FILE"
    git commit -m "Add generated TXT batch ${batch_no} through Gutenberg ID ${current_id}"
    git push origin HEAD:main
    batch_bytes=0; batch_files=0; batch_no=$((batch_no+1))
  fi
done < /tmp/selected.tsv

if (( batch_files > 0 )); then
  TOTAL_BYTES=$((TOTAL_BYTES + batch_bytes)); TOTAL_FILES=$((TOTAL_FILES + batch_files))
  python3 - "$STATE_FILE" "$current_id" "$TOTAL_BYTES" "$TOTAL_FILES" <<'PY'
import json,sys
p,last,b,f=sys.argv[1:]
json.dump({'collection':'Project Gutenberg generated TXT','last_id':int(last),'total_bytes_repo':int(b),'total_files_repo':int(f),'complete':False},open(p,'w',encoding='utf-8'),indent=2)
PY
  git add "$STATE_FILE" "$INDEX_FILE"
  git commit -m "Add generated TXT batch ${batch_no} through Gutenberg ID ${current_id}"
  git push origin HEAD:main
fi

echo "Checkpoint Gutenberg ID: $current_id"
echo "TXT bytes in repository: $TOTAL_BYTES"
echo "TXT files in repository: $TOTAL_FILES"
