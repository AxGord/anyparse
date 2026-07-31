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
 * One convertible block comment: the span to REPORT (the comment token), the span to
 * REPLACE (the token plus any trailing whitespace up to the line end) and the line-comment
 * text that replaces it.
 */
typedef LineCommentRewrite = { comment: Span, edit: Span, text: String };

/**
 * The node kinds a rewrite is decided against: `blocks` hold statements directly (the
 * statement-position gate), `localFns` declare a local function (a `/**` block above one
 * is a real doc and is left alone).
 */
typedef LineCommentKinds = { blocks: Array<String>, localFns: Array<String> };

/**
 * Flags a block comment sitting in a STATEMENT position inside a function body — prose
 * that reads as a line comment, written with block delimiters. `Info`; `--fix` rewrites
 * it to `//` line comments. A pure trivia edit: a comment never affects compilation, and
 * the rewrite preserves every line's own text.
 *
 * ## Detection
 *
 * A comment-token scan (`RefactorSupport.collectCommentTokens`, string-aware — a `/*`
 * inside a STRING literal is never visited) crossed with the parse tree. A block comment
 * qualifies only as one of three positive shapes:
 *
 *  1. a WHOLE-LINE block — it opens its own line and closes it;
 *  2. a TRAILING block — code before it, nothing but whitespace after its close
 *     (`g(); /* why *\/` -> `g(); // why`);
 *  3. a MULTI-LINE block whose delimiters own their lines.
 *
 * Every shape additionally needs the STATEMENT-POSITION gate: the innermost node
 * enclosing the token must be a statement block (`RefShape.blockBodyKind` /
 * `blockStmtKind`). That gate is what keeps a DECLARATION's doc out of scope (its
 * enclosing node is the type body, not a block) and what rejects a comment nested in an
 * EXPRESSION — `foo(a, /* x *\/` with the `b);` on the next line passes every textual
 * test, yet converting it would let the writer re-join the operand onto the commented-out
 * line.
 *
 * Two shapes are deliberately ceded: a content-free comment (only whitespace and stars)
 * belongs to `empty-comment`, whose fix DELETES rather than converts; and a `/**` block
 * immediately above a LOCAL FUNCTION declaration is a real doc for that function — the
 * in-body analogue of the member doc the statement-position gate already excludes.
 *
 * ## Fix
 *
 * Each body line becomes `// <text>`: the delimiters (including a `/***` / `**\/` star
 * run) are stripped, the block's own indent is re-emitted before each continuation line,
 * and the body's COMMON leading whitespace is removed so its relative indentation
 * survives. The CLOSING line is excluded from that common prefix — it carries the wrap's
 * structural indent, not the body's — mirroring `BlockCommentNormalizer.normalize`. A
 * leading `*` is CONTENT unless the block is javadoc-STYLED (three or more lines whose
 * every non-blank interior line opens with `*`, the same predicate the writer uses), so
 * the single-line `/* * 2 *\/` keeps its star and a gutter block loses its column.
 *
 * DEFAULT OFF (`DefaultOff`): block-vs-line comment style is a project convention, not a
 * defect. Opt in with `"rules": { "prefer-line-comment": { "enabled": true } }`.
 *
 * ## Grammar-agnostic
 *
 * The statement-block kinds come from `RefShape.blockBodyKind` / `blockStmtKind`; with
 * neither set the check is a no-op. The local-function kinds come from
 * `RefShape.localFunctionKinds` / `inlineFunctionKinds`; with neither set no doc is
 * spared.
 */
@:nullSafety(Strict)
final class PreferLineComment implements Check implements DefaultOff {

	public function new() {}

	public function id(): String {
		return 'prefer-line-comment';
	}

	public function description(): String {
		return 'a block comment in a statement position, replaceable with a line comment';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final kinds: LineCommentKinds = decisionKinds(plugin.refShape());
		return kinds.blocks.length == 0 ? [] : [
			for (entry in files) for (rewrite in rewrites(entry.source, plugin, kinds))
				{
					file: entry.file,
					span: rewrite.comment,
					rule: 'prefer-line-comment',
					severity: Severity.Info,
					message: 'block comment in a statement position; use a line comment'
				}
		];
	}

	/** Rewrite each flagged block comment to line comments. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final kinds: LineCommentKinds = decisionKinds(plugin.refShape());
		if (kinds.blocks.length == 0) return [];
		final flagged: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(span.from);
		}
		return [
			for (rewrite in rewrites(source, plugin, kinds)) if (flagged.contains(rewrite.comment.from))
				{ span: rewrite.edit, text: rewrite.text }
		];
	}

	/** The block and local-function node kinds the gates are decided against. */
	private static function decisionKinds(shape: RefShape): LineCommentKinds {
		final blocks: Array<String> = [];
		final bodyKind: Null<String> = shape.blockBodyKind;
		final stmtKind: Null<String> = shape.blockStmtKind;
		if (bodyKind != null) blocks.push(bodyKind);
		if (stmtKind != null) blocks.push(stmtKind);
		return { blocks: blocks, localFns: (shape.localFunctionKinds ?? []).concat(shape.inlineFunctionKinds ?? []) };
	}

	/** Every convertible block comment in `source`, in source order. */
	private static function rewrites(source: String, plugin: GrammarPlugin, kinds: LineCommentKinds): Array<LineCommentRewrite> {
		final comments: Array<CommentTok> = RefactorSupport.collectCommentTokens(source);
		final blocks: Array<CommentTok> = [for (tok in comments) if (!tok.isLine) tok];
		if (blocks.length == 0) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final out: Array<LineCommentRewrite> = [];
		for (tok in blocks) {
			final rewrite: Null<LineCommentRewrite> = rewriteOf(source, tok);
			if (rewrite == null) continue;
			final host: Null<String> = innermostKind(tree, tok.from, tok.to, null);
			if (host != null && kinds.blocks.contains(host) && !documentsLocalFunction(source, tree, tok, kinds.localFns))
				out.push(rewrite);
		}
		return out;
	}

	/**
	 * The rewrite for the block comment `tok`, or null when it fails a gate: unclosed,
	 * code after the closing delimiter, a multi-line block that does not open its own
	 * line, or a content-free body (`empty-comment`'s job).
	 */
	private static function rewriteOf(source: String, tok: CommentTok): Null<LineCommentRewrite> {
		if (tok.to - tok.from < 4 || source.substring(tok.to - 2, tok.to) != '*/') return null; // noqa: magic-number
		final lineEnd: Int = lineEndOf(source, tok.to);
		if (StringTools.trim(source.substring(tok.to, lineEnd)) != '') return null;
		final indent: String = source.substring(lineStartOf(source, tok.from), tok.from);
		final raw: String = source.substring(tok.from, tok.to);
		final multiline: Bool = raw.indexOf('\n') >= 0;
		if (multiline && StringTools.trim(indent) != '') return null;
		final lines: Array<String> = bodyLines(source.substring(bodyStartOf(source, tok), bodyEndOf(source, tok)));
		if (lines.length == 0 || contentFree(lines)) return null;
		final newline: String = raw.indexOf('\r\n') >= 0 ? '\r\n' : '\n';
		final text: String = [for (line in lines) line == '' ? '//' : '// $line'].join('$newline$indent');
		return { comment: new Span(tok.from, tok.to), edit: new Span(tok.from, lineEnd), text: text };
	}

	/**
	 * The comment body split into the lines a `//` prefix is written onto. The first line
	 * shares the opening delimiter's line, so it carries no indentation of its own and is
	 * simply trimmed; every later line is dedented by the body's COMMON leading whitespace,
	 * which keeps their relative indentation. A BLANK line contributes no indent, which is
	 * what keeps a bare `*\/` closing line — whose whitespace is the wrap's structural
	 * indent, not the body's — from skewing the prefix; a close that carries content
	 * (`}*\/`) is body and does participate. Blank edge lines drop out, so a body that
	 * opens or closes on a bare delimiter line yields no empty `//`.
	 */
	private static function bodyLines(body: String): Array<String> {
		final raw: Array<String> = [for (line in body.split('\n')) StringTools.rtrim(line)];
		if (raw.length == 1) {
			final only: String = StringTools.trim(raw[0]);
			return only == '' ? [] : [only];
		}
		final gutter: Bool = javadocStyled(raw);
		final dedent: String = commonIndent(raw.slice(1));
		final lines: Array<String> = [StringTools.trim(raw[0])];
		for (i in 1...raw.length) lines.push(stripGutter(StringTools.rtrim(dedented(raw[i], dedent)), gutter));
		return RefactorSupport.trimBlankEdges(lines);
	}

	/**
	 * Whether the body carries a per-line ` * ` gutter: three or more lines whose every
	 * non-blank INTERIOR line opens with a star. Mirrors the writer's own
	 * `BlockCommentNormalizer.isJavadocStyle`, and by requiring interior lines it never
	 * misreads a single-line `/* * 2 *\/`, whose star is content.
	 */
	private static function javadocStyled(lines: Array<String>): Bool {
		if (lines.length < 3) return false; // noqa: magic-number
		var content: Int = 0;
		var starred: Int = 0;
		for (i in 1...lines.length - 1) {
			final trimmed: String = StringTools.ltrim(lines[i]);
			if (trimmed == '') continue;
			content++;
			if (StringTools.startsWith(trimmed, '*')) starred++;
		}
		return content > 0 && starred == content;
	}

	/** Whether every body line is whitespace and stars — `empty-comment`'s shape, not this rule's. */
	private static function contentFree(lines: Array<String>): Bool {
		for (line in lines) for (i in 0...line.length) {
			final c: Int = StringTools.fastCodeAt(line, i);
			if (c != '*'.code && c != ' '.code && c != '\t'.code && c != '\r'.code) return false;
		}
		return true;
	}

	/**
	 * Whether `tok` is a `/**` doc for a LOCAL FUNCTION declared right after it — the
	 * in-body analogue of a member doc, which reads as documentation and so is not
	 * converted. A plain `/*` block above a local function is prose and still converts.
	 */
	private static function documentsLocalFunction(source: String, tree: QueryNode, tok: CommentTok, localFns: Array<String>): Bool {
		if (localFns.length == 0 || source.substring(tok.from, tok.from + 3) != '/**') return false; // noqa: magic-number
		return startsNodeOfKind(tree, RefactorSupport.skipForwardTrivia(source, tok.to), localFns);
	}

	/** Whether any node of one of `kinds` starts exactly at `offset`. */
	private static function startsNodeOfKind(node: QueryNode, offset: Int, kinds: Array<String>): Bool {
		final span: Null<Span> = node.span;
		if (span != null && span.from == offset && kinds.contains(node.kind)) return true;
		for (child in node.children) if (startsNodeOfKind(child, offset, kinds)) return true;
		return false;
	}

	/** The offset the comment body starts at — past `/*` and any further stars of a `/***` open. */
	private static function bodyStartOf(source: String, tok: CommentTok): Int {
		final end: Int = tok.to - 2; // noqa: magic-number
		var i: Int = tok.from + 2; // noqa: magic-number
		while (i < end && StringTools.fastCodeAt(source, i) == '*'.code) i++;
		return i;
	}

	/** The offset the comment body ends at — before `*\/` and any further stars of a `**\/` close. */
	private static function bodyEndOf(source: String, tok: CommentTok): Int {
		final start: Int = bodyStartOf(source, tok);
		var i: Int = tok.to - 2; // noqa: magic-number
		while (i > start && StringTools.fastCodeAt(source, i - 1) == '*'.code) i--;
		return i;
	}

	/** The longest leading-whitespace prefix shared by every non-blank line of `lines`. */
	private static function commonIndent(lines: Array<String>): String {
		var common: Null<String> = null;
		for (line in lines) if (StringTools.rtrim(line) != '') {
			final seen: Null<String> = common;
			final lead: String = leadingWhitespace(line);
			common = seen == null ? lead : sharedPrefix(seen, lead);
		}
		return common ?? '';
	}

	/** `line` with `dedent` removed from its front; a line that does not carry it (a blank one) is unchanged. */
	private static inline function dedented(line: String, dedent: String): String {
		return StringTools.startsWith(line, dedent) ? line.substr(dedent.length) : line;
	}

	/** A gutter block's ` * ` line marker stripped; elsewhere a leading star is content and stays. */
	private static inline function stripGutter(line: String, gutter: Bool): String {
		return !gutter || !StringTools.startsWith(line, '*')
			? line
			: StringTools.startsWith(line, '* ') ? line.substr(2) : line.substr(1); // noqa: magic-number
	}

	/** `line`'s leading spaces and tabs. */
	private static function leadingWhitespace(line: String): String {
		var i: Int = 0;
		while (i < line.length) {
			final c: Int = StringTools.fastCodeAt(line, i);
			if (c != ' '.code && c != '\t'.code) break;
			i++;
		}
		return line.substr(0, i);
	}

	/** The longest common prefix of `a` and `b`. */
	private static function sharedPrefix(a: String, b: String): String {
		final limit: Int = a.length < b.length ? a.length : b.length;
		var i: Int = 0;
		while (i < limit && StringTools.fastCodeAt(a, i) == StringTools.fastCodeAt(b, i)) i++;
		return a.substr(0, i);
	}

	/**
	 * The kind of the innermost node whose span encloses `[from, to)`, or `fallback` when
	 * no child does. A node with no span is looked THROUGH (a bare name atom projects
	 * without one) rather than treated as a container.
	 */
	private static function innermostKind(node: QueryNode, from: Int, to: Int, fallback: Null<String>): Null<String> {
		for (child in node.children) {
			final span: Null<Span> = child.span;
			if (span == null) {
				final deeper: Null<String> = innermostKind(child, from, to, null);
				if (deeper != null) return deeper;
			} else if (span.from <= from && span.to >= to)
				return innermostKind(child, from, to, child.kind);
		}
		return fallback;
	}

	/** The offset just after the newline preceding `at` (the start of its physical line). */
	private static function lineStartOf(source: String, at: Int): Int {
		var i: Int = at;
		while (i > 0 && StringTools.fastCodeAt(source, i - 1) != '\n'.code) i--;
		return i;
	}

	/** The offset of the line terminator ending `at`'s physical line (before a `\r\n` CR), or the source end. */
	private static function lineEndOf(source: String, at: Int): Int {
		var i: Int = at;
		while (i < source.length && StringTools.fastCodeAt(source, i) != '\n'.code) i++;
		return i > at && StringTools.fastCodeAt(source, i - 1) == '\r'.code ? i - 1 : i;
	}

}
