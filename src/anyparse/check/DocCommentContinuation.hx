package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.FragmentedDocComment.CommentTok;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.SourceComments;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/** One block comment ready to judge: the continuation prefix its own lines agreed on, whether
* that prefix carries a gutter star, the indentation the block opens at, and its interior lines. */
private typedef JudgedBlock = {
	var prefix: String;
	var indent: String;
	var gutter: Bool;
	var lines: Array<InteriorLine>;
}

/** One interior line of a block comment: its byte range in the source, and its text. */
private typedef InteriorLine = {
	var from: Int;
	var to: Int;
	var text: String;
}

/**
 * Flags an interior line of a block comment that breaks the continuation prefix its own block uses.
 * A STAR-GUTTERED block is judged against its gutter — the line lost its ` * ` and sits flush inside
 * the block, or carries the gutter at an indent the rest of the block does not use. A GUTTER-LESS one
 * (the `/**` … `**\/` spelling, a commented-out block of code) is judged against its INDENTATION,
 * which is the whole prefix it has. `Warning` either way, with a fix that restores the
 * block's own prefix without touching what follows it.
 *
 * ## Why this rule exists at all
 *
 * It is the only channel in this project that can see the class. The writer re-emits a
 * comment INTERIOR byte for byte, so a corrupted doc block is writer-canonical and
 * `apq fmt --list` reports nothing; comments are trivia and never reach the parse tree,
 * so every node-based rule is blind to them as well. Measured on this repository at the
 * time the rule landed: a doc block corrupted months earlier sat committed in
 * `test/unit/UnusedLocalShadowTest.hx` — one line at a doubled indent, three flush left
 * inside the block — with `fmt --list` clean and the whole builtin rule set silent on it.
 * It was found by a human reading a diff, which is not a gate.
 *
 * The corruption is produced by the ops that SPLICE text into a comment. `set-doc` owns
 * the gutter and adds it, so a caller who supplies their own gets ` * ` twice;
 * `comment-rewrite` splices its replacement raw, so a real newline in it starts a line
 * with no gutter at all, and the writer then re-bases the whole run onto the shallowest
 * line — which is why ONE unguttered line pushes every guttered sibling one level deeper.
 * Both ops now correct their own input, and this rule is what proves they did.
 *
 * ## Detection
 *
 * A pure comment-token scan (no parse needed) over `RefactorSupport.collectCommentTokens`,
 * which is string-aware — a `/*` inside a STRING literal is never visited.
 *
 * The gate is POSITIVE and every clause cost a measured false-positive class to find. The block
 * must be closed, span at least two lines and start its own line; its FIRST non-blank interior line
 * decides WHICH prefix the block is judged against — a gutter star (one followed by whitespace or
 * nothing, so `**BETA**` and `*emphasis*` do not qualify) or, failing that, the line's own
 * indentation; and its lines must DISAGREE about that prefix.
 *
 * Unanimity is what separates a corruption from a house style. A block whose every line
 * already starts with one prefix is left alone whatever indent it chose, because that is what
 * a deliberate style looks like and no splice produces it. Reading the first character alone
 * counted markdown bullets as gutters and reported 36 correct blocks across the 2624
 * Haxe-stdlib files, 254 in openfl and 77 in haxe-formatter — with a fix that DELETED the
 * bullet markers. Judging every block against its OPENER's indent instead of its own reported
 * 142 more, in openfl and lime, that simply gutter one level deeper than they open.
 *
 * Once a block DOES disagree with itself, a guttered one repairs onto the OPENER's indentation, in
 * whichever of its two spellings — `<indent> * ` or the compact `<indent>* ` — more of the block's
 * own lines already use, ties going to the spaced form. A gutter-less one repairs onto the
 * indentation its first interior line chose, which for the stdlib spelling is one level deeper than
 * the delimiters — the exact level `comment-rewrite` used to miss.
 *
 * Every non-blank interior line that does not start with that prefix then reports — it lost
 * the gutter, or carries it at another indent. A line indented DEEPER than the prefix still
 * STARTS with it, so a fenced code block inside a doc is untouched.
 *
 * There is deliberately no DOUBLED-gutter arm. The ` *  * ` shape a caller-supplied ` * ` used
 * to produce has no live producer left (`RefactorSupport.ungutter` strips it at the source),
 * and every textual test for it that was tried also matched a nested markdown bullet — over
 * this tree and 679 Pony files the pattern matched exactly two lines and both were bullets in
 * `CollapsePass.hx`.
 *
 * ## Fix
 *
 * Each flagged line is rewritten onto the block's prefix, keeping its content byte for byte:
 * a line that still has a star keeps everything from the star on, and a line that lost it
 * keeps whatever indentation it carried BEYOND the block's own, so a code sample indented
 * inside a doc survives. A trailing `\r` rides along, so a CRLF file does not gain one bare-LF
 * line. The edits are the raw line replacements the caller batches into one
 * `RefactorSupport.canonicalize` per file.
 */
@:nullSafety(Strict)
final class DocCommentContinuation implements Check {

	/** The shortest closed block comment, `/**\/` — below that length there is no separate closer to read. */
	private static inline final SHORTEST_CLOSED_BLOCK: Int = 4;

	public function new() {}

	public function id(): String {
		return 'doc-comment-continuation';
	}

	public function description(): String {
		return 'an interior line of a block comment that breaks the continuation prefix — gutter or indentation — its own block uses';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		for (entry in files) scan(violations, entry.file, entry.source, plugin.lexicalRegions(entry.source));
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final flagged: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(span.from);
		}
		// ONE lexical pass for the whole file, not one per finding: `fix` is handed every violation
		// of this rule in the file at once, and a 77-finding block comment paid 77 full re-lexes.
		final edits: Array<{ span: Span, text: String }> = [];
		for (tok in SourceComments.collectCommentTokens(plugin.lexicalRegions(source))) if (!tok.isLine) {
			final block: Null<JudgedBlock> = judgedBlock(source, tok);
			if (block == null) continue;
			for (line in block.lines) if (flagged.contains(line.from))
				edits.push({ span: new Span(line.from, line.to), text: repaired(line.text, block) });
		}
		return edits;
	}

	/** Whether the block comment token is closed by `*\/` — an unterminated one has no interior to judge. */
	private static inline function closed(source: String, tok: CommentTok): Bool {
		return tok.to >= tok.from + SHORTEST_CLOSED_BLOCK && source.fastCodeAt(tok.to - 2) == '*'.code
			&& source.fastCodeAt(tok.to - 1) == '/'.code;
	}

	/** The offset of the start of the line holding `at`. */
	private static inline function lineStartOf(source: String, at: Int): Int {
		final nl: Int = source.lastIndexOf('\n', at);
		return nl < 0 ? 0 : nl + 1;
	}

	/** Scan every block comment in `source`, flagging each interior line that breaks the block's prefix. */
	private static function scan(out: Array<Violation>, file: String, source: String, regions: Array<LexRegion>): Void {
		for (tok in SourceComments.collectCommentTokens(regions)) if (!tok.isLine) {
			final block: Null<JudgedBlock> = judgedBlock(source, tok);
			if (block == null) continue;
			for (line in block.lines) {
				final why: Null<String> = breakage(line.text, block);
				if (why == null) continue;
				final reason: String = why;
				out.push({
					file: file,
					span: new Span(line.from, line.to),
					rule: 'doc-comment-continuation',
					severity: Severity.Warning,
					message: reason
				});
			}
		}
	}

	/**
	 * The block's continuation prefix and its interior lines, or null when the token is not a multi-line
	 * block that starts its own line, when a STAR-GUTTERED block's lines already agree, or when a
	 * GUTTER-LESS one is a plain `/*` or has nothing to say. Which arm judges it is decided here and
	 * nowhere else, off the first non-blank interior line.
	 */
	private static function judgedBlock(source: String, tok: CommentTok): Null<JudgedBlock> {
		if (!closed(source, tok) || !SourceText.startsItsLine(source, tok.from)) return null;
		final indent: String = source.substring(lineStartOf(source, tok.from), tok.from);
		final lines: Array<InteriorLine> = interiorLines(source, tok);
		if (lines.length == 0) return null;
		final opener: Null<InteriorLine> = lines.find(line -> line.text.trim() != '');
		if (opener == null) return null;
		final head: String = opener.text;
		// The gutter-star discriminator is `RefactorSupport`'s, shared with the splice that writes the
		// prefix this rule reports against — the one predicate of the pair that must not drift.
		final star: Int = SourceComments.gutterStarAt(head);
		// A `/*` block is commented-out code or a banner, where indentation is CONTENT — the stdlib
		// keeps a whole C# method inside one, at four different levels. Only a `/**` doc block is
		// judged by its indentation.
		return if (star >= 0)
			starGuttered(indent, head, star, lines)
		else if (source.fastCodeAt(tok.from + 2) == '*'.code)
			gutterless(indent, lines)
		else
			null;
	}

	/**
	 * A block whose first interior line opens with a gutter star, judged against THAT star: the
	 * prefix to repair onto sits at the opener's indentation, in whichever of its two spellings —
	 * `<indent> * ` or the compact `<indent>* ` — more of the block's own lines already use.
	 */
	private static function starGuttered(indent: String, head: String, star: Int, lines: Array<InteriorLine>): Null<JudgedBlock> {
		final spaced: String = '$indent *';
		final compact: String = '$indent*';
		var spacedLines: Int = 0;
		var compactLines: Int = 0;
		for (line in lines) if (line.text.trim() != '') {
			if (line.text.startsWith(spaced))
				spacedLines++
			else if (line.text.startsWith(compact))
				compactLines++;
		}
		// UNANIMITY WINS. A block whose every line already agrees on one gutter is a house style,
		// whatever indent it chose — measured, that is the only shape openfl / lime / the `format`
		// library produce, and judging it against the OPENER's indent reported 142 correct blocks.
		// What this rule reports is a line disagreeing with its OWN block, which is what a splice
		// makes and a consistent style never does.
		final own: String = head.substring(0, star + 1);
		for (line in lines) if (line.text.trim() != '' && !line.text.startsWith(own)) return {
			prefix: compactLines > spacedLines ? compact : spaced,
			indent: indent,
			gutter: true,
			lines: lines
		};
		return null;
	}

	/**
	 * A doc block with NO gutter star at all — the `/**` … `**\/` spelling the Haxe standard library
	 * uses. Its continuation prefix is pure INDENTATION, and what it reports is exactly the splice
	 * signature: the block indents its interior past its own delimiters, and ONE line sits at the
	 * delimiter indent instead, because that is what the splicer answered with.
	 *
	 * Judging such a block against its FIRST interior line's indentation the way the gutter arm
	 * judges a gutter reported 8 correct blocks across the 2624 Haxe-stdlib files, every one of them
	 * a first line whose leading spaces are PROSE padding (`\t  This function searches…` over a
	 * `\t`-indented sibling) or a tab-against-spaces mix. A gutter star anchors a prefix; bare
	 * indentation does not, so the anchor here is the block's own delimiter column.
	 *
	 * The prefix to repair onto is what the lines that DID indent share. A block written flush with
	 * its delimiters has no deeper line and says nothing; so does one whose lines share no indentation
	 * with their delimiters AT ALL — a space-indented interior under tab delimiters, or the reverse, has
	 * no "its own" prefix to be judged against. A line at or UNDER the delimiter indent is what the arm
	 * reports.
	 *
	 * BLIND ON CRLF, and the cause is not here: the block-comment re-base the writer applies treats a
	 * CRLF block differently from its byte-identical LF twin, shifting the whole interior one level, so
	 * after canonicalisation the corrupted line no longer sits at the delimiter indent and this arm has
	 * nothing to anchor on. `apq fmt --write` is what a caller must run before `--fix`, so there is no
	 * order in which the arm both fires and repairs a CRLF file. The star arm survives the same shift,
	 * which is the arm's own premise — a gutter star anchors a prefix, bare indentation does not — turned
	 * against it.
	 */
	private static function gutterless(indent: String, lines: Array<InteriorLine>): Null<JudgedBlock> {
		var deep: Null<String> = null;
		var first: Bool = true;
		for (line in lines) if (line.text.trim() != '') {
			final lead: String = line.text.substring(0, line.text.length - line.text.ltrim().length);
			// Three ways a line can relate to the block's own indentation. DEEPER is the block's text and
			// folds into the prefix; AT or SHALLOWER than the delimiters is a candidate to report — the
			// splice answers with the delimiter indent, and a hand edit or an older op can land shorter
			// still; UNRELATED (a space-indented interior under tab delimiters, and the reverse) shares no
			// prefix with the block at all, so there is no "its own" indentation to judge against.
			final shallow: Bool = indent.startsWith(lead);
			if (!shallow && !lead.startsWith(indent)) return null;
			// The block's OWN first interior line settles its style. One written flush with the
			// delimiters is a style — and it may still hold an indented sample, which would otherwise
			// make every flush line of it read as the line that fell away.
			if (shallow && first) return null;
			if (!shallow) deep = deep == null ? lead : commonPrefix(deep, lead);
			first = false;
		}
		final prefix: Null<String> = deep;
		// Unreachable, and here for null-safety alone: the first non-blank interior line either is
		// shallow (returned above) or becomes `deep`, and `judgedBlock` never calls this without one.
		// Two guards that read like siblings of it were NOT unreachable-but-harmless, they were
		// REDUNDANT — an `atDelimiter` flag, and a `prefix == indent` early-out — and each killed no
		// mutation, because with `prefix` the shared indentation of every DEEPER line, only a line at or
		// under the delimiter indent can fail to start with it.
		return prefix == null ? null : {
			prefix: prefix,
			indent: indent,
			gutter: false,
			lines: lines
		};
	}

	/** The longest prefix `a` and `b` share; every caller passes leading whitespace. */
	private static function commonPrefix(a: String, b: String): String {
		var i: Int = 0;
		while (i < a.length && i < b.length && a.fastCodeAt(i) == b.fastCodeAt(i)) i++;
		return a.substring(0, i);
	}

	/**
	 * The lines strictly BETWEEN the opener's line and the closer's line, each as its byte
	 * range and text. The opener line carries `/**` and the closer line carries `*\/`; both
	 * are the writer's own to place, so neither is this rule's business.
	 */
	private static function interiorLines(source: String, tok: CommentTok): Array<InteriorLine> {
		final closerStart: Int = lineStartOf(source, tok.to - 1);
		final out: Array<InteriorLine> = [];
		var from: Int = source.indexOf('\n', tok.from);
		if (from < 0) return out;
		from++;
		// Every line here ends before `closerStart`, which itself follows a newline, so `indexOf`
		// always finds one — no clamp is reachable.
		while (from < closerStart) {
			final to: Int = source.indexOf('\n', from);
			out.push({ from: from, to: to, text: source.substring(from, to) });
			from = to + 1;
		}
		return out;
	}

	/** Why `line` breaks its block's continuation prefix, or null when it is blank or well-formed. */
	private static function breakage(line: String, block: JudgedBlock): Null<String> {
		return if (line.trim() == '' || line.startsWith(block.prefix))
			null
		else if (!block.gutter)
			'doc-comment continuation line does not carry its block\'s own indentation'
		else if (line.ltrim().fastCodeAt(0) == '*'.code)
			'doc-comment continuation line carries its ` * ` gutter at a different indent than its block'
		else
			'doc-comment continuation line lost its ` * ` gutter';
	}

	/** `line` rewritten onto `prefix`: a wrong indent corrected, a missing gutter restored, a doubled one collapsed. */
	private static function repaired(line: String, block: JudgedBlock): String {
		final prefix: String = block.prefix;
		final carriage: String = line.endsWith('\r') ? '\r' : '';
		final body: String = line.substring(0, line.length - carriage.length);
		// A gutter-less block has no star to keep and nothing beyond its own indentation to preserve:
		// a flagged line is one that does NOT start with the block's indentation, so everything it
		// carries is content and the whole prefix is what it lost.
		if (!block.gutter) return prefix + body.ltrim() + carriage;
		// A line that still carries a star lost only its INDENT, so the star and everything after it
		// is content to keep verbatim. A line that lost the star kept whatever indentation the writer
		// left in front of it — drop the block's own indent from that and keep the rest, so a code
		// sample indented INSIDE the doc survives the repair.
		final starAt: Int = body.ltrim().fastCodeAt(0) == '*'.code ? body.length - body.ltrim().length + 1 : -1;
		final rest: String = if (starAt >= 0)
			body.substring(starAt)
		else if (body.startsWith(block.indent))
			body.substring(block.indent.length)
		else
			body.ltrim();
		return if (rest.trim() == '')
			prefix + carriage
		else if (rest.startsWith(' ') || rest.startsWith('\t'))
			'$prefix$rest$carriage'
		else
			'$prefix $rest$carriage';
	}

}
