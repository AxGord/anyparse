package anyparse.check.common.members;

import anyparse.check.Check.DefaultOff;
import anyparse.check.scan.CheckScan;
import anyparse.query.AccessorClause;
import anyparse.query.CtorFieldWrite;
import anyparse.query.SymbolIndex;

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
 * than two, or a clause the grammar does not capture (a conditional-compilation directive inside
 * it) is a safe miss. `final` members and local declarations never carry a meaningful clause and
 * are out of the walk entirely (`RefactorSupport.eachFieldMember` visits mutable FIELD members
 * only), and so are INTERFACE members: `visibilityContainerKinds` covers classes and abstracts,
 * not `InterfaceDecl`. Haxe treats an interface `(default, default)` the same way, so that is a
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
 * finding (the `redundant-cast-type` comment-guard convention), as does a comment between the
 * field name and the clause. It is a WHOLE-HEAD refusal, per MEMBER, not per file: a genuine
 * sibling on the next line still reports.
 *
 * ## Grammar-agnostic
 *
 * The member walk is the shared `eachFieldMember` one, and the clause is the grammar fact
 * `AccessorClause` (`TypeInfoProvider.accessorClauses`): its accessor identifiers and its span
 * come from the declaration node, so nothing here spells a Haxe keyword beyond the accessor
 * vocabulary `default`.
 */
@:nullSafety(Strict)
final class RedundantPropertyAccess extends RuleBase implements DefaultOff {

	public function new() {
		super(
			'redundant-property-access', 'a property declared (default, default) — the plain stored accessors, identical to a bare var',
			RuleCategory.Members
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		CtorFieldWrite.eachFieldMember(files, plugin, (owner, field, source, file, exported) -> {
			final name: Null<String> = field.name;
			final clause: Null<Span> = redundantClause(RunScan.accessorClausesOf(plugin, source), source, field);
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
	 * name. The violation span is the clause's parenthesised pair; the clause is looked up by the
	 * span's end and must still be a plain stored one opening at the span's start, so a stale span
	 * deletes nothing.
	 *
	 * The comment guard is deliberately `run`-only: this gate is strictly weaker, which is the
	 * sound direction under the `Check.fix` contract (the caller passes this check's OWN
	 * violations, already guarded), and the region this deletes is whitespace and the clause.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final byEnd: Map<Int, AccessorClause> = [
			for (clause in RunScan.accessorClausesOf(plugin, source)) clause.span.to => clause
		];
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final clause: Null<AccessorClause> = byEnd[span.to];
			if (clause == null || !clause.plainStored() || clause.parenSpan().from != span.from) continue;
			edits.push({ span: new Span(clause.leadGap.from, span.to), text: '' });
		}
		return edits;
	}

	/**
	 * The `(default, default)` clause span of `field`, or null when the member carries no
	 * accessor clause, carries a different one, or a comment sits anywhere from the
	 * declaration's start through the clause's `)`.
	 */
	private static function redundantClause(clauses: Map<Int, AccessorClause>, source: String, field: QueryNode): Null<Span> {
		final span: Null<Span> = field.span;
		if (span == null) return null;
		final clause: Null<AccessorClause> = clauses[span.from];
		if (clause == null || !clause.plainStored()) return null;
		final paren: Span = clause.parenSpan();
		return CheckScan.hasCommentMarker(source, span.from, paren.to) ? null : paren;
	}

}
