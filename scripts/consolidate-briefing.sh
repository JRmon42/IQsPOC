#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# consolidate-briefing.sh
#
# The customer briefing is regenerated in full on each revision, but Word holds
# an exclusive lock on the .docx while it is open, so the new version is written
# to a "-v5" sibling instead of overwriting the canonical file.
#
# Run this once Word is closed to collapse the two files back into one. It
# refuses to act while the lock is still present rather than half-completing.
# ---------------------------------------------------------------------------
set -euo pipefail

DIR="/mnt/c/Users/jpontvianne/Documents/Azure/ST/IQs"
CANON="${DIR}/Foundry-Work-Web-IQ-Security-Briefing.docx"
NEW="${DIR}/Foundry-Work-Web-IQ-Security-Briefing-v5.docx"

[[ -f "$NEW" ]] || { echo "nothing to consolidate: ${NEW##*/} not found"; exit 0; }

# Word writes a ~$ owner file next to any open document.
if compgen -G "${DIR}/~\$*Security-Briefing.docx" > /dev/null; then
  echo "Word still has the briefing open (a ~\$ lock file is present)."
  echo "Close the document in Word, then run this script again."
  exit 1
fi

cp "$CANON" "${DIR}/.briefing-previous.docx" 2>/dev/null || true

if cp "$NEW" "$CANON" 2>/dev/null; then
  rm -f "$NEW"
  echo "consolidated into ${CANON##*/}"
  echo "previous version kept as .briefing-previous.docx"
  python3 - "$CANON" <<'PY'
import sys
from docx import Document
d = Document(sys.argv[1])
imgs = [r for r in d.part.rels.values() if "image" in r.reltype]
print(f"  {len(d.paragraphs)} paragraphs, {len(d.tables)} tables, {len(imgs)} images")
for p in d.paragraphs:
    if p.style.name == "Heading 1":
        print("   " + p.text[:78])
PY
else
  echo "still locked - close Word and retry"
  exit 1
fi
