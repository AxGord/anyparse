package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.FieldWriteIndex;
import anyparse.runtime.Span;

/**
 * Flags a PUBLIC `var` field written ONLY inside its declaring class — never from
 * another file — and rewrites it to `public var X(default, null)`, making it
 * externally read-only while staying internally mutable. `Severity.Info` (a
 * modernization cleanup toward immutability), with an autofix. The weaker sibling of
 * `prefer-final-public-field`: where that proves a field is NEVER reassigned (so
 * `final` fits), this one proves every reassignment is internal (so external write
 * access can be removed).
 *
 * ## Soundness — why a missed external write is impossible
 *
 * A false positive (a wrong `(default, null)` the compiler rejects at an external
 * write site) is the dangerous direction, so the candidate must be PROVABLY
 * internal-only:
 *
 * 1. Its enclosing type has NO subtype (`SymbolIndex.hasSubtype`) — a subtype's
 *    inherited write would misattribute, so the gate (with SymbolIndex.supertypeDeclaresMember, which also bails when a supertype declares the same field) rules it out.
 * 2. No write to the field NAME anywhere is unresolved
 *    (`FieldWriteIndex.hasUnresolvedWrite`) — an unresolved `recv.field = …` could be
 *    a hidden external write.
 * 3. The type is declared in exactly one file (`SymbolIndex.declarationSiteOf`) — an
 *    ambiguous simple name cannot pin the decl range, so it bails.
 * 4. No resolved write to the field lies outside that decl range
 *    (`FieldWriteIndex.writtenExternally`).
 *
 * ## Disjoint from `prefer-final-public-field`
 *
 * A candidate must be written somewhere (`FieldWriteIndex.writtenAnywhere`) — a field
 * with NO write is `prefer-final-public-field`'s territory (it can become `final`),
 * not this one. The two checks therefore never emit conflicting fixes for the same
 * field.
 *
 * ## Whole-project scope required
 *
 * Like `prefer-final-public-field` / `unused-private`, the write-index and subtype
 * gate are only sound when the lint scope contains every file referencing the type;
 * the sound usage is linting the whole project (`lint src/`).
 */
@:nullSafety(Strict)
final class PreferReadOnlyField implements Check {

	public function new() {}

	public function id(): String {
		return 'prefer-read-only-field';
	}

	public function description(): String {
		return 'a public var field written only inside its class that can be (default, null)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final writeIndex: FieldWriteIndex = FieldWriteIndex.build(files, plugin);
		final violations: Array<Violation> = [];
		RefactorSupport.eachFieldMember(files, plugin, (owner, field, source, file, exported) -> {
			if (exported)
				considerField(violations, file, source, field, owner, index, writeIndex);
		});
		return violations;
	}

	/**
	 * Insert `(default, null)` just after each flagged field's name. The candidate is by
	 * construction never written externally (proven by the gates above), so restricting external write access is safe.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final nameEnd: Int = nameEndOffset(source, span);
			if (nameEnd < 0) continue;
			edits.push({ span: new Span(nameEnd, nameEnd), text: '(default, null)' });
		}
		return edits;
	}

	/**
	 * Flag `field` when it is a plain `var` (not already a property), its enclosing
	 * type has no subtype, no write to its name is unresolved, it IS written somewhere
	 * (else it is `prefer-final-public-field`'s job), and no write is external.
	 */
	private static function considerField(
		out: Array<Violation>, file: String, source: String, field: QueryNode, owner: String, index: SymbolIndex,
		writeIndex: FieldWriteIndex
	): Void {
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		if (name == null || span == null) return;
		final nameEnd: Int = nameEndOffset(source, span);
		if (nameEnd < 0 || isProperty(source, nameEnd)) return;
		if (index.hasSubtype(owner) || index.supertypeDeclaresMember(owner, name)) return;
		if (writeIndex.hasUnresolvedWrite(name)) return;
		if (!writeIndex.writtenAnywhere(owner, name)) return;
		final site: Null<{ file: String, span: Span }> = index.declarationSiteOf(owner);
		if (site == null) return;
		if (writeIndex.writtenExternally(owner, name, site.file, site.span)) return;
		out.push({
			file: file,
			span: span,
			rule: 'prefer-read-only-field',
			severity: Severity.Info,
			message: 'public field \'$name\' is written only internally; restrict writes with (default, null)'
		});
	}

	/**
	 * Offset just past the field name — after the `var` keyword, whitespace, and the
	 * identifier — or -1 when the decl does not begin with the `var` keyword.
	 */
	private static function nameEndOffset(source: String, span: Span): Int {
		final keyword: String = 'var';
		final n: Int = source.length;
		if (span.from + keyword.length > n || source.substring(span.from, span.from + keyword.length) != keyword) return -1;
		var i: Int = span.from + keyword.length;
		while (i < n && isSpace(StringTools.fastCodeAt(source, i))) i++;
		final start: Int = i;
		while (i < n && isIdentChar(StringTools.fastCodeAt(source, i))) i++;
		return i > start ? i : -1;
	}

	/** Whether the first non-whitespace byte at or after `nameEnd` is `(` — a property accessor head. */
	private static function isProperty(source: String, nameEnd: Int): Bool {
		final n: Int = source.length;
		var i: Int = nameEnd;
		while (i < n && isSpace(StringTools.fastCodeAt(source, i))) i++;
		return i < n && StringTools.fastCodeAt(source, i) == '('.code;
	}

	/** Whether `c` is an identifier character. */
	private static inline function isIdentChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code;
	}

	/** Whether `c` is whitespace. */
	private static inline function isSpace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

}
