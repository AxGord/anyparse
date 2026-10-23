# Mermaid flowchart corpus

The round-trip corpus of the Mermaid flowchart grammar (`src/anyparse/grammar/mermaid`), read by
`unit.grammar.MermaidRoundTripTest`. Every file must parse, write back to text that parses to the
same AST, and write idempotently.

- `docs/` — every flowchart example of the Mermaid flowchart documentation
  (`packages/mermaid/src/docs/syntax/flowchart.md`), one block per file, in document order.
- `spec/` — the flowchart sources the Mermaid parser specs feed their parser
  (`packages/mermaid/src/diagrams/flowchart/parser/*.spec.js`), excluding the sources a spec expects
  to be rejected, the ones built by string interpolation, and one the grammar does not support (a
  node id ending in `-` directly before an asymmetric shape, `odd->text]`). The file name is the
  spec file and the source's ordinal in it.
- `demo/` — diagrams written for this repository in the shapes code diagrams use (a package map
  with subgraphs, classes and link styles; a diff with dotted and invisible links; a decision flow
  with stadiums, diamonds and escaped labels). They are in canonical form: writing one gives back
  its own bytes.

`docs/` and `spec/` are taken from [mermaid-js/mermaid](https://github.com/mermaid-js/mermaid) at
commit `6d8921f94f9a12b76586eddcf45a566080d4767e`, under its MIT license:

```
The MIT License (MIT)

Copyright (c) 2014 - 2022 Knut Sveidqvist

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
