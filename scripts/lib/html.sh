#!/bin/bash
# HTML report helpers for the phase scripts. Sourced, not executed.

# Args: file_path title
# Writes an HTML fragment (no <html>/<head>/<body> wrapper).
# CSS is provided by generate_index.py when building the merged index.html.
html_init() {
  local file="$1"
  local title="$2"
  {
    echo "    <h2>$title</h2>"
    echo "    <p><strong>Generated:</strong> $(date '+%Y-%m-%d %H:%M:%S')</p>"
  } >"$file"
}

# Args: file_path
html_close() {
  local file="$1"
  : # fragment needs no closing wrapper
}
