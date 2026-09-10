#!/usr/bin/env bash
set -euo pipefail

# Importador de TXT individuais da coleção PRINCIPAL do Project Gutenberg.
# Prioriza UTF-8 (-0.txt), depois o TXT simples, e mantém 1 TXT por eBook.

RSYNC_SOURCE="${RSYNC_SOURCE:-gutenberg.pglaf.org::gutenberg}"
RUN_TARGET_MIB="${RUN_TARGET_MIB:-2500}"
REPO_TARGET_GIB="${REPO_TARGET_GIB:-8}"
MAX_FILE_MIB="${MAX_FILE_MIB:-90}"
PUSH_BATCH_MIB="${PUSH_BATCH_MIB:-400}"
STATE_FILE="${STATE_FILE:-txt-continuation-state.json}"
INDEX_FILE="${INDEX_FILE:-txt-index.tsv}"
OUT_DIR="${OUT_DIR:-books_txt}"

RUN_TARGET_BYTES=$((RUN_TARGET_MIB * 1024 * 1024))
REPO_TARGET_BYTES=$((REPO_TARGET_GIB * 1024 * 1024 * 1024))
MAX_FILE_BYTES=$((MAX_FILE_MIB * 1024 * 1024))
PUSH_BATCH_BYTES=$((PUSH_BATCH_MIB * 1024 * 1024))

for c in rsync python3 git; do
  command -v "$c" >/dev/null 2>&1 || { echo "$c is required"; exit 1; }
done
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

echo "Listing Project Gutenberg MAIN collection from $RSYNC_SOURCE ..."
rsync -r --list-only --timeout=600 "$RSYNC_SOURCE" > /tmp/gutenberg-main-list.txt

python3 - "$LAST_ID" "$RUN_TARGET_BYTES" "$MAX_FILE_BYTES" <<'PY'
import re,sys,os
last_id=int(sys.argv[1]); target=int(sys.argv[2]); max_file=int(sys.argv[3])

# One preferred TXT per eBook ID. Main collection structure ends in .../<ID>/<file>.
books={}
for line in open('/tmp/gutenberg-main-list.txt',encoding='utf-8',errors='replace'):
    parts=line.split()
    if len(parts)<5:
        continue
    try:
        size=int(parts[1])
    except ValueError:
        continue
    path=parts[-1].lstrip('./')
    if not path.lower().endswith('.txt'):
        continue
    seg=path.split('/')
    if len(seg)<2 or not seg[-2].isdigit():
        continue
    gid=int(seg[-2])
    if gid<=last_id or size<=0 or size>max_file:
        continue
    name=seg[-1].lower()
    # Prefer UTF-8 files named ID-0.txt, then ID.txt, then any other .txt.
    if name == f'{gid}-0.txt': rank=0
    elif name == f'{gid}.txt': rank=1
    elif name.startswith(f'{gid}-') and name.endswith('.txt'): rank=2
    else: rank=3
    prev=books.get(gid)
    cand=(rank,size,path)
    if prev is None or cand < prev:
        books[gid]=cand

selected=[]; total=0
for gid in sorted(books):
    rank,size,path=books[gid]
    if selected and total+size>target:
        break
    selected.append((gid,size,path)); total+=size

with open('/tmp/selected.tsv','w',encoding='utf-8') as f:
    for gid,size,path in selected:
        f.write(f'{gid}\t{size}\t{path}\n')
with open('/tmp/selected.paths','w',encoding='utf-8') as f:
    for _,_,path in selected:
        f.write(path+'\n')
print(f'selected={len(selected)} bytes={total} last_id={selected[-1][0] if selected else last_id}')
PY

if [[ ! -s /tmp/selected.paths ]]; then
  python3 - "$STATE_FILE" "$LAST_ID" "$TOTAL_BYTES" "$TOTAL_FILES" <<'PY'
import json,sys
p,last,b,f=sys.argv[1:]
json.dump({'collection':'Project Gutenberg main TXT','last_id':int(last),'total_bytes_repo':int(b),'total_files_repo':int(f),'complete':True},open(p,'w',encoding='utf-8'),indent=2)
PY
  git add "$STATE_FILE"
  git commit -m "Mark main TXT collection complete" || true
  git push origin HEAD:main
  exit 0
fi

# Preserve source hierarchy during transfer to avoid collisions.
rsync -avR --timeout=600 --files-from=/tmp/selected.paths "$RSYNC_SOURCE" /tmp/pg-main/
[[ -f "$INDEX_FILE" ]] || printf 'gutenberg_id\tbytes\tsource_path\trepo_path\n' > "$INDEX_FILE"

batch_bytes=0; batch_files=0; batch_no=1; current_id="$LAST_ID"
while IFS=$'\t' read -r gid size path; do
  [[ -z "${path:-}" ]] && continue
  src="/tmp/pg-main/$path"
  dst="$OUT_DIR/$gid.txt"
  cp "$src" "$dst"
  git add "$dst"
  printf '%s\t%s\t%s\t%s\n' "$gid" "$size" "$path" "$dst" >> "$INDEX_FILE"
  batch_bytes=$((batch_bytes + size)); batch_files=$((batch_files + 1)); current_id="$gid"

  if (( batch_bytes >= PUSH_BATCH_BYTES )); then
    TOTAL_BYTES=$((TOTAL_BYTES + batch_bytes)); TOTAL_FILES=$((TOTAL_FILES + batch_files))
    python3 - "$STATE_FILE" "$current_id" "$TOTAL_BYTES" "$TOTAL_FILES" <<'PY'
import json,sys
p,last,b,f=sys.argv[1:]
json.dump({'collection':'Project Gutenberg main TXT','last_id':int(last),'total_bytes_repo':int(b),'total_files_repo':int(f),'complete':False},open(p,'w',encoding='utf-8'),indent=2)
PY
    git add "$STATE_FILE" "$INDEX_FILE"
    git commit -m "Add Project Gutenberg TXT batch ${batch_no} through ID ${current_id}"
    git push origin HEAD:main
    batch_bytes=0; batch_files=0; batch_no=$((batch_no+1))
  fi
done < /tmp/selected.tsv

if (( batch_files > 0 )); then
  TOTAL_BYTES=$((TOTAL_BYTES + batch_bytes)); TOTAL_FILES=$((TOTAL_FILES + batch_files))
  python3 - "$STATE_FILE" "$current_id" "$TOTAL_BYTES" "$TOTAL_FILES" <<'PY'
import json,sys
p,last,b,f=sys.argv[1:]
json.dump({'collection':'Project Gutenberg main TXT','last_id':int(last),'total_bytes_repo':int(b),'total_files_repo':int(f),'complete':False},open(p,'w',encoding='utf-8'),indent=2)
PY
  git add "$STATE_FILE" "$INDEX_FILE"
  git commit -m "Add Project Gutenberg TXT batch ${batch_no} through ID ${current_id}"
  git push origin HEAD:main
fi

echo "Checkpoint Gutenberg ID: $current_id"
echo "TXT bytes in repository: $TOTAL_BYTES"
echo "TXT files in repository: $TOTAL_FILES"
