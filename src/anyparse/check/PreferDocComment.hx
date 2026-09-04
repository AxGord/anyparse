package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.FragmentedDocComment.CommentTok;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SourceComments;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags a `//` comment that documents a TYPE or MEMBER declaration — prose in the one
 * comment form no doc extractor reads. `Info`; `--fix` turns it into a doc comment at the
 * declaration's doc anchor. A pure trivia edit: a comment never affects compilation, and
 * the rewrite preserves the text.
 *
 * TWO COMMENT SOURCES, and a comment qualifies as either:
 *
 *  - an ABOVE-LINE RUN — consecutive whole-line `//` comments immediately above the
 *    declaration. Rewritten in place. Most of the gates below exist for this source,
 *    because a run above a declaration may equally well be labelling the SECTION that
 *    starts there;
 *  - a TRAILING DECL COMMENT — a `//` at the end of the declaration's own line
 *    (`public final startTime:Date = Date.now(); // when this session started`).
 *    RELOCATED: the tail is cut, the doc inserted above the declaration. Ownership is
 *    positional and unambiguous, so the label gates do not apply to it — see
 *    `trailingRewriteOf` for its own position gates.
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
 * ## Gates — an ABOVE-LINE RUN is documentation only when every one of these holds
 *
 * (A trailing decl comment is subject to 4-9 and to its own position gates; 1-3, 10 and
 * 11 answer questions a trailing comment does not raise.)
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
 *     nothing. The list is `CommentProse.DIRECTIVE_MARKERS`.
 *  6. NO TASK MARKER. `TODO` / `FIXME` / `HACK` / `XXX` anywhere in the run (case-
 *     insensitive) — a reminder to change the code is not a description of it.
 *  7. READS AS PROSE. Every line must satisfy `readsAsProse`, a POSITIVE criterion:
 *     English, not code. Stated the other way round — as a list of the commented-out
 *     shapes to dodge — it leaks, because every shape left off the list converts
 *     silently. Punctuation inside a BALANCED quoted span is exempt: a quoted sample is
 *     material the prose embeds, not punctuation of the line itself. See `CommentProse.readsAsProse` for the definition.
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
 * comment line becomes a bare `<indent> *`) + `<indent> *\/`; a single-line run and every
 * trailing comment become `<indent>/** <text> *\/`. The text is the comment body with the `//` and ONE following
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

	/** The triple-slash section-label opener of gate 8. */
	private static inline final LABEL_MARKER: String = '///';

	/** The block-comment closer, which a converted body must not contain. */
	private static inline final BLOCK_CLOSE: String = '*/';

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
			for (rewrite in rewrites(source, plugin, seams)) if (flagged.contains(rewrite.comment.from)) for (edit in rewrite.edits) edit
		];
	}

	/** Whether `outer`'s span covers `inner`'s — a nesting relation, so the two are not siblings. */
	private static inline function encloses(outer: Anchor, inner: Anchor): Bool {
		return outer.from <= inner.from && outer.to >= inner.to;
	}

	/**
	 * Where the replacement stops: the run's last token end, minus a trailing CR. The
	 * token spans up to (not including) the `\n`, so on a CRLF file the `\r` sits INSIDE
	 * it — replacing through it would leave the emitted close followed by a bare `\n` and
	 * silently downgrade that one line ending.
	 */
	private static inline function editEndOf(source: String, last: CommentTok): Int {
		return last.to > last.from && source.fastCodeAt(last.to - 1) == '\r'.code ? last.to - 1 : last.to;
	}

	/** The whitespace between `at`'s line start and `at`. */
	private static inline function indentOf(source: String, at: Int): String {
		return source.substring(SourceText.startOfLine(source, at), at);
	}

	/** Every convertible run in `source`, in source order. */
	private static function rewrites(source: String, plugin: GrammarPlugin, seams: Seams): Array<DocCommentRewrite> {
		final comments: Array<CommentTok> = SourceComments.collectCommentTokens(plugin.lexicalRegions(source));
		if (comments.length == 0) return [];
		final owned: Array<CommentTok> = [for (tok in comments) if (ownsItsLine(source, tok)) tok];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final anchors: Map<Int, Anchor> = [];
		collectAnchors(source, tree, seams, new Span(-1, source.length), anchors);
		final docEnds: Map<Int, Bool> = CheckScan.docBlockEnds(source, plugin.lexicalRegions(source));
		// What ends a section: the next label, or the next separately-documented sibling.
		final stops: Array<CommentTok> = [
			for (tok in comments) if (ownsItsLine(source, tok) || SourceComments.isDocBlock(source, tok)) tok
		];
		final headings: Array<Int> = headingConventionOwners(source, anchors, owned, stops);
		final out: Array<DocCommentRewrite> = [];
		for (run in runsOf(source, owned)) {
			final rewrite: Null<DocCommentRewrite> = rewriteOf(source, run, anchors, docEnds, stops, headings);
			if (rewrite != null) out.push(rewrite);
		}
		final byDeclLine: Map<Int, Anchor> = declLineIndex(source, anchors);
		for (tok in comments) if (tok.isLine && !ownsItsLine(source, tok)) {
			final rewrite: Null<DocCommentRewrite> = trailingRewriteOf(source, tok, byDeclLine, docEnds, owned);
			if (rewrite != null) out.push(rewrite);
		}
		out.sort((a, b) -> a.comment.from - b.comment.from);
		return out;
	}

	/**
	 * The rewrite for a TRAILING `//` comment on a declaration's own line, or null when a gate declines. The rule's
	 * second comment source: an above-line run describes the declaration below it, a trailing comment describes the
	 * declaration it shares a line with, and both belong in the doc slot.
	 *
	 * Ownership here is POSITIONAL and stronger than a run's — the comment is on the declaration's own line — so the
	 * label gates (group, section, heading convention) do not apply: nothing about a trailing comment can describe a
	 * span of siblings. What does apply is the qualifying POSITION and the content gates:
	 *
	 *  - the declaration must be ANCHORED on this line (a continuation line of a wrapped declaration carries no
	 *    anchor, so it never qualifies) and be the ONLY one there (`var a; var b; // note` has no single owner);
	 *  - the code before the comment must END the declaration with `;` — a field whose statement closes on this line
	 *    — or OPEN its body with `{` — a function or type whose header closes on this line. A closing `}`, a `case`
	 *    colon, a statement inside a body: none of those reaches here, because none of those lines carries an anchor;
	 *  - the declaration must carry no doc already, and no `//` run directly above it — that run is the other
	 *    mechanism's, and stacking the two would emit two docs;
	 *  - the content gates are the run's own (`///`, `*\/`, directives, task markers, decoration and `CommentProse.readsAsProse`),
	 *    applied to the single line.
	 *
	 * The fix RELOCATES rather than rewrites in place: the tail is cut back to the code's last token and the doc is
	 * inserted at the declaration's anchor, above any `@:meta` / modifier run. A single content line, so it takes the
	 * one-line doc form, which the writer's collapse keeps stable.
	 */
	private static function trailingRewriteOf(
		source: String, tok: CommentTok, byDeclLine: Map<Int, Anchor>, docEnds: Map<Int, Bool>, owned: Array<CommentTok>
	): Null<DocCommentRewrite> {
		final lineStart: Int = SourceText.startOfLine(source, tok.from);
		final anchor: Null<Anchor> = byDeclLine[lineStart];
		if (anchor == null || anchor.count > 1) return null;
		final codeEnd: Int = trimmedEnd(source, lineStart, tok.from);
		final closer: Int = source.fastCodeAt(codeEnd - 1);
		if (closer != ';'.code && closer != '{'.code) return null;
		if (CheckScan.hasDocBefore(source, docEnds, anchor.from)) return null;
		for (run in owned) if (run.to + 1 == lineStart) return null;
		final text: Null<String> = gatedText(source, tok);
		if (text == null) return null;
		final lines: Array<String> = [text];
		if (CommentProse.carriesNoDocumentation(lines)) return null;
		final editEnd: Int = editEndOf(source, tok);
		final newline: String = editEnd == tok.to ? '\n' : '\r\n';
		return {
			comment: new Span(tok.from, tok.to),
			edits: [
				{ span: new Span(anchor.from, anchor.from), text: '/** $text */$newline${indentOf(source, anchor.from)}' },
				{ span: new Span(codeEnd, editEnd), text: '' }
			]
		};
	}

	/** The offset just past the last non-whitespace character of `[from, to)`. */
	private static function trimmedEnd(source: String, from: Int, to: Int): Int {
		var at: Int = to;
		while (at > from) {
			final c: Int = source.fastCodeAt(at - 1);
			if (c != ' '.code && c != '\t'.code) break;
			at--;
		}
		return at;
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
			if (current.length > 0 && SourceText.startOfLine(source, tok.from) != current[current.length - 1].to + 1) {
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
			final text: Null<String> = gatedText(source, tok);
			if (text == null) return null;
			lines.push(text);
		}
		if (CommentProse.carriesNoDocumentation(lines)) return null;
		final newline: String = editEndOf(source, last) == last.to ? '\n' : '\r\n';
		return {
			comment: new Span(first.from, last.to),
			edits: [
				{ span: new Span(first.from, editEndOf(source, last)), text: docText(lines, indent, newline) }
			]
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
		return anchors.foreach(
			other -> !(other.from > self.to && other.from < stop && other.owner == self.owner && other.kind == self.kind)
		);
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
			final previous: Int = SourceText.startOfLine(source, at - 1);
			if (source.substring(previous, at - 1).trim() == '') break;
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
			if (source.substring(at, end).trim() == '') break;
			if (newline < 0) return source.length;
			at = newline + 1;
		}
		return at;
	}

	/**
	 * A comment token's text — the body past `//`, one following space removed — or null
	 * when a per-line content gate declines it: a `///` section label (gate 8), a body
	 * carrying the block-comment closer (which would end the doc mid-text and leave the
	 * tail as code), or anything `CommentProse.declines` rejects (gates 5-7). Shared by the two comment
	 * sources, which apply the same per-line gates to a run's lines and to a trailing tail.
	 */
	private static function gatedText(source: String, tok: CommentTok): Null<String> {
		if (source.substring(tok.from, tok.from + LABEL_MARKER.length) == LABEL_MARKER) return null;
		final text: String = commentText(source, tok);
		return text.indexOf(BLOCK_CLOSE) >= 0 || CommentProse.declines(text.trim()) ? null : text;
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
		final body: String = source.substring(tok.from + CommentProse.LINE_MARKER.length, tok.to).rtrim();
		return body.length > 0 && body.fastCodeAt(0) == ' '.code ? body.substr(1) : body;
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
				record(source, runStart >= 0 ? runStart : span.from, span.from, span.to, child.kind, owner, out);
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

	/**
	 * Keep the declaration under its line start, unless a further-left anchor on that line is already indexed, and
	 * tally how many declarations start on that line — a trailing comment on a line holding two has no single owner.
	 */
	private static function record(
		source: String, from: Int, declFrom: Int, to: Int, kind: String, owner: Span, out: Map<Int, Anchor>
	): Void {
		final line: Int = SourceText.startOfLine(source, from);
		final known: Null<Anchor> = out[line];
		if (known == null) {
			out[line] = {
				from: from,
				declFrom: declFrom,
				to: to,
				kind: kind,
				owner: owner.from,
				ownerEnd: owner.to,
				count: 1
			};
			return;
		}
		known.count++;
		if (known.from <= from) return;
		known.from = from;
		known.declFrom = declFrom;
		known.to = to;
		known.kind = kind;
		known.owner = owner.from;
		known.ownerEnd = owner.to;
	}

	/**
	 * The anchors re-keyed by the DECLARATION's own line rather than the anchor's. The two part when an `@:meta` /
	 * modifier run precedes the declaration on earlier lines: a trailing comment sits on the declaration's line, while
	 * the doc still belongs at the anchor, above the run. Keeps the leftmost declaration per line, as `record` does.
	 */
	private static function declLineIndex(source: String, anchors: Map<Int, Anchor>): Map<Int, Anchor> {
		final out: Map<Int, Anchor> = [];
		for (anchor in anchors) {
			final line: Int = SourceText.startOfLine(source, anchor.declFrom);
			final known: Null<Anchor> = out[line];
			if (known == null || known.declFrom > anchor.declFrom) out[line] = anchor;
		}
		return out;
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

/**
 * One convertible comment: the span to REPORT, and the edits that convert it. An above-line run rewrites in place
 * (one edit); a trailing decl comment RELOCATES (two — the tail is cut, the doc is inserted at the decl's anchor).
 */
private typedef DocCommentRewrite = { comment: Span, edits: Array<{ span: Span, text: String }> };

/**
 * A declaration's doc anchor (the start of its leading `@:meta` / modifier run), the declaration's own end, its node
 * kind, and the span of the declaration ENCLOSING it — `owner` is `-1` at module level. The owner is what makes two
 * anchors siblings; indent cannot, because two types in one module hold their members at the same depth. `count` is
 * how many declarations start on the anchor's line: above one, a trailing comment there has no single owner.
 * `declFrom` is the declaration's OWN start, which parts from `from` exactly when an `@:meta` / modifier run precedes
 * it — the trailing mechanism keys on the declaration's line, the above-run mechanism on the anchor's.
 */
private typedef Anchor = {
	from: Int,
	declFrom: Int,
	to: Int,
	kind: String,
	owner: Int,
	ownerEnd: Int,
	count: Int
};

/** Resolved kind-sets the anchor walk threads through its recursion. */
private typedef Seams = {
	final decls: Array<String>;
	final modifiers: Array<String>;
};
