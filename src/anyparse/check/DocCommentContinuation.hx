package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.FragmentedDocComment.CommentTok;
import anyparse.query.GrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

/** One star-guttered block comment ready to judge: the continuation prefix its own lines
* agreed on, the indentation that prefix sits at, and its interior lines. */
private typedef GutteredBlock = {
	var prefix: String;
	var indent: String;
	var lines: Array<InteriorLine>;
}

/** One interior line of a block comment: its byte range in the source, and its text. */
private typedef InteriorLine = {
	var from: Int;
	var to: Int;
	var text: String;
}

/**
 * Flags an interior line of a STAR-GUTTERED block comment that breaks the block's own
 * continuation prefix — the line lost its ` * ` gutter and sits flush inside the block, or
 * carries the gutter at an indent the rest of the block does not use. `Warning`, with a fix
 * that restores the block's own prefix without touching what follows it.
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
 * The gate is POSITIVE and has three clauses, each of which cost a measured false-positive
 * class to find. The block must be closed, span at least two lines and start its own line;
 * its FIRST non-blank interior line must open with a gutter star — one followed by whitespace
 * or nothing, so `**BETA**` and `*emphasis*` do not qualify; and its lines must DISAGREE about
 * what that gutter is.
 *
 * Unanimity is what separates a corruption from a house style. A block whose every line
 * already starts with one prefix is left alone whatever indent it chose, because that is what
 * a deliberate style looks like and no splice produces it. Reading the first character alone
 * counted markdown bullets as gutters and reported 36 correct blocks across the 2624
 * Haxe-stdlib files, 254 in openfl and 77 in haxe-formatter — with a fix that DELETED the
 * bullet markers. Judging every block against its OPENER's indent instead of its own reported
 * 142 more, in openfl and lime, that simply gutter one level deeper than they open.
 *
 * Once a block DOES disagree with itself, the prefix to repair it onto sits at the OPENER's
 * indentation, in whichever of its two spellings — `<indent> * ` or the compact `<indent>* ` —
 * more of the block's own lines already use, ties going to the spaced form.
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
		return 'an interior line of a star-guttered block comment that breaks the block\'s continuation prefix';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		for (entry in files) scan(violations, entry.file, entry.source);
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
		for (tok in RefactorSupport.collectCommentTokens(source)) if (!tok.isLine) {
			final block: Null<GutteredBlock> = gutteredBlock(source, tok);
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
	private static function scan(out: Array<Violation>, file: String, source: String): Void {
		for (tok in RefactorSupport.collectCommentTokens(source)) if (!tok.isLine) {
			final block: Null<GutteredBlock> = gutteredBlock(source, tok);
			if (block == null) continue;
			for (line in block.lines) {
				final why: Null<String> = breakage(line.text, block.prefix);
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
	 * The block's continuation prefix and its interior lines, or null when the token is not
	 * a star-guttered multi-line block that starts its own line — see the class doc for why
	 * every clause is a positive requirement.
	 */
	private static function gutteredBlock(source: String, tok: CommentTok): Null<GutteredBlock> {
		if (!closed(source, tok) || !RefactorSupport.startsItsLine(source, tok.from)) return null;
		final indent: String = source.substring(lineStartOf(source, tok.from), tok.from);
		final lines: Array<InteriorLine> = interiorLines(source, tok);
		if (lines.length == 0) return null;
		final spaced: String = '$indent *';
		final compact: String = '$indent*';
		var opener: Null<String> = null;
		var spacedLines: Int = 0;
		var compactLines: Int = 0;
		for (line in lines) if (line.text.trim() != '') {
			if (opener == null) opener = line.text;
			if (line.text.startsWith(spaced))
				spacedLines++
			else if (line.text.startsWith(compact))
				compactLines++;
		}
		final head: Null<String> = opener;
		if (head == null) return null;
		// A GUTTER star is followed by whitespace or nothing. `**BETA**` and `*emphasis*` open a
		// gutter-less block's prose with a star that is not one, and reading only the first character
		// reported every line of 109 such blocks in one library.
		final star: Int = head.length - head.ltrim().length;
		if (head.fastCodeAt(star) != '*'.code || (star + 1 < head.length && !RefactorSupport.isSpace(head.fastCodeAt(star + 1))))
			return null;
		// UNANIMITY WINS. A block whose every line already agrees on one gutter is a house style,
		// whatever indent it chose — measured, that is the only shape openfl / lime / the `format`
		// library produce, and judging it against the OPENER's indent reported 142 correct blocks.
		// What this rule reports is a line disagreeing with its OWN block, which is what a splice
		// makes and a consistent style never does.
		final own: String = head.substring(0, star + 1);
		for (line in lines) if (line.text.trim() != '' && !line.text.startsWith(own)) return {
			prefix: compactLines > spacedLines ? compact : spaced,
			indent: indent,
			lines: lines
		};
		return null;
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

	/** Why `line` breaks `prefix`, or null when it is blank or well-formed. */
	private static function breakage(line: String, prefix: String): Null<String> {
		return if (line.trim() == '' || line.startsWith(prefix))
			null
		else if (line.ltrim().fastCodeAt(0) == '*'.code)
			'doc-comment continuation line carries its ` * ` gutter at a different indent than its block'
		else
			'doc-comment continuation line lost its ` * ` gutter';
	}

	/** `line` rewritten onto `prefix`: a wrong indent corrected, a missing gutter restored, a doubled one collapsed. */
	private static function repaired(line: String, block: GutteredBlock): String {
		final prefix: String = block.prefix;
		final carriage: String = line.endsWith('\r') ? '\r' : '';
		final body: String = line.substring(0, line.length - carriage.length);
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
