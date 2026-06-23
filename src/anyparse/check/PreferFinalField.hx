package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a private `var` field whose initializer is its only assignment — a
 * mutable field the immutable `final` should replace — and rewrites `var` to
 * `final`. `Severity.Info` (a modernization cleanup toward immutability), with an
 * autofix. Structurally a sibling of `unused-private`: same confinement gate, same
 * conservative in-file scan.
 *
 * ## Soundness — why a missed write is impossible
 *
 * A false negative (a wrong `final` the compiler rejects) is the dangerous
 * direction, so the candidate must be PROVABLY single-assignment:
 *
 * 1. The field has a declaration initializer (one assignment).
 * 2. It is private and its enclosing type is confined to its file
 *    (`RefactorSupport.isPrivateMemberConfined`) — so every possible write lives
 *    in this file. A non-default visibility (public) is excluded: a public field
 *    is writable from another file regardless of confinement.
 * 3. No other write to the field name appears in the file. The scan is a
 *    conservative, COMPLETE text scan — it treats the name followed by any
 *    assignment operator (`=`, `+=`, … but not `==` / `<=` / `!=` / `=>`) or
 *    adjacent to `++` / `--` as a write, matching `this.x = …`, `obj.x = …`,
 *    `x++`, and `++x` alike, and skips whitespace AND interposed comments between
 *    the name and the operator (a write whose name is separated from `=` by a
 *    comment is still detected). It over-counts (a same-named local, or the name in
 *    a comment / string, reads as a write) which only ever KEEPS a `var`, never
 *    produces a wrong `final`.
 *
 * Together these prove the initializer is the sole assignment, so `var → final` is
 * always sound.
 *
 * ## Whole-project scope required
 *
 * Confinement is only sound when the lint scope contains EVERY file that can
 * reference the type — `isPrivateMemberConfined` can only rule out a cross-file
 * `@:access` / subtype writer it can SEE in the index. Run over a single file in
 * isolation, an external writer is invisible and the field would be wrongly flagged.
 * This is the same limitation `unused-private` carries; like it, this check is
 * registered as a full-scope check in the `--fix` loop, and the sound usage is
 * linting the whole project (`lint src/`).
 *
 * ## Initializer required; properties skipped
 *
 * A no-initializer field (`final` would need a definite-assignment proof across
 * the constructor this check does not attempt) is skipped, as is a property
 * (`var x(get, set)`) — detected by a `(` in the declaration head — whose accessor
 * machinery `final` does not fit.
 */
@:nullSafety(Strict)
final class PreferFinalField implements Check {

	public function new() {}

	public function id(): String {
		return 'prefer-final-field';
	}

	public function description(): String {
		return 'a private var field assigned only at its declaration that can be final';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final violations: Array<Violation> = [];
		RefactorSupport.eachFieldMember(files, plugin, (owner, field, source, file, exported) -> {
			if (!exported)
				considerField(violations, file, source, field, owner, index);
		});
		return violations;
	}

	/**
	 * Rewrite each flagged field's `var` keyword to `final`. The candidate is by
	 * construction assigned only at its declaration, so the swap is always safe; the
	 * edit fires only when the bytes at the declaration start are literally the
	 * keyword (`substring` clamps, so an unexpected span simply fails the equality).
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return RefactorSupport.varKeywordToFinalEdits(source, [for (v in violations) v.span]);
	}

	/**
	 * Flag `field` when it has an initializer, is not a property, its type is
	 * confined, and no other write to its name appears in the file.
	 */
	private static function considerField(
		out: Array<Violation>, file: String, source: String, field: QueryNode, owner: String, index: SymbolIndex
	): Void {
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		if (name == null || span == null) return;
		if (!RefactorSupport.isInitializedNonPropertyField(source, field)) return;
		if (!RefactorSupport.isPrivateMemberConfined(owner, source, index)) return;
		if (writtenInFile(source, name, span)) return;
		out.push({
			file: file,
			span: span,
			rule: 'prefer-final-field',
			severity: Severity.Info,
			message: 'field \'$name\' is assigned only at its declaration; use final'
		});
	}

	/**
	 * Whether `name` is written anywhere in `source` outside `exclude` (its own
	 * declaration). A write is a word-boundary occurrence of `name` followed (past
	 * whitespace and comments) by an assignment operator or adjacent to `++` / `--`.
	 * Conservative and complete: it over-counts toward "written", which only keeps a
	 * `var`.
	 */
	private static function writtenInFile(source: String, name: String, exclude: Span): Bool {
		final n: Int = source.length;
		final len: Int = name.length;
		if (len == 0) return false;
		var from: Int = 0;
		while (true) {
			final idx: Int = source.indexOf(name, from);
			if (idx < 0) return false;
			from = idx + len;
			final boundedBefore: Bool = idx == 0 || !isWordChar(StringTools.fastCodeAt(source, idx - 1));
			final boundedAfter: Bool = from >= n || !isWordChar(StringTools.fastCodeAt(source, from));
			if (!boundedBefore || !boundedAfter) continue;
			if (idx >= exclude.from && idx < exclude.to) continue;
			if (precededByIncrDecr(source, idx) || followedByAssign(source, from)) return true;
		}
	}

	/** Whether the non-whitespace token immediately before `idx` is `++` or `--`. */
	/**
	 * Whether the non-whitespace token immediately before `idx`, skipping any
	 * interposed block comment, is `++` or `--` (a prefix increment / decrement —
	 * a write). Symmetric with `followedByAssign`'s comment-skipping so a write
	 * with a comment between the operator and the name is not missed.
	 */
	private static function precededByIncrDecr(source: String, idx: Int): Bool {
		var i: Int = idx - 1;
		while (i >= 0) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (isSpace(c)) {
				i--;
				continue;
			}
			if (c == '/'.code && i >= 1 && StringTools.fastCodeAt(source, i - 1) == '*'.code) {
				i -= 2;
				while (i >= 1 && !(
					StringTools.fastCodeAt(source, i - 1) == '/'.code && StringTools.fastCodeAt(source, i) == '*'.code
				)) i--;
				i -= 2;
				continue;
			}
			break;
		}
		if (i < 1) return false;
		final c0: Int = StringTools.fastCodeAt(source, i - 1);
		final c1: Int = StringTools.fastCodeAt(source, i);
		return (c0 == '+'.code && c1 == '+'.code) || (c0 == '-'.code && c1 == '-'.code);
	}

	/**
	 * Whether the operator token starting (past whitespace and comments) at `pos` is
	 * an assignment: `++` / `--`, or an operator run ending in `=` that is not a
	 * comparison (`==` / `<=` / `>=` / `!=`) or the lambda arrow (`=>`).
	 */
	private static function followedByAssign(source: String, pos: Int): Bool {
		final n: Int = source.length;
		var i: Int = skipTrivia(source, pos);
		final start: Int = i;
		while (i < n && isOperatorChar(StringTools.fastCodeAt(source, i))) i++;
		final token: String = source.substring(start, i);
		return token == '++' || token == '--'
			|| (token.length != 0 && StringTools.fastCodeAt(token, token.length - 1) == '='.code && token != '==' && token != '<='
				&& token != '>=' && token != '!=' && token != '=>');
	}

	/** Index of the first byte at or after `pos` that is neither whitespace nor inside a line or block comment. */
	private static function skipTrivia(source: String, pos: Int): Int {
		final n: Int = source.length;
		var i: Int = pos;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (isSpace(c)) {
				i++;
				continue;
			}
			if (c == '/'.code && i + 1 < n) {
				final c1: Int = StringTools.fastCodeAt(source, i + 1);
				if (c1 == '/'.code) {
					i += 2;
					while (i < n && StringTools.fastCodeAt(source, i) != '\n'.code) i++;
					continue;
				}
				if (c1 == '*'.code) {
					i += 2;
					while (i + 1 < n && !(
						StringTools.fastCodeAt(source, i) == '*'.code && StringTools.fastCodeAt(source, i + 1) == '/'.code
					)) i++;
					i += 2;
					continue;
				}
			}
			break;
		}
		return i;
	}

	/** Whether `c` is an identifier character (a word boundary is anything else). */
	private static function isWordChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code;
	}

	/** Whether `c` is an operator character that can form an assignment token. */
	private static function isOperatorChar(c: Int): Bool {
		return switch c {
			case '='.code | '+'.code | '-'.code | '*'.code | '/'.code | '%'.code | '&'.code | '|'.code | '^'.code | '<'.code | '>'.code
				| '?'.code
				| '~'.code
				| '!'.code: true;
			case _: false;
		};
	}

	/** Whether `c` is whitespace. */
	private static function isSpace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

}
