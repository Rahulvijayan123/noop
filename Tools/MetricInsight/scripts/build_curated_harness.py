"""Build Prime Agent's harness_state.json from data/curated_harness.json with Prime's own API (rlm.harness), so
the file matches the runtime's format. Run with the kernel Python (it has `rlm`):

    <kernel python> scripts/build_curated_harness.py OUT_DIR

Writes OUT_DIR/harness/harness_state.json; point NARA_CURATED_HARNESS at it. The source is checked to hold no
person-like data (UUIDs, e-mail addresses, ISO dates, numbers with health units).
"""

import json
import os
import re
import sys
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "src" / "nara_metric_insight" / "data" / "curated_harness.json"
PERSONAL = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-|@|\b\d{4}-\d{2}-\d{2}\b|\b\d+(\.\d+)?\s*(bpm|ms|%|h|min)\b", re.I)


def main(out_dir: str) -> None:
    curated = json.loads(SOURCE.read_text())
    entries = curated.get("prompt_notes", []) + curated.get("memories", [])
    for entry in entries:
        if PERSONAL.search(entry["title"] + " " + entry["content"]):
            sys.exit(f"{entry['id']}: looks like personal data; the curated harness must stay user-free")
    agent = Path(out_dir).resolve()
    agent.mkdir(parents=True, exist_ok=True)
    os.environ["PRIME_AGENT_CODING_AGENT_DIR"] = str(agent)
    import rlm  # noqa: PLC0415 - must see the agent dir set above

    for note in curated.get("prompt_notes", []):
        rlm.harness.create_prompt_note(note["title"], note["content"], id=note["id"], global_=True)
    for memory in curated.get("memories", []):
        rlm.harness.create_memory(memory["title"], memory["content"], id=memory["id"], global_=True)
    state = agent / "harness" / "harness_state.json"
    if not state.exists():
        sys.exit(f"rlm did not write {state}")
    print(state)


if __name__ == "__main__":
    main(sys.argv[1])
