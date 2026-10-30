# `docs` rules

Comments and doc comments. One section per rule, by id; each rule's language, default and fix marker are in the [rule index](../../lint-rules.md#docs), and a suite test fails when a registered rule has no section here or a section names no rule of this category.

## `comment-width`

A comment line — a `//` run, a `/* … */` banner or a `/** … */` doc block — that renders wider
than the project's own `wrapping.maxLineLength` (from `hxformat.json`). The writer owns every code
line's width but re-emits a comment's interior byte for byte, so an over-wide comment leaves
`fmt --list` clean and nothing else ever measures it. `Info`, DEFAULT OFF: the width is a project's
style choice; opt in with `"comment-width": { "enabled": true }`.

A line counts only when the COMMENT is what puts it over: a trailing comment on a line whose code is
already too long is the formatter's business, not this rule's. `--fix` breaks the line at spaces into
the same comment block, carrying the prefix (`//`, ` * `) that position needs. It leaves the line
alone, saying why in the finding, when wrapping could change meaning or has no room: a suppression
directive, a table row, a heading or list item, hand-indented text, a fenced code block, a comment
trailing code, a raw `#if` region, or a line with no space inside the width (a long URL).

```haxe
// A long explanation that runs well past the configured width of this project and keeps going
// --fix:
// A long explanation that runs well past the configured width of this
// project and keeps going
```

## `doc-comment-continuation`

An interior line of a block comment that breaks the continuation prefix its own block uses. A
star-guttered block is judged against its gutter: a line that lost its ` * `, or carries it at an
indent the rest of the block does not use. A gutter-less block is judged against its indentation.
`Warning`.

Comments are trivia: the writer re-emits their interior byte for byte and no node-based rule sees
them, so a doc block mangled by a text splice stays committed with every other gate clean. Only a
block whose lines DISAGREE is reported — a block whose every line uses one prefix is a house style
whatever indent it chose, and a markdown bullet (`*emphasis*`, `**bold**`) is not mistaken for a
gutter. `--fix` rewrites each flagged line onto the block's majority prefix and keeps its content
byte for byte, including any indentation beyond the prefix, so a code sample inside a doc survives.

```haxe
/**
 * Returns the parsed value.
Throws when the input is empty.   // reported: lost its gutter
 */
```

## `doc-coverage`

A public API declaration that carries no doc comment: a top-level type that is not `private`,
and — when `requireMemberDoc` is on — a `public` member of one (interface members, and members of an
extern or `@:publicFields` type, count as public). The public surface is what other modules compile
against, so an undocumented one is a gap no intra-body rule sees. `Info`, report-only: writing the doc
is an authoring decision.

Only a `/**` block directly above the declaration, or above its modifier and metadata run, counts; a
`//` line or a plain `/*` block does not. Enum constructors and typedef fields are documented by
their type's doc. Options: `requireTypeDoc` (default `true`), `requireMemberDoc` (default
`false`), `includeConstructor` (default `false` — the type doc covers construction).

```haxe
class Parser {}               // reported: no doc
/** Reads one record. */
class Reader {}               // documented
```

## `doc-length`

A doc block (`/** … */`) longer than the project's maximum. A doc states what a reader may rely
on, in a sentence or three; past that it has become a document — a rationale belongs in `docs/` and a
history in the commit that made it, and neither survives the next edit of the code it sits above.
`Info`, DEFAULT OFF and report-only: which sentences are the contract is the whole of the work.

Opt in and set the limit with `"doc-length": { "enabled": true, "max": N }` (lines, default `40`).
`//` runs and plain `/* */` banners are not measured: they belong to the statements they stand
over, not to a declaration's contract.

## `doc-measurement-claim`

A comment carrying a READING of the tree rather than a contract: a duration, a percentage, an
abbreviated commit hash, a ticket or slice id, a census count ("12 call sites"), a before-and-after
pair, or a sentence pinning its claim to the repository's current state. A reading describes one tree
at one moment and goes stale while the code it sits in lives on; the commit message keeps the
numbers, the comment keeps the conclusion. `Info`, DEFAULT OFF and report-only: what the surviving
sentence says is a judgement.

A bare number is never a finding — a doc naming the code's own constant (a minimum count, a language
version) is a contract. References are not readings either: a hash inside a path or URL, a doc tag
pointing at one, `%` as the remainder operator, and anything inside a string literal stay silent.

```haxe
// Batched since the rewrite: 14.6s -> 0.4s on this repo.   // reported
// Batched so one compile answers every file.                // fine
```

## `empty-comment`

a content-free comment — a `//` with only whitespace after the slashes, an empty `/* */`, or an empty doc comment (including a multi-line one whose interior is only stars and whitespace); `Warning`, `--fix` deletes it (the whole physical line(s) when the comment is alone on them, the comment plus the whitespace before it when it trails code, the comment alone when code follows it on the same line). A pure comment-token scan (`RefactorSupport.collectCommentTokens`, string-aware — a slash-slash inside a STRING literal is never visited), so no parse is needed and a conditional-compilation line, which is not a comment, never matches. Content keeps a comment, which is what leaves a dashed divider run and a `// noqa` directive alone. **The PARAGRAPH SEPARATOR is kept too**: a bare `//` on its own line with a comment-only line directly above and another directly below is the blank line of a `//` prose block — content-free by every character test, but deleting it MERGES two paragraphs, a change to what the comment says rather than a cleanup. The gate is positive and purely lexical (this token and BOTH comment-stream neighbours are line comments, each alone on its line, on three consecutive lines), so an unlisted shape fails by construction: a bare `//` at the head or tail of a run is padding and still reports, as does one whose neighbour shares its line with code, sits a blank line away (the blank already separates), or is a block comment (a block carries its paragraph breaks inside itself). WITHOUT that gate every finding the rule produced on this repository was a paragraph separator, and an unguarded `--fix` would have silently reflowed every such prose block. A pure trivia edit: comments never affect compilation

## `empty-doc-tag`

a javadoc/haxedoc tag with no description inside a CLOSED `/** */` doc comment — content the doc extractor renders as an empty row; `Warning`, `--fix` deletes the tag's line(s), or the whole comment when nothing but gutter would survive. A pure comment-token scan (`RefactorSupport.collectCommentTokens`, string-aware; plain `/* */` blocks and unclosed `/**` never qualify). A POSITIVE whitelist, so anything else is kept by construction: `@param` bare or NAME-ONLY (the name restates the signature), bare `@return` / `@returns`, bare `@throws` / `@exception` (`@throws IOError` is KEPT — the type is information a Haxe signature does not carry), bare `@see` — and each only when every CONTINUATION line up to the next tag / interior end is content-free, so a description on the following line protects the tag. The tag name must be followed by whitespace or line end (`@param2` is not `@param`), and a tag is a LINE-START construct — a mid-line `@word` in prose, `{@link …}`, and doxygen's `@param[in]` never match. Detection and deletion deliberately use DIFFERENT gutter predicates: detection's is permissive (whitespace + any star run, so a tag "documented" only by a `***` divider is still empty), deletion's is strict (at most ONE star) — a deliberate `*`-divider line is never deleted and blocks whole-comment deletion; when `*/` shares the last flagged line, only that line's content is deleted and the closer stays. Residual interplay: the fix can reduce a doc to a divider-only or empty interior, which `empty-comment` then legitimately removes on the next fixed-point pass, and deleting a member's only doc (a lone `/** @return */`) converts a `doc-coverage`-satisfied member into a `doc-coverage` finding — intended, it unmasks a real gap (no oscillation: `doc-coverage` has no fix). Remaining doc re-flow (one-line collapse) is the canonicalizer's job, not the rule's. A pure trivia edit: comments never affect compilation

## `english-comments`

a comment (line, block, or doc) containing a NON-LATIN LETTER — the user's rule: all code comments and documentation must be in English only; `Info`, report-only (translating a comment is a human task, not a mechanical rewrite). A pure comment-token scan (`RefactorSupport.collectCommentTokens`, string-aware, so non-Latin text inside a string LITERAL is legal data and never visited); the FIRST offending code unit in each token produces ONE finding for the whole comment (not one per character), spanned at that unit with a short single-line excerpt. Flags the well-known BMP non-Latin letter blocks — Cyrillic (`U+0400..U+052F`), Hebrew, Arabic, Hangul (Jamo + syllables), Hiragana/Katakana, and CJK unified — via UTF-16 code-unit range checks (no surrogate decoding; astral CJK extensions out of scope). Deliberate non-flags: GREEK is excluded (its dominant use in code comments is mathematical / symbolic — e.g. an omega anchor tag — so flagging it would be almost all false positives); Latin-extended accents (`é` / `ü` / `ñ`, e.g. in an attribution name) are Latin script, not a separate script; and emoji, box-drawing, arrows, and typographic punctuation (`— « » … ° ×`) are not letters. No parse needed (comments are dropped from the query projection), so it is grammar-agnostic by construction

## `fragmented-doc-comment`

a declaration documented by SEVERAL adjacent doc-comment blocks (each opened and closed separately, on consecutive lines) instead of one — a confusing duplicate, usually from a doc edit that inserted a second block rather than replacing the first; `Info`, `--fix` merges the run into a single doc comment (block bodies concatenated). A pure comment-token scan (comments are dropped from the query projection). Only `/**` DOC blocks join a run: a plain block (license header, section banner), a blank line, a line comment, or any code between blocks breaks it — so license/section comments are never absorbed. Behaviour-safe (comments never affect compilation). Only a SPLIT doc is merged — every block but at most one opens with a lower-case letter, continuing the text before it; two blocks that each open a doc stay report-only (an earlier one may be the orphan of a member that moved, and merging would hand its text to this declaration)

## `misplaced-type-doc`

a `/**` doc block written between the `package` statement and the module's `import` / `using` lines — the compiler attaches a doc to the declaration it IMMEDIATELY precedes, so a block the import run separates from the module's type documents nothing: a DEAD doc, invisible to every IDE and doc generator, that still reads as documentation to the next human. `Warning`, `--fix` MOVES the block verbatim into the type declaration's leading trivia (above its `@:meta` / modifier run, where a type's doc is read), supplying the separating blank line when the anchor lacks one. The comment text is never reflowed or rewritten — a trivia MOVE, so the writer's comment guard sees the same block leave one slot and arrive in another. Import layout is what strands the doc and what keeps stranding it (`AddImport` splices a new plain import at its ordered slot, which for an import sorting first is directly below the block), so the rule is registered ahead of the import rules. Gates, each with a negative fixture: only a `/**` block with a non-blank body (a plain `/* … */` banner and a `//` run are license headers and section labels); the type must carry no doc of its own (two docs are never merged); EXACTLY ONE top-level type (with two, which one the doc was written for is a guess — `enum abstract` counts, though `RefShape.typeDeclKinds` omits it); a block ABOVE the `package` statement is a FILE header and is never touched (so a module with no package statement never fires); exactly ONE doc block in the gap (two adjacent ones are `fragmented-doc-comment`'s job, and this rule fires on the merged block at the next pass); and the block must OWN its lines, else the finding stays report-only. The file-header gate is POSITIONAL by design — it asks where the block was written, not what it says — so an attribution note below the package statement reads as a type doc and moves onto the type. That judgement about an author's intent is why the rule is DEFAULT OFF: opt in with `"misplaced-type-doc": { "enabled": true }`

## `prefer-doc-comment`

a `//` comment that documents a type or member declaration — prose in the one comment form no doc extractor reads; `Info`, `--fix` turns it into a doc comment at the declaration's doc anchor. TWO comment sources: an ABOVE-LINE RUN of consecutive whole-line `//` comments immediately above the declaration (rewritten in place), and a TRAILING DECL COMMENT at the end of the declaration's own line (`public final startTime:Date = Date.now(); // when this session started`), which is RELOCATED — the tail is cut back to the code's last token and the doc inserted above the declaration's `@:meta` / modifier run. A trailing comment's ownership is positional and unambiguous, so the label gates (2, 3, 10, 11) do not apply to it; it has its own position gates instead — the declaration must be ANCHORED on that line (a continuation line of a wrapped declaration carries no anchor) and be the ONLY one there (`var a; var b; // note` has no single owner), the code before the comment must END the declaration with `;` or OPEN its body with `{` (a closing `}`, a `case` colon and a statement inside a body all fail to carry an anchor), and a `//` run directly above the declaration wins, so the two sources never stack two docs. The content gates (4-9) are shared. The gates below are stated for the run source. The inverse direction of `prefer-line-comment`, and its complement: that rule pulls a block comment OUT of a statement position, this one lifts a line comment INTO the doc slot, and neither can fire on what the other converts. DEFAULT OFF (`DefaultOff`): whether a note above a declaration is documentation or an aside is an authoring judgement — opt in with `"rules": { "prefer-doc-comment": { "enabled": true } }`. Detection is a comment-token scan (`RefactorSupport.collectCommentTokens`, string-aware) crossed with the parse tree: consecutive WHOLE-LINE `//` tokens group into a RUN, and the run qualifies when the line right after it is the declaration's first line — where "first line" is the start of the leading `@:meta` / modifier run, the same doc anchor `doc-coverage` and `misplaced-type-doc` compute (`RefShape.typeDeclKinds` + `memberDeclKinds` + `enumAbstractDeclKind`; with none of them set the check is a no-op, and a kind outside those sets — a module-level function, an enum constructor — is not an anchor). Eleven gates: (1) WHOLE-LINE OWNERSHIP — a trailing `// note` after code is a remark about that line and never joins a run; (2) ADJACENCY — zero blank lines between run and declaration, which is also what keeps a run sitting above an EXISTING doc out; (3) INDENT MATCH — every run line carries the declaration's own indent; (4) NO EXISTING DOC — a `/**` block directly above the run means the declaration is already documented, and two docs are never merged (that is `fragmented-doc-comment`'s shape); (5) NO TOOLING DIRECTIVE — `noqa`, `CHECKSTYLE:`, `@formatter:`, `#region` / `#endregion` skip the run WHOLE, since burying a machine instruction in a doc block both silences it and documents nothing; (6) NO TASK MARKER — `TODO` / `FIXME` / `HACK` / `XXX` anywhere in the run (case-insensitive), a reminder to change the code not a description of it; (7) READS AS PROSE — a POSITIVE criterion rather than a list of commented-out shapes to dodge (a negative list leaks: every shape left off it converts silently): the line's first word must not be a declaration / statement keyword, nor a control keyword with the construct's `(` or `{` behind it, and the line must carry no `=` or `@` and no punctuation in a CODE POSITION: a `;` with nothing but a trailing `//` behind it (a statement terminator — a prose semicolon joins two clauses, `… filenames in NFD; servers use NFC.`), a `{` ending the line or a `}` opening or ending it (block delimiters — `Returns {x, y} in stage space.` is prose), an identifier glued to a `(` (a call — prose puts a space before a bracket) and an identifier glued to a `:` that an identifier follows (a type annotation — a prose colon is followed by a space or ends the line). The keyword match is CASE-SENSITIVE, so `If unset, …` and `for internal use only` stay prose while `if (b) {` and `for (x in xs)` do not; (8) NOT a `///` RUN — triple-slash is a section-label convention; (9) NOT SECTION DECORATION — a run drawn only from `-=*_#`, or a DECORATED label (`// --- Mobile touch ---`: rule characters on both ends around at most four words); (10) NOT A SECTION LABEL — a note above a RUN of siblings labels the run (`// Button` over four constants), and attaching it to sibling #1 as that member's haxedoc both misdescribes the member and loses the label; two layouts express a run, so there are two readings — siblings on CONSECUTIVE lines (the blank-line group, where nesting in either direction is not sibling-hood) and blank-line-SEPARATED siblings, where the section ends at the next label — or at a separately-documented sibling, whose own doc proves the run cannot label a span across it — rather than at the next blank line, and only same-owner same-kind siblings count; (11) NOT THE ENCLOSING TYPE'S HEADING CONVENTION — a type that writes section headings also writes SINGLE-member ones (`// Slider` over the one constant that needs it) which no shape test can tell from a doc, so that type's own statistics decide: in each declaration body the runs proven to label a section are counted against those over a lone declaration, and a strict majority of the former makes every run in that body a heading. Sibling-hood and the tally are both bounded by the ENCLOSING declaration's span, never by indent — two types in one module hold their members at the same depth, so an indent-bounded scan read one type's members as another's and let a constants table's headings suppress a sibling model type's genuine docs. One grouping among nine per-member docs is an author grouping two related fields, not a convention. Every gate is ablation-verified by a fixture that flips when it alone is removed, except adjacency (2), which is enforced by construction (the anchor index is keyed on the line right after the run) and is covered jointly with the indent gate. On the consuming project the label gates take the finding count from 120 to 29, of which 2 are label-shaped. A content-free run is ceded to `empty-comment`, whose fix DELETES it, and a run whose text contains `*/` is left alone (wrapping it would end the doc mid-text). Two shapes convert that only a human can adjudicate, and are left for the review of the diff: a comment above a leading `@:meta` run becomes the TYPE's doc even when it annotates the metadata, and a provenance header (`// Based on https://…`) becomes public documentation. The fix emits `/**` + one `<indent> * <text>` line per comment line (an empty comment line becomes a bare `<indent> *`) + `<indent> */`, or a one-line `<indent>/** <text> */` for a single-line run, with the `//` and ONE following space stripped so relative indentation survives and the file's own line terminator preserved. That shape is byte-identical to what `BlockCommentNormalizer.canonicalDoc` emits under `comments.blockCommentStyle: "javadoc"`, and is a fixed point of the default `Verbatim` writer — so a fixed site does not drift on the next `fmt`. Under that style a multi-line fix output whose interior is a single content line is then COLLAPSED back to the one-line form by the writer, which is also what the single-line-run fix emits directly — the two paths converge rather than ping-pong. A pure trivia edit: comments never affect compilation

## `prefer-line-comment`

a `/* … */` BLOCK comment sitting in a STATEMENT position inside a function body — prose that reads as a line comment, written with block delimiters; `Info`, `--fix` rewrites it to `//` line comments. DEFAULT OFF (`DefaultOff`): block-vs-line comment style is a project convention, not a defect — opt in with `"rules": { "prefer-line-comment": { "enabled": true } }`. A comment-token scan (`RefactorSupport.collectCommentTokens`, string-aware, so a `/*` inside a STRING literal is never visited) crossed with the parse tree. Three positive shapes qualify: a WHOLE-LINE block, a TRAILING block (`g(); /* why */` → `g(); // why`), and a MULTI-LINE block whose delimiters own their lines. Each also needs the STATEMENT-POSITION gate — the innermost node enclosing the token must be a statement block (`RefShape.blockBodyKind` / `blockStmtKind`), which is what keeps a DECLARATION's doc out of scope (its enclosing node is the type body, not a block) and what rejects a comment nested in an EXPRESSION, whose conversion could let the writer re-join the following operand onto the commented-out line (`foo(a, /* x */` with the `b);` on the next line passes every textual test and is refused here) — plus the hard textual gate that the closing delimiter be the last non-whitespace on its line, or a `//` would swallow the code after it (this is what rejects the mid-expression `foo(a /* x */, b)`). Two shapes are deliberately ceded: a CONTENT-FREE comment (only whitespace and stars) belongs to `empty-comment`, whose fix DELETES rather than converts — converting it would strand an un-deletable `// *`; and a `/**` block immediately above a LOCAL FUNCTION declaration is a real doc for that function, the in-body analogue of the member doc the position gate already excludes (a PLAIN block above one is prose and still converts). The fix writes each body line as `// <text>`: delimiters stripped — including the star run of a `/***` open or a `**/` close, so neither leaks into the body — the block's own indent re-emitted before each continuation line, the file's own line terminator preserved (`\r\n` stays `\r\n`), and the body's COMMON leading whitespace removed so its relative indentation survives, with the CLOSING line excluded from that common prefix (it carries the wrap's structural indent, not the body's) — the same two decisions `BlockCommentNormalizer.normalize` makes. A leading `*` is CONTENT unless the block is javadoc-STYLED (three or more lines whose every non-blank interior line opens with `*`, the writer's own `isJavadocStyle` predicate), so the single-line `/* * 2 */` keeps its star (→ `// * 2`) while a gutter block loses its column — the SHAPE decides, not the open delimiter, so a plain `/*` gutter block is stripped too. A pure trivia edit: comments never affect compilation
