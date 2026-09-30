#!/bin/sh
# Generate the html documentation in docs/ (served by GitHub Pages) with scod, the same skin
# as serverino and parserino, with the declarations (Connection, Query, Result, ...) in the
# menu on the left.
# docs/llms.txt, docs/llms-full.txt and docs/AGENTS.md are written by hand; docs/SKILL.md is
# generated from AGENTS.md.
# Usage: tools/docs.sh
set -e
cd "$(dirname "$0")/.."

dub build -q -b ddox
dub run -q scod -- generate-html --navigation-type=DeclarationTree \
    --sitemap-url=https://trikko.github.io/jape/ docs.json docs
rm -f docs.json __dummy.html

# SKILL.md is AGENTS.md with the front matter that makes it an installable skill
{
    printf -- '---\nname: jape\n'
    printf 'description: Official reference for jape, the PostgreSQL client for the D programming language (a libpq wrapper via ImportC: bound parameters, ranges, streaming, prepared statements, transactions, COPY, exact numeric). Use it whenever the user asks about jape, or about using Postgres from D.\n'
    printf -- '---\n\n'
    cat docs/AGENTS.md
} > docs/SKILL.md
echo "docs/ updated"
