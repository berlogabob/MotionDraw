// MotionDraw documentation. Body is generated from README.md by
// tools/readme_pdf.sh — edit README.md, not readme-body.typ.
#set page(paper: "a4", margin: (x: 22mm, y: 24mm), numbering: "1")
#set text(font: "IBM Plex Mono", size: 9.5pt, fill: black)
#set par(justify: false, leading: 0.7em)
#set heading(numbering: none)
#show heading.where(level: 1): it => block(above: 0pt, below: 18pt, text(size: 18pt, tracking: 0.08em, upper(it.body)))
#show heading.where(level: 2): it => block(above: 22pt, below: 10pt, text(size: 11pt, tracking: 0.12em, upper(it.body)))
#show raw.where(block: true): it => block(width: 100%, inset: 8pt, stroke: 0.5pt + black, text(size: 8.5pt, it))
#show raw.where(block: false): it => text(size: 8.5pt, it)
#show link: it => underline(it)
#show figure: set align(left)
#show table: it => block(stroke: none, it)
#set table(align: left + top, stroke: (x, y) => if y == 0 { (bottom: 0.5pt + black) } else { none }, inset: (x: 6pt, y: 5pt))
#show table.cell.where(y: 0): it => text(tracking: 0.08em, upper(it))

#include "readme-body.typ"
