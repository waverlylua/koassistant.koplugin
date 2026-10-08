#!/usr/bin/env python3
"""Build an installable queue ZIP with the upstream release exclusions.

Run from the checkout after staging newly added files:
  python3 scripts/build_question_queue_zip.py /path/queue-v3-text.zip --text-only
  python3 scripts/build_question_queue_zip.py /path/queue-v3.zip
No credentials, test fixtures, development settings, or runtime are packaged.
"""
import argparse
import pathlib
import re
import os
import datetime
import subprocess
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('output')
parser.add_argument('--text-only', action='store_true')
parser.add_argument('--version', help='Optional explicit build version (defaults to source metadata)')
args = parser.parse_args()
root = pathlib.Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip())
out = pathlib.Path(args.output).resolve()
if out.exists():
    raise FileExistsError(f'Refusing to overwrite an immutable candidate: {out}')
epoch = int(os.environ.get('SOURCE_DATE_EPOCH') or subprocess.check_output(
    ['git', 'show', '-s', '--format=%ct', 'HEAD'], cwd=root, text=True).strip())
zip_time = datetime.datetime.fromtimestamp(max(epoch, 315532800), datetime.timezone.utc).timetuple()[:6]
excluded = {'.git', '.github', '.claude', 'build', 'docs', 'tests', 'scripts', 'hooks', 'screenshots', '.gitignore'}
files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
vision_only = {'koassistant_question_region.lua', 'koassistant_question_vision.lua', 'koassistant_question_page.lua'}
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for name in files:
        if not name or name.split('/')[0] in excluded or (args.text_only and name in vision_only):
            continue
        data = (root / name).read_bytes()
        if args.text_only and name == 'main.lua':
            source, n = re.subn(r'      -- QUEUE_REGION_BEGIN\n.*?      -- QUEUE_REGION_END\n', '', data.decode(), flags=re.S)
            if n != 1:
                raise RuntimeError('Expected exactly one region-menu block')
            data = source.encode()
        if name == '_meta.lua':
            source_version = re.search(rb'version = "([^"]+)"', data).group(1).decode()
            version = args.version or (source_version + '-text' if args.text_only else source_version)
            data = re.sub(rb'version = "[^"]+"', ('version = "'+version+'"').encode(), data)
        info = zipfile.ZipInfo('koassistant.koplugin/' + name, zip_time)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        z.writestr(info, data)
print(out)
