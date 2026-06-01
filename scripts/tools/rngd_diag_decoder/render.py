"""HTML rendering, terminal logger, and ANSI color constants."""

import collections
import sys
from datetime import datetime
from typing import IO

GREEN = "\033[92m"
RED   = "\033[91m"
RESET = "\033[0m"
BOLD  = "\033[1m"


def strip_ansi(text: str) -> str:
    """Remove ANSI color escape sequences from `text`."""
    return text.replace(GREEN, "").replace(RED, "").replace(RESET, "").replace(BOLD, "")


class Logger:
    """Tees stdout to a file, stripping ANSI codes from the file copy."""

    def __init__(self, filename: str) -> None:
        """Open `filename` (UTF-8) as the file copy target.

        Args:
            filename: Path to the file that receives ANSI-stripped output.
        """
        self.terminal: IO[str] = sys.stdout
        # SIM115 (use a context manager) -- the file is held open for the lifetime
        # of this Logger instance, so a `with` block isn't applicable.
        self.log: IO[str] = open(filename, "w", encoding="utf-8")  # noqa: SIM115

    def write(self, message: str) -> None:
        """Write `message` to stdout and the file copy (ANSI-stripped)."""
        self.terminal.write(message)
        self.log.write(strip_ansi(message))

    def flush(self) -> None:
        """Flush both stdout and the file copy."""
        self.terminal.flush()
        self.log.flush()


def generate_html_report(all_results: list[tuple[str, str, str]], filename: str) -> None:
    """Render the per-NPU PASS/FAIL HTML fragment to `filename`.

    Writes a fragment (no <html>/<head>/<body> wrapper) so that
    generate_index.py can embed it directly inside index.html.
    """
    npu_groups: dict[str, list[tuple[str, str]]] = collections.defaultdict(list)
    for npu_id, item, res_text in all_results:
        npu_groups[npu_id].append((item, res_text))

    generated = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    html = "    <h2>Furiosa HW Component Health Check Report</h2>\n"
    html += f"    <p><strong>Generated:</strong> {generated}</p>\n"

    for npu_id in sorted(npu_groups.keys()):
        html += f"""    <div class="npu-section">
        <div class="npu-title">{npu_id.upper()} Status</div>
        <table>
            <thead><tr><th>ITEM</th><th>RESULT</th></tr></thead>
            <tbody>
"""
        for item, res_text in npu_groups[npu_id]:
            res_class = "pass" if "PASS" in res_text else "fail"
            html += (
                f"            <tr><td>{item}</td>"
                f'<td class="{res_class}">{strip_ansi(res_text)}</td></tr>\n'
            )
        html += "            </tbody>\n        </table>\n    </div>\n"

    with open(filename, "w", encoding="utf-8") as f:
        f.write(html)
