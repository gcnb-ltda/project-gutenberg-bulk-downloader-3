#!/usr/bin/env bash
set -euo pipefail

# Project Gutenberg canonical TXT mirror importer - Part 3
# Source of truth: validated txt-files.tar.zip split across repositories 1 and 2.

RUN_TARGET_MIB="${RUN_TARGET_MIB:-2000}"
REPO_TARGET_GIB="${REPO_TARGET_GIB:-8}"
MAX_FILE_MIB="${MAX_FILE_MIB:-90}"
PUSH_BATCH_MIB="${PUSH_BATCH_MIB:-180}"
STATE_FILE="${STATE_FILE:-txt-continuation-state.json}"
INDEX_FILE="${INDEX_FILE:-txt-index.tsv}"
OUT_DIR="${OUT_DIR:-books_txt}"
EXPECTED_ZIP_SIZE="11278856242"
EXPECTED_ZIP_SHA256="504191cf3ecfb111da66416952682a5fd23959f9fcea20066a81a7ca9a9fdb94"
COLLECTION="Project Gutenberg master archive canonical TXT"

for c in curl unzip python3 git sha256sum; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 1; }
done

WORK="${RUNNER_TEMP:-/tmp}/gutenberg-master-mirror-${GITHUB_RUN_ID:-$$}"
MASTER_ZIP="$WORK/txt-files.tar.zip"
MASTER_TAR="$WORK/txt-files.tar"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# Reconstruct the exact validated ZIP from repositories 1 and 2.
: > "$MASTER_ZIP"
download_part() {
  local repo="$1" n="$2" expected="$3" part url actual
  part=$(printf 'pg-all-text-%05d.part' "$n")
  url="https://raw.githubusercontent.com/gcnb-ltda/${repo}/main/archive_parts/${part}"
  echo "Downloading ${part} from ${repo}"
  rm -f "$WORK/part.tmp"
  curl -L --fail --retry 8 --retry-delay 3 --connect-timeout 30 --max-time 900 \
    -A 'GCNB-Gutenberg-Mirror/3.0' "$url" -o "$WORK/part.tmp"
  actual=$(stat -c %s "$WORK/part.tmp")
  if [ "$actual" -ne "$expected" ]; then
    echo "ERROR: ${part} size ${actual}, expected ${expected}" >&2
    exit 1
  fi
  cat "$WORK/part.tmp" >> "$MASTER_ZIP"
  rm -f "$WORK/part.tmp"
}

for n in $(seq 1 91); do
  download_part project-gutenberg-bulk-downloader "$n" 94371840
done
for n in $(seq 92 119); do
  download_part project-gutenberg-bulk-downloader-2 "$n" 94371840
done
download_part project-gutenberg-bulk-downloader-2 120 48607282

actual_size=$(stat -c %s "$MASTER_ZIP")
if [ "$actual_size" -ne "$EXPECTED_ZIP_SIZE" ]; then
  echo "ERROR: reconstructed ZIP size $actual_size, expected $EXPECTED_ZIP_SIZE" >&2
  exit 1
fi
actual_sha=$(sha256sum "$MASTER_ZIP" | awk '{print $1}')
if [ "$actual_sha" != "$EXPECTED_ZIP_SHA256" ]; then
  echo "ERROR: reconstructed ZIP SHA256 $actual_sha, expected $EXPECTED_ZIP_SHA256" >&2
  exit 1
fi

echo "Validated master ZIP: ${actual_size} bytes, SHA256 ${actual_sha}"
unzip -tqq "$MASTER_ZIP"

member=$(unzip -Z1 "$MASTER_ZIP" | head -1)
member_count=$(unzip -Z1 "$MASTER_ZIP" | wc -l)
if [ "$member_count" -ne 1 ] || [ "$member" != "txt-files.tar" ]; then
  echo "ERROR: expected one ZIP member named txt-files.tar; got count=$member_count member=$member" >&2
  exit 1
fi

echo "Materializing inner TAR for indexed canonical extraction..."
unzip -p "$MASTER_ZIP" txt-files.tar > "$MASTER_TAR"
rm -f "$MASTER_ZIP"

python3 - "$MASTER_TAR" "$STATE_FILE" "$INDEX_FILE" "$OUT_DIR" "$RUN_TARGET_MIB" "$REPO_TARGET_GIB" "$MAX_FILE_MIB" "$PUSH_BATCH_MIB" "$COLLECTION" <<'PY'
import hashlib, json, os, re, shutil, subprocess, sys, tarfile, time

(master_tar,state_file,index_file,out_dir,run_target_mib,repo_target_gib,
 max_file_mib,push_batch_mib,collection)=sys.argv[1:]
run_target=int(run_target_mib)*1024*1024
repo_target=int(repo_target_gib)*1024*1024*1024
max_file=int(max_file_mib)*1024*1024
push_batch=int(push_batch_mib)*1024*1024

try:
    state=json.load(open(state_file,encoding='utf-8'))
except Exception:
    state={}

migration=state.get('collection') != collection
if migration:
    print('Old/contaminated mirror state detected. Resetting books_txt and index before canonical rebuild.', flush=True)
    shutil.rmtree(out_dir,ignore_errors=True)
    os.makedirs(out_dir,exist_ok=True)
    with open(index_file,'w',encoding='utf-8') as f:
        f.write('gutenberg_id\tbytes\tsha256\tsource_member\trepo_path\n')
    last_id=0
    total_bytes=0
    total_files=0
else:
    os.makedirs(out_dir,exist_ok=True)
    last_id=int(state.get('last_id',0))
    total_bytes=0
    total_files=0
    for name in os.listdir(out_dir):
        if not re.fullmatch(r'\d+\.txt',name):
            continue
        p=os.path.join(out_dir,name)
        if os.path.isfile(p):
            total_files+=1
            total_bytes+=os.path.getsize(p)
    if not os.path.exists(index_file):
        with open(index_file,'w',encoding='utf-8') as f:
            f.write('gutenberg_id\tbytes\tsha256\tsource_member\trepo_path\n')

if total_bytes >= repo_target:
    print(f'Repository target already reached: {total_bytes} bytes / {total_files} files')
    raise SystemExit(0)

print('Indexing canonical TXT members from validated master TAR...', flush=True)
books={}
with tarfile.open(master_tar,'r:') as tf:
    for m in tf:
        if not m.isfile() or m.size<=0 or m.size>max_file:
            continue
        base=os.path.basename(m.name)
        mo=re.fullmatch(r'(\d+)(?:-(\d+))?\.txt',base,re.I)
        if not mo:
            continue
        gid=int(mo.group(1))
        suffix=mo.group(2)
        if suffix == '0':
            rank=(0,0)
        elif suffix is None:
            rank=(1,0)
        else:
            rank=(2,int(suffix))
        key=(rank,len(m.name),m.name)
        prev=books.get(gid)
        if prev is None or key < prev[0]:
            books[gid]=(key,m.name,m.size)

ids=sorted(books)
if not ids:
    raise RuntimeError('No canonical numeric TXT members found in master archive')
max_id=ids[-1]
print(f'Canonical IDs discovered: {len(ids)}; range {ids[0]}..{max_id}; continuing after {last_id}',flush=True)

remaining_repo=repo_target-total_bytes
run_limit=min(run_target,remaining_repo)
selected=[]
selected_bytes=0
for gid in ids:
    if gid<=last_id:
        continue
    _,member,size=books[gid]
    if selected and selected_bytes+size>run_limit:
        break
    if size>run_limit and not selected:
        # A single canonical file may exceed the remaining run budget but still fit repo.
        if size<=remaining_repo:
            selected.append((gid,member,size)); selected_bytes+=size
        break
    selected.append((gid,member,size)); selected_bytes+=size

if not selected:
    complete=last_id>=max_id
    state={
      'collection':collection,
      'source_archive_sha256':'504191cf3ecfb111da66416952682a5fd23959f9fcea20066a81a7ca9a9fdb94',
      'last_id':last_id,'total_bytes_repo':total_bytes,'total_files_repo':total_files,
      'max_canonical_id':max_id,'complete':complete,'repository_full':total_bytes>=repo_target
    }
    json.dump(state,open(state_file,'w',encoding='utf-8'),indent=2)
    subprocess.run(['git','add','-A',state_file,index_file,out_dir],check=True)
    if subprocess.run(['git','diff','--cached','--quiet']).returncode!=0:
        subprocess.run(['git','commit','-m','Update canonical Gutenberg mirror state'],check=True)
        subprocess.run(['git','push','origin','HEAD:main'],check=True)
    print('No additional canonical books selected.',flush=True)
    raise SystemExit(0)

print(f'Selected {len(selected)} canonical books / {selected_bytes} bytes for this run',flush=True)

current_id=last_id
batch_bytes=0
batch_files=0
run_bytes=0
run_files=0


def write_state(complete=False):
    obj={
      'collection':collection,
      'source_archive_sha256':'504191cf3ecfb111da66416952682a5fd23959f9fcea20066a81a7ca9a9fdb94',
      'last_id':int(current_id),
      'total_bytes_repo':int(total_bytes),
      'total_files_repo':int(total_files),
      'max_canonical_id':int(max_id),
      'complete':bool(complete),
      'repository_full':bool(total_bytes>=repo_target)
    }
    with open(state_file,'w',encoding='utf-8') as f:
        json.dump(obj,f,indent=2)


def push_checkpoint(message):
    subprocess.run(['git','add','-A',state_file,index_file,out_dir],check=True)
    if subprocess.run(['git','diff','--cached','--quiet']).returncode==0:
        return
    subprocess.run(['git','commit','-m',message],check=True)
    for attempt in range(1,6):
        if subprocess.run(['git','push','origin','HEAD:main']).returncode==0:
            return
        print(f'Push rejected; synchronizing with origin/main ({attempt}/5)',flush=True)
        subprocess.run(['git','fetch','origin','main'],check=True)
        rb=subprocess.run(['git','rebase','origin/main'])
        if rb.returncode!=0:
            subprocess.run(['git','rebase','--abort'],check=False)
            raise RuntimeError('Automatic rebase failed; conflict review required')
        time.sleep(2*attempt)
    raise RuntimeError('Unable to push canonical mirror checkpoint after 5 attempts')

# Reopen the uncompressed TAR. tarfile can seek directly to previously indexed members.
with tarfile.open(master_tar,'r:') as tf:
    for gid,member,size in selected:
        dst=os.path.join(out_dir,f'{gid}.txt')
        src=tf.extractfile(member)
        if src is None:
            raise RuntimeError(f'Unable to extract {member}')
        h=hashlib.sha256()
        written=0
        with open(dst,'wb') as f:
            while True:
                chunk=src.read(1024*1024)
                if not chunk:
                    break
                f.write(chunk); h.update(chunk); written+=len(chunk)
        if written!=size:
            raise RuntimeError(f'Size mismatch extracting {member}: {written} != {size}')
        with open(index_file,'a',encoding='utf-8') as f:
            f.write(f'{gid}\t{written}\t{h.hexdigest()}\t{member}\t{dst}\n')
        current_id=gid
        total_bytes+=written; total_files+=1
        run_bytes+=written; run_files+=1
        batch_bytes+=written; batch_files+=1

        if batch_bytes>=push_batch:
            write_state(False)
            push_checkpoint(f'Canonical Gutenberg TXT through ID {current_id}')
            print(f'Checkpoint: ID {current_id}; repo={total_bytes} bytes/{total_files} files; run={run_bytes} bytes',flush=True)
            batch_bytes=0; batch_files=0

complete=current_id>=max_id and total_bytes<repo_target
write_state(complete)
push_checkpoint(('Complete' if complete else 'Checkpoint')+f' canonical Gutenberg TXT through ID {current_id}')
print(f'Run complete: added={run_files} files/{run_bytes} bytes; repo={total_files} files/{total_bytes} bytes; last_id={current_id}; complete={complete}',flush=True)
PY
