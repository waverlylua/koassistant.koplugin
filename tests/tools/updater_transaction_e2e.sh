#!/bin/sh
# Exercise this working tree's real performUpdate with KOReader's archive,
# filesystem and process code. No network, credentials, git mutation or GUI.
# KOREADER_DIR must contain setupkoenv.lua and ./luajit. Python 3 builds fresh
# fixtures from tracked working-tree files, including uncommitted edits and
# newly staged files. Untracked local credentials are never copied.
# KEEP=1 retains logs.
# Optional arguments select individual cases (see the list below).
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
KO=${KOREADER_DIR:-/Applications/KOReader.app/Contents/koreader}
[ -x "$KO/luajit" ] && [ -f "$KO/setupkoenv.lua" ] || {
    echo "Set KOREADER_DIR to a KOReader runtime with luajit and setupkoenv.lua" >&2
    exit 2
}
work=$(mktemp -d "${TMPDIR:-/tmp}/koa_transaction.XXXXXX")
cleanup() {
    if [ "${KEEP:-}" = 1 ]; then echo "Fixtures and logs: $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

python3 - "$root" "$work" <<'PY'
import os, pathlib, re, shutil, stat, subprocess, sys, warnings, zipfile

root, work = map(pathlib.Path, sys.argv[1:])
excluded = {".git", ".github", ".agents", ".codex", ".claude", "build", "docs",
            "tests", "scripts", "hooks", "screenshots", ".gitignore"}
installed = work / "installed"
installed.mkdir()
paths = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z"]).split(b"\0")
for raw in paths:
    if not raw:
        continue
    relative = pathlib.Path(os.fsdecode(raw))
    if relative.parts[0] in excluded:
        continue
    path = root / relative
    if not path.is_file():
        continue  # reflect tracked deletions in the working tree
    target = installed / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, target)
release = work / "release"
shutil.copytree(installed, release)
meta = release / "_meta.lua"
old = re.search(r'version\s*=\s*"([^"]+)"', meta.read_text()).group(1)
major, minor, patch = map(int, re.match(r"(\d+)\.(\d+)\.(\d+)", old).groups())
version = f"{major}.{minor}.{patch + 1}"
meta.write_text(re.sub(r'version\s*=\s*"[^"]+"', f'version = "{version}"', meta.read_text()))
(release / "transaction_release_marker.txt").write_text("new release fixture\n")
(work / "version").write_text(version)

def archive(name, variant=None):
    with zipfile.ZipFile(work / (name + ".zip"), "w", zipfile.ZIP_DEFLATED) as z:
        top = "wrong.koplugin" if variant == "wrong_root" else "koassistant.koplugin"
        z.writestr(top + "/", b"")
        for path in sorted(release.rglob("*")):
            rel = path.relative_to(release).as_posix()
            if variant == "missing_module" and rel == "koassistant_release_channel.lua":
                continue
            dest = top + "/" + rel
            if variant == "metadata_execution" and rel == "_meta.lua":
                z.writestr(dest, b"_G.KOA_TEST_UNTRUSTED_META_EXECUTED = true\n" + path.read_bytes())
            else:
                z.write(path, dest)
        if variant == "traversal":
            z.writestr(top + "/../escaped.txt", b"must not escape staging")
        elif variant == "symlink":
            link = zipfile.ZipInfo(top + "/unsafe-link")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(link, "../../outside")
        elif variant == "duplicate":
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                z.writestr(top + "/transaction_release_marker.txt", b"duplicate")

archive("good")
for variant in ("wrong_root", "traversal", "symlink", "duplicate", "missing_module", "metadata_execution"):
    archive(variant, variant)
(work / "garbage.zip").write_bytes(b"This is not a ZIP archive.\n")
PY

if [ "$#" = 0 ]; then
    set -- success linked_domains backup_collisions backup_full download_failure \
        repeated_update later_dismissal queued_guard running_guard streaming_guard \
        active_during_download queue_pending_lock bad_size bad_digest garbage \
        wrong_version wrong_root traversal symlink duplicate missing_module \
        metadata_execution preserve_missing preserve_same_size restore_same_size \
        move_old_failure move_new_failure rollback_failure git_worktree offline no_url
fi

pass=0
fail=0
for case_name in "$@"; do
    mkdir -p "$work/$case_name/plugins" "$work/$case_name/settings" "$work/$case_name/data"
    cp -R "$work/installed" "$work/$case_name/plugins/koassistant.koplugin"
    if (cd "$KO" && ./luajit "$root/tests/tools/updater_transaction_e2e.lua" \
            "$work" "$case_name" "$(cat "$work/version")") > "$work/$case_name/out.txt" 2>&1; then
        pass=$((pass + 1))
        grep '^PASS ' "$work/$case_name/out.txt"
    else
        fail=$((fail + 1))
        echo "FAIL $case_name"
        tail -15 "$work/$case_name/out.txt" | sed 's/^/  /'
    fi
done
echo "$pass passed, $fail failed (real KOReader archive and filesystem)"
[ "$fail" -eq 0 ]
