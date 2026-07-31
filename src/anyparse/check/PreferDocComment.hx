package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.FragmentedDocComment.CommentTok;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a run of `//` line comments written directly above a TYPE or MEMBER
 * declaration — prose that documents the declaration, in the one comment form no doc
 * extractor reads. `Info`; `--fix` rewrites the run to a doc comment at the
 * declaration's indent. A pure trivia edit: a comment never affects compilation, and
 * the rewrite preserves every line's own text.
 *
 * The inverse direction of `prefer-line-comment`, and its complement: that rule pulls a
 * block comment OUT of a statement position, this one lifts a line comment INTO the doc
 * slot. Neither can fire on what the other converts.
 *
 * ## Detection
 *
 * A comment-token scan (`RefactorSupport.collectCommentTokens`, string-aware — a `//`
 * inside a STRING literal is never visited) crossed with the parse tree. Consecutive
 * WHOLE-LINE `//` tokens — each owning its line, nothing but whitespace beside it — group
 * into a RUN, and the run qualifies when the line right after it is the declaration's
 * first line. "First line" means the start of the leading `@:meta` / modifier run, which
 * projects as siblings BEFORE the declaration node and is where the compiler reads a doc
 * from — the same anchor `doc-coverage` and `misplaced-type-doc` compute.
 *
 * ## Gates — a run is documentation only when every one of these holds
 *
 *  1. WHOLE-LINE OWNERSHIP. A trailing `// note` after code is a remark about that line,
 *     not about the declaration below, and could not move to the doc slot anyway.
 *  2. ADJACENCY. Zero blank lines between the run and the declaration. A blank line
 *     detaches the comment — it becomes a section label or a note about the code above.
 *     This is also what keeps a run ABOVE AN EXISTING DOC out: the doc, not the
 *     declaration, is what follows the run.
 *  3. INDENT MATCH. Every line of the run carries the declaration's own indent. A run at
 *     a different column belongs to a different nesting level.
 *  4. NO EXISTING DOC. A `/**` block directly above the run means the declaration is
 *     already documented; converting would leave two adjacent doc blocks
 *     (`fragmented-doc-comment`'s shape). Two docs are never merged.
 *  5. NO TOOLING DIRECTIVE. A run containing `noqa`, `CHECKSTYLE:`, `@formatter:` or a
 *     `#region` / `#endregion` marker is skipped WHOLE — those lines are machine
 *     instructions, and burying one in a doc block both silences it and documents
 *     nothing. The list is `DIRECTIVE_MARKERS`.
 *  6. NO TASK MARKER. `TODO` / `FIXME` / `HACK` / `XXX` anywhere in the run (case-
 *     insensitive) — a reminder to change the code is not a description of it.
 *  7. READS AS PROSE. Every line must satisfy `readsAsProse`, a POSITIVE criterion:
 *     English, not code. Stated the other way round — as a list of the commented-out
 *     shapes to dodge — it leaks, because every shape left off the list converts
 *     silently. See `readsAsProse` for the definition.
 *  8. NOT A `///` RUN. Triple-slash is a section-label convention, not a per-declaration
 *     doc; such a run is skipped entirely.
 *  9. NOT SECTION DECORATION. A rule (`//----`) or a DECORATED label
 *     (`// --- Mobile touch ---`) is a visual divider, not a description.
 * 10. NOT A SECTION LABEL. A note above a RUN of siblings labels the run, and attaching it
 *     to sibling #1 as that member's haxedoc both misdescribes the member and loses the
 *     label. Two readings of "run", because two layouts express it: the siblings sit on
 *     CONSECUTIVE lines (`soleInGroup`), or they are blank-line-separated and the section
 *     ends at the next label — or at a separately-documented sibling — rather than at the
 *     next blank line (`soleInSection`).
 * 11. NOT THE ENCLOSING TYPE'S HEADING CONVENTION. A type that writes section headings
 *     also writes SINGLE-member ones, which no shape test can tell from a doc — so that
 *     type's own statistics decide. See `headingConventionOwners`.
 *
 * A content-free run (every line empty after the `//`) is ceded to `empty-comment`, whose
 * fix DELETES it — converting would emit an empty doc block. A run whose text contains
 * `*\/` is left alone too: wrapping it would end the doc mid-text and leave the tail as
 * code.
 *
 * ## What the gates deliberately do NOT decide — read the diff
 *
 * Two shapes convert although only a human can say whether they should. Both are
 * report-then-review material, not defects:
 *
 *  - A comment above a leading `@:meta` run becomes the TYPE's doc even when it annotates
 *    the METADATA rather than the declaration (`// access private fields` above an
 *    `@:access(...)`). The anchor is the compiler's doc slot, and nothing in the text
 *    distinguishes the two readings.
 *  - A provenance header (`// Based on https://…`, `// Ported from …`) converts into the
 *    declaration's public documentation, which may not be where its author wanted it.
 *
 * ## Fix
 *
 * A multi-line run becomes `/**` + one `<indent> * <text>` line per comment line (an empty
 * comment line becomes a bare `<indent> *`) + `<indent> *\/`; a single-line run becomes
 * `<indent>/** <text> *\/`. The text is the comment body with the `//` and ONE following
 * space stripped, so relative indentation inside the run survives. The file's own line
 * terminator is preserved (`\r\n` stays `\r\n`).
 *
 * That shape is byte-identical to what `BlockCommentNormalizer.canonicalDoc` emits under
 * `commentStyle: Javadoc`, and it is a fixed point of the default `Verbatim` writer — so
 * a fixed site neither drifts on the next `fmt` nor ping-pongs against the comment style.
 *
 * DEFAULT OFF (`DefaultOff`): whether a note above a declaration is documentation or an
 * aside is an authoring judgement. Opt in with
 * `"rules": { "prefer-doc-comment": { "enabled": true } }`.
 *
 * ## Grammar-agnostic
 *
 * The declaration kinds come from `RefShape.typeDeclKinds` + `memberDeclKinds` (plus
 * `enumAbstractDeclKind`, which `typeDeclKinds` omits); with neither of the first two set
 * the check is a no-op. Kinds outside those sets — a module-level function or variable, an
 * enum constructor, a typedef field — are not anchors, so a run above one is left alone.
 * The modifier / `@:meta` run is recognised through `CheckScan.modifierKinds` and
 * `CheckScan.isLeadingAnnotation`. Sibling-hood is decided by the ENCLOSING declaration's
 * span, never by indent: two types in one module hold their members at the same depth.
 */
@:nullSafety(Strict)
final class PreferDocComment implements Check implements DefaultOff {

	private static inline final RULE_ID: String = 'prefer-doc-comment';

	/** The line-comment opener, stripped from each body line. */
	private static inline final LINE_MARKER: String = '//';

	/** The triple-slash section-label opener of gate 8. */
	private static inline final LABEL_MARKER: String = '///';

	/** The block-comment closer, which a converted body must not contain. */
	private static inline final BLOCK_CLOSE: String = '*/';

	/**
	 * Tooling directives (gate 5), lower-cased and matched as a LINE PREFIX. `noqa` and
	 * `CHECKSTYLE:` are this project's own suppression markers (`Suppression`); the
	 * `@formatter:` and `#region` pairs are the two conventions foreign formatters and
	 * IDEs read out of Haxe line comments.
	 */
	private static final DIRECTIVE_MARKERS: Array<String> = ['noqa', 'checkstyle:', '@formatter:', '#region', '#endregion'];

	/** Task markers (gate 6), lower-cased and matched ANYWHERE in a line. */
	private static final TASK_MARKERS: Array<String> = ['todo', 'fixme', 'hack', 'xxx'];

	/** The characters a section rule is drawn from (gate 9) — `//----`, `// === `, `// --- Mobile touch ---`. */
	private static inline final SEPARATOR_CHARS: String = '-=*_#';

	/** The longest a DECORATED phrase can be and still read as a section label rather than a sentence (gate 9). */
	private static inline final DECORATED_LABEL_WORDS: Int = 4;

	/**
	 * Declaration and statement HEADS (gate 7): the Haxe keywords that open a line of code
	 * and never open an English sentence in lower case. Matched CASE-SENSITIVELY, which is
	 * what lets `If unset, the default applies` stay prose while `if (b) {` does not.
	 */
	private static final CODE_HEAD_KEYWORDS: Array<String> = [
		'abstract',
		'break',
		'case',
		'cast',
		'catch',
		'class',
		'continue',
		'dynamic',
		'else',
		'enum',
		'extern',
		'final',
		'function',
		'import',
		'inline',
		'interface',
		'macro',
		'new',
		'override',
		'package',
		'private',
		'public',
		'return',
		'static',
		'throw',
		'try',
		'typedef',
		'untyped',
		'using',
		'var'
	];

	/**
	 * Control-flow heads (gate 7). Unlike the declaration heads these DO open English
	 * sentences — `for internal use only`, `while loading`, `do not call this directly` —
	 * so they read as code only when the parenthesised or braced head of the construct
	 * follows.
	 */
	private static final CONTROL_HEAD_KEYWORDS: Array<String> = ['do', 'for', 'if', 'switch', 'while'];

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a line comment directly above a declaration, replaceable with a doc comment';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		return seams == null ? [] : [
			for (entry in files) for (rewrite in rewrites(entry.source, plugin, seams))
				{
					file: entry.file,
					span: rewrite.comment,
					rule: RULE_ID,
					severity: Severity.Info,
					message: 'line comment above a declaration; use a doc comment'
				}
		];
	}

	/** Rewrite each flagged run to a doc comment. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final flagged: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(span.from);
		}
		return [
			for (rewrite in rewrites(source, plugin, seams)) if (flagged.contains(rewrite.comment.from))
				{ span: rewrite.edit, text: rewrite.text }
		];
	}

	/** Every convertible run in `source`, in source order. */
	private static function rewrites(source: String, plugin: GrammarPlugin, seams: Seams): Array<DocCommentRewrite> {
		final comments: Array<CommentTok> = RefactorSupport.collectCommentTokens(source);
		final owned: Array<CommentTok> = [for (tok in comments) if (ownsItsLine(source, tok)) tok];
		if (owned.length == 0) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final anchors: Map<Int, Anchor> = [];
		collectAnchors(source, tree, seams, new Span(-1, source.length), anchors);
		final docEnds: Map<Int, Bool> = CheckScan.docBlockEnds(source);
		// What ends a section: the next label, or the next separately-documented sibling.
		final stops: Array<CommentTok> = [for (tok in comments) if (
			ownsItsLine(source, tok) || RefactorSupport.isDocBlock(source, tok)
		) tok];
		final headings: Array<Int> = headingConventionOwners(source, anchors, owned, stops);
		final out: Array<DocCommentRewrite> = [];
		for (run in runsOf(source, owned)) {
			final rewrite: Null<DocCommentRewrite> = rewriteOf(source, run, anchors, docEnds, stops, headings);
			if (rewrite != null) out.push(rewrite);
		}
		return out;
	}

	/**
	 * GATE 11 — the declarations whose bodies demonstrably write `//` runs as SECTION
	 * HEADINGS, identified by the span of the enclosing declaration (`Anchor.owner`).
	 *
	 * A heading over a MULTI-member section is unambiguous — `soleInSection` proves it. But a
	 * type that writes headings also writes SINGLE-member ones (`// Horizontal Separator` over
	 * the one colour that needs it), and those cannot be told from a real doc by their own
	 * shape. What tells them apart is the CONVENTION of the type they sit in, so the runs in
	 * each body are counted: when the ones proven to label a section OUTNUMBER the ones
	 * sitting over a lone declaration, that body writes headings and none of its runs convert.
	 *
	 * A strict majority is the point. One heading among nine per-member docs is an author
	 * grouping two related fields, not a convention — treating it as one would cost every real
	 * doc in the type. Measured on the consuming project this is the difference between losing
	 * a model class's nine field docs and keeping them.
	 *
	 * Keyed on the OWNER rather than the indent: two types in one module hold their members at
	 * the same depth, so an indent tally let a constants table's headings outvote — and
	 * silently suppress — a sibling model type's genuine docs.
	 */
	private static function headingConventionOwners(
		source: String, anchors: Map<Int, Anchor>, owned: Array<CommentTok>, stops: Array<CommentTok>
	): Array<Int> {
		final headings: Map<Int, Int> = [];
		final docs: Map<Int, Int> = [];
		for (tok in owned) {
			final indent: String = indentOf(source, tok.from);
			final anchor: Null<Anchor> = anchors[tok.to + 1];
			if (anchor == null || indentOf(source, anchor.from) != indent) continue;
			final tally: Map<Int, Int> = soleInSection(source, anchors, stops, anchor, indent) ? docs : headings;
			tally[anchor.owner] = (tally[anchor.owner] ?? 0) + 1;
		}
		return [for (owner => count in headings) if (count > (docs[owner] ?? 0)) owner];
	}

	/** Gate 1: a line comment with nothing but whitespace before it (its close is the line end by construction). */
	private static function ownsItsLine(source: String, tok: CommentTok): Bool {
		return tok.isLine && StringTools.trim(indentOf(source, tok.from)) == '';
	}

	/** Consecutive whole-line tokens grouped into runs — a gap of one line or more starts a new run. */
	private static function runsOf(source: String, toks: Array<CommentTok>): Array<Array<CommentTok>> {
		final runs: Array<Array<CommentTok>> = [];
		var current: Array<CommentTok> = [];
		for (tok in toks) {
			if (current.length > 0 && RefactorSupport.startOfLine(source, tok.from) != current[current.length - 1].to + 1) {
				runs.push(current);
				current = [];
			}
			current.push(tok);
		}
		if (current.length > 0) runs.push(current);
		return runs;
	}

	/**
	 * The rewrite for `run`, or null when a gate declines. Gates run cheapest-first: the
	 * run's own lines must agree on indent (gate 3), an anchor must be indexed under the
	 * line right after the run (gate 2) and carry that same indent (gate 3), that anchor must
	 * be alone in its group (gate 10), no doc may sit above the run (gate 4), and every line
	 * must pass the content gates (5-9).
	 */
	private static function rewriteOf(
		source: String, run: Array<CommentTok>, anchors: Map<Int, Anchor>, docEnds: Map<Int, Bool>, stops: Array<CommentTok>,
		headings: Array<Int>
	): Null<DocCommentRewrite> {
		final first: CommentTok = run[0];
		final last: CommentTok = run[run.length - 1];
		final indent: String = indentOf(source, first.from);
		for (tok in run) if (indentOf(source, tok.from) != indent) return null;
		final declLine: Int = last.to + 1;
		final anchor: Null<Anchor> = anchors[declLine];
		if (anchor == null) return null;
		if (indentOf(source, anchor.from) != indent) return null;
		if (!soleInGroup(source, anchors, anchor, declLine)) return null;
		if (!soleInSection(source, anchors, stops, anchor, indent)) return null;
		if (headings.contains(anchor.owner)) return null;
		if (CheckScan.hasDocBefore(source, docEnds, first.from)) return null;
		final lines: Array<String> = [];
		for (tok in run) {
			if (source.substring(tok.from, tok.from + LABEL_MARKER.length) == LABEL_MARKER) return null;
			final text: String = commentText(source, tok);
			// A body carrying the block-comment closer cannot be wrapped in one: the doc
			// would end mid-text and the tail would be code. Nothing to convert here.
			if (text.indexOf(BLOCK_CLOSE) >= 0) return null;
			if (declines(StringTools.trim(text))) return null;
			lines.push(text);
		}
		if (contentFree(lines) || separatorOnly(lines)) return null;
		final newline: String = source.substring(first.from, last.to).indexOf('\r\n') >= 0 ? '\r\n' : '\n';
		return {
			comment: new Span(first.from, last.to),
			edit: new Span(first.from, editEndOf(source, last)),
			text: docText(lines, indent, newline)
		};
	}

	/**
	 * GATE 10, first half — whether the anchored declaration is the ONLY one in its
	 * blank-line-delimited group.
	 *
	 * A comment above a RUN of siblings is a GROUP LABEL, not the first sibling's
	 * documentation: `// Button` over four `public static inline final` constants describes
	 * all four, and attaching it to constant #1 as a haxedoc both misdescribes that constant
	 * and loses the label. This gate is what separates the two readings — a note above a
	 * declaration that stands alone in its group is about that declaration and nothing else.
	 *
	 * The group is the maximal run of non-blank lines containing the declaration, which is
	 * how authors already separate one member from the next. NESTING is not sibling-hood, in
	 * either direction: the `class C {` line directly above the first member ENCLOSES it (or
	 * no first member would ever convert), and a compact type's own members are enclosed BY
	 * it (or `// Kinds.` above a one-line `enum abstract` would never convert).
	 */
	private static function soleInGroup(source: String, anchors: Map<Int, Anchor>, self: Anchor, declLine: Int): Bool {
		final from: Int = groupStart(source, declLine);
		final to: Int = groupEnd(source, declLine);
		for (line => other in anchors) {
			if (line < from || line >= to || other.from == self.from) continue;
			if (encloses(other, self) || encloses(self, other)) continue;
			return false;
		}
		return true;
	}

	/** Whether `outer`'s span covers `inner`'s — a nesting relation, so the two are not siblings. */
	private static inline function encloses(outer: Anchor, inner: Anchor): Bool {
		return outer.from <= inner.from && outer.to >= inner.to;
	}

	/**
	 * GATE 10, second half — whether the run labels a SECTION rather than the one
	 * declaration under it.
	 *
	 * The blank-line group above catches a label over a CONTIGUOUS run of siblings, but a
	 * codebase that blank-line-separates its members writes the same label differently:
	 *
	 * ```
	 * // PopupManager
	 * public static inline final POPUP_BACKGROUND_COLOR:UInt = 0x000000;
	 *
	 * public static inline final POPUP_BACKGROUND_ALPHA:Float = .3;
	 *
	 * // Button
	 * ```
	 *
	 * `// PopupManager` is alone in its blank-line group and still labels both constants —
	 * what ends the section is the NEXT label, not the next blank line. So the scan runs
	 * from the anchored declaration's end to the next stop and refuses if another sibling
	 * lies inside. A sibling is a declaration with the SAME OWNER (the enclosing
	 * declaration's span, so a second type's members never count) and the SAME KIND (a label
	 * groups members of one kind; the methods that follow a documented field are not what it
	 * labels).
	 *
	 * Three things stop the scan: the next whole-line `//` run at this indent (the next
	 * label), the next `/**` doc block (a separately-documented sibling proves the run
	 * cannot label a section spanning it), and the owner's own end.
	 *
	 * Measured on the consuming project this is the gate that matters: it is what the
	 * `constants/` tables — the bulk of the label-shaped findings — trip on.
	 */
	private static function soleInSection(
		source: String, anchors: Map<Int, Anchor>, stops: Array<CommentTok>, self: Anchor, indent: String
	): Bool {
		final stop: Int = sectionStop(source, stops, self, indent);
		for (other in anchors) {
			if (other.from <= self.to || other.from >= stop) continue;
			if (other.owner == self.owner && other.kind == self.kind) return false;
		}
		return true;
	}

	/**
	 * Where `self`'s section ends: the first stop comment past the declaration at this
	 * indent, capped at the owner's end. Deeper comments belong to a body, not to this
	 * nesting level, so they do not end the section.
	 */
	private static function sectionStop(source: String, stops: Array<CommentTok>, self: Anchor, indent: String): Int {
		for (tok in stops) if (tok.from > self.to && indentOf(source, tok.from) == indent)
			return tok.from < self.ownerEnd ? tok.from : self.ownerEnd;
		return self.ownerEnd;
	}


	/** The start of the first non-blank line of `lineStart`'s group. */
	private static function groupStart(source: String, lineStart: Int): Int {
		var at: Int = lineStart;
		while (at > 0) {
			final previous: Int = RefactorSupport.startOfLine(source, at - 1);
			if (StringTools.trim(source.substring(previous, at - 1)) == '') break;
			at = previous;
		}
		return at;
	}

	/** The start of the first blank line after `lineStart`'s group (or the source end). */
	private static function groupEnd(source: String, lineStart: Int): Int {
		var at: Int = lineStart;
		while (at < source.length) {
			final newline: Int = source.indexOf('\n', at);
			final end: Int = newline < 0 ? source.length : newline;
			if (StringTools.trim(source.substring(at, end)) == '') break;
			if (newline < 0) return source.length;
			at = newline + 1;
		}
		return at;
	}

	/**
	 * GATE 9 — whether the run is SECTION DECORATION rather than a description. Two shapes:
	 *
	 *  - a pure rule (`//----`, `// === `): nothing but `SEPARATOR_CHARS` and whitespace;
	 *  - a DECORATED LABEL (`// --- Mobile touch ---`): rule characters on both ends around a
	 *    short phrase. The decoration is what makes it a divider — the same words without it
	 *    (`// Mobile touch`) are judged by the label gates like any other run, and a sentence
	 *    long enough to be documentation is not turned into one by a leading dash.
	 */
	private static function separatorOnly(lines: Array<String>): Bool {
		if (ruleCharsOnly(lines)) return true;
		if (lines.length != 1) return false;
		final text: String = StringTools.trim(lines[0]);
		return text.length > 0 && isRuleChar(StringTools.fastCodeAt(text, 0)) && isRuleChar(StringTools.fastCodeAt(text, text.length - 1))
			&& wordCount(stripRuleChars(text)) <= DECORATED_LABEL_WORDS;
	}

	/** Whether every line is drawn only from rule characters and whitespace. */
	private static function ruleCharsOnly(lines: Array<String>): Bool {
		for (line in lines) for (i in 0...line.length) {
			final c: Int = StringTools.fastCodeAt(line, i);
			if (c != ' '.code && c != '\t'.code && !isRuleChar(c)) return false;
		}
		return true;
	}

	/** Whether `c` is one of the characters a section rule is drawn from. */
	private static inline function isRuleChar(c: Int): Bool {
		return SEPARATOR_CHARS.indexOf(String.fromCharCode(c)) >= 0;
	}

	/** `text` with every rule character replaced by a space. */
	private static function stripRuleChars(text: String): String {
		final buf: StringBuf = new StringBuf();
		for (i in 0...text.length) {
			final c: Int = StringTools.fastCodeAt(text, i);
			buf.addChar(isRuleChar(c) ? ' '.code : c);
		}
		return buf.toString();
	}

	/** The number of whitespace-separated words in `text`. */
	private static function wordCount(text: String): Int {
		var words: Int = 0;
		for (part in StringTools.trim(text).split(' ')) if (StringTools.trim(part) != '') words++;
		return words;
	}

	/**
	 * Where the replacement stops: the run's last token end, minus a trailing CR. The
	 * token spans up to (not including) the `\n`, so on a CRLF file the `\r` sits INSIDE
	 * it — replacing through it would leave the emitted close followed by a bare `\n` and
	 * silently downgrade that one line ending.
	 */
	private static inline function editEndOf(source: String, last: CommentTok): Int {
		return last.to > last.from && StringTools.fastCodeAt(source, last.to - 1) == '\r'.code ? last.to - 1 : last.to;
	}

	/**
	 * Gates 5-7 over one trimmed body line: a tooling directive, a task marker, or anything
	 * that does not READ AS PROSE.
	 */
	private static function declines(text: String): Bool {
		final lower: String = text.toLowerCase();
		for (marker in DIRECTIVE_MARKERS) if (StringTools.startsWith(lower, marker)) return true;
		for (marker in TASK_MARKERS) if (lower.indexOf(marker) >= 0) return true;
		return !readsAsProse(text);
	}

	/**
	 * Gate 7, stated POSITIVELY: whether `text` reads as prose. The rule converts what it can
	 * recognise as English, rather than dodging a list of code shapes — a blacklist of
	 * commented-out forms leaks, because every shape omitted from it converts silently and the
	 * list can only grow after the fact.
	 *
	 * Prose is a line that opens with something other than a code head and carries no
	 * punctuation English does not use:
	 *
	 *  - its first word is not a declaration / statement keyword (`CODE_HEAD_KEYWORDS`), and
	 *    not a control keyword followed by the construct's `(` or `{`
	 *    (`CONTROL_HEAD_KEYWORDS`) — the keyword sets are the LANGUAGE's, a closed fact, not a
	 *    catalogue of observed mistakes;
	 *  - it holds no `;`, `{`, `}`, `=` or `@`;
	 *  - no identifier is glued to a `(` (a CALL — prose puts a space before a bracket, as in
	 *    `… width and height (center align)`);
	 *  - no identifier is glued to a `:` that a further identifier follows (a TYPE ANNOTATION
	 *    — a prose colon is followed by a space or ends the line, and a URL's `://` is neither).
	 *
	 * An empty line is prose: it is the paragraph break of a multi-line run.
	 */
	private static function readsAsProse(text: String): Bool {
		final head: String = firstWord(text);
		return !CODE_HEAD_KEYWORDS.contains(head) && !(CONTROL_HEAD_KEYWORDS.contains(head) && opensBracket(text.substr(head.length)))
			&& !hasCodePunctuation(text);
	}

	/** `text`'s leading run of identifier characters. */
	private static function firstWord(text: String): String {
		var i: Int = 0;
		while (i < text.length && isIdentChar(StringTools.fastCodeAt(text, i))) i++;
		return text.substr(0, i);
	}

	/** Whether `rest`, past any spaces, opens a `(` or `{` — the head of a control construct. */
	private static function opensBracket(rest: String): Bool {
		var i: Int = 0;
		while (i < rest.length && StringTools.fastCodeAt(rest, i) == ' '.code) i++;
		if (i >= rest.length) return false;
		final c: Int = StringTools.fastCodeAt(rest, i);
		return c == '('.code || c == '{'.code;
	}

	/**
	 * Whether `text` carries punctuation in a position English does not use but Haxe does.
	 *
	 * `=` and `@` are unconditional — neither has an English role. The rest are judged by
	 * POSITION, because the characters themselves are ordinary prose:
	 *
	 *  - `;` reads as a STATEMENT TERMINATOR only when nothing but a trailing `//` comment
	 *    follows it. A prose semicolon joins two clauses and has more sentence behind it
	 *    (`… return filenames in NFD; servers and Windows use NFC.`).
	 *  - `{` reads as a BLOCK OPENER only at the line end, `}` as a closer only at the line
	 *    start or end. Braces inside a sentence are describing a value
	 *    (`Returns {x, y} in stage space.`).
	 *  - `(` is a CALL only when glued to an identifier; prose puts a space before a bracket
	 *    (`… width and height (center align)`).
	 *  - `:` is a TYPE ANNOTATION only between two identifiers; a prose colon is followed by
	 *    a space or ends the line, and a URL's `://` is neither.
	 */
	private static function hasCodePunctuation(text: String): Bool {
		for (i in 0...text.length) {
			final c: Int = StringTools.fastCodeAt(text, i);
			if (c == '='.code || c == '@'.code) return true;
			if (c == ';'.code && terminatesLine(text, i + 1)) return true;
			if (c == '{'.code && terminatesLine(text, i + 1)) return true;
			if (c == '}'.code && (terminatesLine(text, i + 1) || StringTools.trim(text.substring(0, i)) == '')) return true;
			if (c == '('.code && i > 0 && isIdentChar(StringTools.fastCodeAt(text, i - 1))) return true;
			if (
				c == ':'.code && i > 0 && i + 1 < text.length && isIdentChar(StringTools.fastCodeAt(text, i - 1))
				&& isIdentStart(StringTools.fastCodeAt(text, i + 1))
			)
				return true;
		}
		return false;
	}

	/** Whether nothing but whitespace, or a trailing `//` comment, follows `from` — the line-terminator position. */
	private static function terminatesLine(text: String, from: Int): Bool {
		final rest: String = StringTools.trim(text.substr(from));
		return rest.length == 0 || StringTools.startsWith(rest, LINE_MARKER);
	}

	/** Whether `c` may appear inside a Haxe identifier. */
	private static inline function isIdentChar(c: Int): Bool {
		return isIdentStart(c) || (c >= '0'.code && c <= '9'.code);
	}

	/** Whether `c` may START a Haxe identifier. */
	private static inline function isIdentStart(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code || c == '$'.code;
	}

	/** Whether every line is empty — `empty-comment`'s shape, not this rule's. */
	private static function contentFree(lines: Array<String>): Bool {
		for (line in lines) if (line != '') return false;
		return true;
	}

	/**
	 * The doc block replacing a run. A multi-line run gets the ` * ` marker column and a
	 * star-aligned ` *\/` close — byte-identical to `BlockCommentNormalizer.canonicalDoc`
	 * under `commentStyle: Javadoc`, and a fixed point of the default writer. A
	 * single-line run stays on one line.
	 */
	private static function docText(lines: Array<String>, indent: String, newline: String): String {
		if (lines.length == 1) return '/** ${lines[0]} */';
		final body: Array<String> = [for (line in lines) line == '' ? '$indent *' : '$indent * $line'];
		return '/**$newline${body.join(newline)}$newline$indent */';
	}

	/** A line comment's text: the body past `//`, right-trimmed, with ONE following space removed. */
	private static function commentText(source: String, tok: CommentTok): String {
		final body: String = StringTools.rtrim(source.substring(tok.from + LINE_MARKER.length, tok.to));
		return body.length > 0 && StringTools.fastCodeAt(body, 0) == ' '.code ? body.substr(1) : body;
	}

	/** The whitespace between `at`'s line start and `at`. */
	private static inline function indentOf(source: String, at: Int): String {
		return source.substring(RefactorSupport.startOfLine(source, at), at);
	}

	/**
	 * Index every declaration's DOC ANCHOR — the start of its leading `@:meta` / modifier
	 * run, or the declaration itself when it has none — keyed by the anchor's LINE START
	 * and keeping the LEFTMOST anchor per line, which is the declaration a comment above
	 * that line documents. Each entry carries the declaration's END (so the group gate can
	 * tell an ENCLOSING declaration from a sibling), its kind, and the span of the
	 * declaration it is declared IN, which is what makes two anchors siblings. Recurses
	 * through the whole tree, so a member of a type nested in a `final class` wrapper is
	 * reached the same way a top-level type is.
	 */
	private static function collectAnchors(source: String, node: QueryNode, seams: Seams, owner: Span, out: Map<Int, Anchor>): Void {
		var runStart: Int = -1;
		for (child in node.children) {
			final span: Null<Span> = child.span;
			if (seams.decls.contains(child.kind) && span != null) {
				record(source, runStart >= 0 ? runStart : span.from, span.to, child.kind, owner, out);
				runStart = -1;
				collectAnchors(source, child, seams, span, out);
				continue;
			}
			if (CheckScan.isLeadingAnnotation(child, seams.modifiers)) {
				if (runStart < 0 && span != null) runStart = span.from;
				continue;
			}
			runStart = -1;
			collectAnchors(source, child, seams, owner, out);
		}
	}

	/** Keep the declaration under its line start, unless a further-left anchor on that line is already indexed. */
	private static function record(source: String, from: Int, to: Int, kind: String, owner: Span, out: Map<Int, Anchor>): Void {
		final line: Int = RefactorSupport.startOfLine(source, from);
		final known: Null<Anchor> = out[line];
		if (known == null || known.from > from) out[line] = {
			from: from,
			to: to,
			kind: kind,
			owner: owner.from,
			ownerEnd: owner.to
		};
	}

	/**
	 * Resolve the declaration and modifier kind-sets, or null when the grammar declares
	 * neither type nor member kinds. `enumAbstractDeclKind` joins the declaration set:
	 * `typeDeclKinds` omits it, and an `enum abstract` carries a doc like any other type.
	 */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final decls: Array<String> = (shape.typeDeclKinds ?? []).concat(shape.memberDeclKinds ?? []);
		if (decls.length == 0) return null;
		final enumAbstract: Null<String> = shape.enumAbstractDeclKind;
		if (enumAbstract != null && !decls.contains(enumAbstract)) decls.push(enumAbstract);
		final modifiers: Array<String> = CheckScan.modifierKinds(shape);
		return { decls: decls, modifiers: modifiers };
	}

}

/** One convertible run: the span to REPORT, the span to REPLACE, and the doc comment that replaces it. */
private typedef DocCommentRewrite = { comment: Span, edit: Span, text: String };

/**
 * A declaration's doc anchor (the start of its leading `@:meta` / modifier run), the declaration's own end, its node
 * kind, and the span of the declaration ENCLOSING it — `owner` is `-1` at module level. The owner is what makes two
 * anchors siblings; indent cannot, because two types in one module hold their members at the same depth.
 */
private typedef Anchor = {
	from: Int,
	to: Int,
	kind: String,
	owner: Int,
	ownerEnd: Int
};

/** Resolved kind-sets the anchor walk threads through its recursion. */
private typedef Seams = {
	final decls: Array<String>;
	final modifiers: Array<String>;
};
