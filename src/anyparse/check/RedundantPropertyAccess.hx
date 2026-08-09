package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

/**
 * Flags a property whose BOTH accessors are `default` — `var x(default, default):T` — and
 * deletes the clause. `default` on either side IS the plain stored slot, so the parenthesised
 * pair restates exactly what a bare `var x:T` already declares: same storage, same read, same
 * write, same visibility. `Info`, DEFAULT OFF (a style preference: a project may spell the
 * plain shape explicitly on purpose), with an autofix.
 *
 * ## What is flagged — and what is not
 *
 * ONLY the exact pair `(default, default)`. Every other accessor is a real declaration: `get` /
 * `set` route through a method, `dynamic` re-binds at runtime, `null` / `never` restrict write
 * access, and a method name is a custom accessor. Any of them on EITHER side, an arity other
 * than two, or an unparseable clause (a conditional-compilation directive inside it) is a safe
 * miss. `final` members and local declarations never carry a meaningful clause and are out of
 * the walk entirely (`RefactorSupport.eachFieldMember` visits mutable FIELD members only), and
 * so are INTERFACE members: `visibilityContainerKinds` covers classes and abstracts, not
 * `InterfaceDecl`. Haxe treats an interface `(default, default)` the same way, so that is a
 * safe miss rather than a decision.
 *
 * `@:isVar` is metadata on the member, not part of the clause, and is left untouched — it is
 * inert on a plain field (it forces physical storage that a plain field always has).
 *
 * ## Not identical to a BUILD MACRO
 *
 * The compiler's own semantics are identical, but a `@:build` / `@:autoBuild` macro sees the
 * two spellings as different `FieldType`s — `FProp('default', 'default')` before the fix,
 * `FVar` after. A project whose macros switch on field kind should leave this rule off; that,
 * with the deliberate-style case below, is why it is off by default.
 *
 * ## The fix
 *
 * ONE edit per finding: the clause plus any whitespace between it and the field name deleted,
 * `[name end, ')' + 1)`. Nothing else in the declaration is touched, so visibility, `static`,
 * the type annotation, the initializer, the doc comment and the metadata all survive verbatim.
 *
 * A COMMENT anywhere from the declaration's start through the clause's `)` withholds the
 * finding (the `redundant-cast-type` comment-guard convention). It is a WHOLE-HEAD refusal, not
 * only a protection of the deleted bytes: a comment sitting BEFORE the name is harmless to the
 * deletion and still costs the finding. That is the price of the hazard it closes — the field
 * name is located by text search (`RefactorSupport.identTokenOffset`), so a comment ahead of the
 * name carrying a word matching it sends the whole scan into the comment's own text. A block
 * comment quoting the whole shape ahead of an ALREADY-PLAIN `var x:Int;` is the worked case (see
 * `RedundantPropertyAccessCheckTest.testCommentQuotingTheNameNotFlagged`, which spells it out —
 * a nested comment cannot be written here). The refusal is per MEMBER, not per file: a genuine
 * sibling on the next line still reports.
 *
 * ## Grammar-agnostic
 *
 * The member walk is the shared `eachFieldMember` one (`RefShape.visibilityContainerKinds` /
 * `mutableFieldDeclKinds`), and the field name token is located through
 * `RefactorSupport.identTokenOffset` rather than a keyword literal, so nothing here spells a
 * Haxe keyword. The accessor SPELLING (`default`) and the `(a, b)` clause syntax are read from
 * the source text: the projection drops `HxVarDecl.access`, and the one seam that survives it
 * (`TypeInfoProvider.propertyAccessors`) reports only whether an accessor RUNS CODE — which
 * cannot tell `(default, default)` from `(default, null)`. A grammar with a different accessor
 * syntax needs that seam widened before this check can follow it.
 */
@:nullSafety(Strict)
final class RedundantPropertyAccess implements Check implements DefaultOff {

	/** The one accessor spelling that means "the plain stored slot" on both the read and the write side. */
	private static inline final PLAIN_ACCESSOR: String = 'default';

	public function new() {}

	public function id(): String {
		return 'redundant-property-access';
	}

	public function description(): String {
		return 'a property declared (default, default) — the plain stored accessors, identical to a bare var';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		RefactorSupport.eachFieldMember(files, plugin, (owner, field, source, file, exported) -> {
			final name: Null<String> = field.name;
			final clause: Null<Span> = redundantClause(source, field);
			if (name != null && clause != null) violations.push({
				file: file,
				span: clause,
				rule: 'redundant-property-access',
				severity: Severity.Info,
				message: 'property \'$name\' declares (default, default) — the plain stored accessors; drop the clause and write \'var '
				+ '$name\''
			});
		});
		return violations;
	}

	/**
	 * Delete each flagged clause together with the whitespace separating it from the field
	 * name. The violation span is the clause itself (computed against this same `source`), and
	 * the text at it is re-checked so a stale span deletes nothing.
	 *
	 * The comment guard is deliberately `run`-only: this gate is strictly weaker, which is the
	 * sound direction under the `Check.fix` contract (the caller passes this check's OWN
	 * violations, already guarded). Re-running it here would buy nothing — for a violation `run`
	 * emitted, the region this deletes is provably comment-free twice over, by the guard AND by
	 * the accessor scan's own alphabet.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null || plainStoredClause(source, span.from, span.to) == null) continue;
			edits.push({ span: new Span(nameEndBefore(source, span.from), span.to), text: '' });
		}
		return edits;
	}

	/**
	 * The `(default, default)` clause span of `field`, or null when the member carries no
	 * accessor clause, carries a different one, or a comment sits anywhere from the
	 * declaration's start through the clause's `)` — where the fix would delete it, or where
	 * it could have hijacked the name-token search (see the class doc).
	 */
	private static function redundantClause(source: String, field: QueryNode): Null<Span> {
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		if (name == null || span == null) return null;
		final nameOffset: Int = RefactorSupport.identTokenOffset(source, span, name);
		if (nameOffset < 0) return null;
		final open: Int = RefactorSupport.skipSpaces(source, nameOffset + name.length, span.to);
		final clause: Null<Span> = plainStoredClause(source, open, span.to);
		return clause == null || CheckScan.hasCommentMarker(source, span.from, clause.to) ? null : clause;
	}

	/**
	 * The `[open, ')' + 1)` span of an accessor clause at `open` whose two identifiers are BOTH
	 * `default`, or null for anything else — a different accessor, a different arity, a
	 * non-identifier where an accessor is expected (a `#if` directive), or a missing `)`.
	 * `limit` bounds the scan to the declaration.
	 */
	private static function plainStoredClause(source: String, open: Int, limit: Int): Null<Span> {
		if (open >= limit || source.fastCodeAt(open) != '('.code) return null;
		final read: Int = plainAccessorEnd(source, RefactorSupport.skipSpaces(source, open + 1, limit), limit);
		if (read < 0) return null;
		final comma: Int = RefactorSupport.skipSpaces(source, read, limit);
		if (comma >= limit || source.fastCodeAt(comma) != ','.code) return null;
		final write: Int = plainAccessorEnd(source, RefactorSupport.skipSpaces(source, comma + 1, limit), limit);
		if (write < 0) return null;
		final close: Int = RefactorSupport.skipSpaces(source, write, limit);
		return close < limit && source.fastCodeAt(close) == ')'.code ? new Span(open, close + 1) : null;
	}

	/** The offset just past a `default` identifier at `i`, or -1 when the token there is anything else. */
	private static function plainAccessorEnd(source: String, i: Int, limit: Int): Int {
		var j: Int = i;
		while (j < limit && RefactorSupport.isIdentChar(source.fastCodeAt(j))) j++;
		return j > i && source.substring(i, j) == PLAIN_ACCESSOR ? j : -1;
	}

	/** The offset where the field name ends — `clauseFrom` walked back over the whitespace before the clause. */
	private static function nameEndBefore(source: String, clauseFrom: Int): Int {
		var i: Int = clauseFrom;
		while (i > 0 && RefactorSupport.isSpace(source.fastCodeAt(i - 1))) i--;
		return i;
	}

}
