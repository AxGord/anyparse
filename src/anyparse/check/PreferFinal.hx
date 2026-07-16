package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.Refs;
import anyparse.query.Refs.RefKind;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a local `var` declaration that is never reassigned — a mutable
 * binding the immutable `final` should replace — and rewrites `var` to
 * `final`. `Severity.Info` (a modernization cleanup toward immutability),
 * with an autofix. Grammar-agnostic over `RefShape.mutableLocalDeclKinds`.
 *
 * ## Soundness — why reassignment is detected structurally
 *
 * A false negative here is dangerous: missing a reassignment would flag a
 * genuinely-mutable `var`, and the autofix would then produce a `final` the
 * compiler rejects. Reassignments are found with the scope-resolved write
 * walker `apq refs --writes` uses (`Refs.find` + `RefShape.writeParentKinds`),
 * which is COMPLETE for writes: every write is a structural assignment / `++`
 * / `--` node, and the only reference a source scan would miss — simple `'$x'`
 * interpolation — can only ever be a read.
 *
 * A write is attributed to this candidate by its POSITION (does the write fall
 * inside the candidate's enclosing scope?), NOT by the resolver's `bindingSpan`.
 * A `case`-branch body opens no scope, so several same-named locals in sibling
 * branches share one frame and the resolver can bind a write to the wrong one;
 * a position test is immune. Since a local can only be reassigned from within
 * its own scope, every real write IS inside the enclosing scope — so no
 * reassignment is ever missed. It is conservative the other way (a sibling
 * `case`'s write of the same name suppresses the flag), which only ever keeps
 * a `var`, never produces a wrong `final`.
 *
 * ## No overlap with `unused-local`
 *
 * The read gate reuses the exact `RefactorSupport.referencedInRange` test
 * `unused-local` uses: this check fires only when the binding IS referenced,
 * `unused-local` only when it is NOT — so their autofix edits (a `var`→`final`
 * swap vs a whole-line delete) are mutually exclusive by construction.
 * Suggesting `final` for a never-read var would be pointless anyway — that is
 * a deletion, not an immutability fix.
 *
 * ## Single-var-with-initializer only
 *
 * Only a `var x = <expr>;` is a candidate: a no-init `var x;` (`final` would
 * need a definite-assignment proof this check does not attempt) and a multi-
 * declaration `var a = 1, b = 2;` are skipped. The grammar collapses
 * `var a, b = 2` to a single node named `a` with one child, so the AST alone
 * cannot tell it from a genuine single var — the guard is therefore `exactly
 * one child AND no top-level comma in the declaration source` (a comma outside
 * `()`/`[]`/`{}` and string literals). Generic type-parameter commas
 * (`Map<K, V>`) are left untracked, so such a var is conservatively skipped
 * rather than risk a wrong fix.
 *
 * ## Reification is opaque
 *
 * A `var` inside a metaprogramming-reification subtree (`opaqueKinds`) is
 * skipped: its mutations may be splice-injected and invisible, consistent with
 * `unused-local`.
 */
@:nullSafety(Strict)
final class PreferFinal implements Check {

	public function new() {}

	public function id(): String {
		return 'prefer-final';
	}

	public function description(): String {
		return 'a local var never reassigned that can be final';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		final shape: RefShape = plugin.refShape();
		final mutableKinds: Array<String> = shape.mutableLocalDeclKinds ?? [];
		if (mutableKinds.length == 0) return violations;
		final scopeKinds: Array<String> = shape.scopeKinds;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) checkTree(violations, entry.file, entry.source, tree, shape, scopeKinds, opaqueKinds, mutableKinds);
		}
		return violations;
	}

	/**
	 * Rewrite each flagged `var` keyword to `final`. The candidate is by
	 * construction never reassigned, so the swap is always safe; the edit only
	 * fires when the bytes at the declaration start are literally the keyword
	 * (a guard against any unexpected span — `substring` clamps, so a span near
	 * EOF simply fails the equality).
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final keyword: String = 'var';
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final end: Int = span.from + keyword.length;
			if (source.substring(span.from, end) != keyword) continue;
			edits.push({ span: new Span(span.from, end), text: 'final' });
		}
		return edits;
	}

	/**
	 * Collect this file's candidates and emit a `Warning`-free `Info` for each
	 * that is never reassigned within its scope. One write scan per distinct
	 * name is memoized — several candidates can share a name.
	 */
	private static function checkTree(
		out: Array<Violation>, file: String, source: String, tree: QueryNode, shape: RefShape, scopeKinds: Array<String>,
		opaqueKinds: Array<String>, mutableKinds: Array<String>
	): Void {
		final candidates: Array<{ name: String, span: Span, scope: Span }> = [];
		collect(candidates, source, tree, null, scopeKinds, opaqueKinds, mutableKinds);
		final writesByName: Map<String, Array<Span>> = [];
		for (c in candidates) {
			if (!writesByName.exists(c.name)) writesByName[c.name] = writeSpans(c.name, tree, shape);
			final writes: Null<Array<Span>> = writesByName[c.name];
			if (writes != null && reassignedInScope(writes, c.scope)) continue;
			out.push({
				file: file,
				span: c.span,
				rule: 'prefer-final',
				severity: Severity.Info,
				message: 'local \'${c.name}\' is never reassigned; use final'
			});
		}
	}

	/**
	 * Walk `node`, tracking the innermost enclosing scope, and collect every
	 * single-var-with-initializer local that is referenced in its scope. A
	 * reification subtree (`opaqueKinds`) is skipped wholesale.
	 */
	private static function collect(
		out: Array<{ name: String, span: Span, scope: Span }>, source: String, node: QueryNode, enclosingScope: Null<QueryNode>,
		scopeKinds: Array<String>, opaqueKinds: Array<String>, mutableKinds: Array<String>
	): Void {
		if (opaqueKinds.contains(node.kind)) return;
		if (mutableKinds.contains(node.kind)) consider(out, source, node, enclosingScope);
		final childScope: Null<QueryNode> = scopeKinds.contains(node.kind) ? node : enclosingScope;
		for (c in node.children) collect(out, source, c, childScope, scopeKinds, opaqueKinds, mutableKinds);
	}

	/**
	 * Append `decl` as a candidate when it is a single `var x = <expr>` (one
	 * initializer child, no top-level comma) referenced somewhere in its
	 * enclosing scope. The scope span is carried so a reassignment can be
	 * attributed by position. Bails on any missing coordinate.
	 */
	private static function consider(
		out: Array<{ name: String, span: Span, scope: Span }>, source: String, decl: QueryNode, enclosingScope: Null<QueryNode>
	): Void {
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		if (name == null || declSpan == null || enclosingScope == null) return;
		final scopeSpan: Null<Span> = enclosingScope.span;
		if (scopeSpan == null) return;
		if (decl.children.length != 1) return;
		if (hasTopLevelComma(source.substring(declSpan.from, declSpan.to))) return;
		if (!RefactorSupport.referencedInRange(source, name, scopeSpan.from, scopeSpan.to, [declSpan])) return;
		out.push({ name: name, span: declSpan, scope: scopeSpan });
	}

	/**
	 * The source positions of every reassignment of `name` in `tree` — a
	 * `Write` hit's own span. A candidate is reassigned when one of these falls
	 * within its scope (see `reassignedInScope`).
	 */
	private static function writeSpans(name: String, tree: QueryNode, shape: RefShape): Array<Span> {
		final spans: Array<Span> = [for (h in Refs.find(name, tree, shape)) if (h.kind == RefKind.Write) h.span];
		return spans;
	}

	/** Whether any reassignment position in `writes` falls within `scope`. */
	private static function reassignedInScope(writes: Array<Span>, scope: Span): Bool {
		for (w in writes) if (w.from >= scope.from && w.from < scope.to) return true;
		return false;
	}

	/**
	 * Whether `s` contains a comma outside any `()`/`[]`/`{}` nesting and
	 * outside a string literal — the multi-declaration separator of
	 * `var a = 1, b = 2`. `<>` is deliberately not tracked (a generic type
	 * parameter's comma reads as top-level, conservatively skipping the var),
	 * because `<` is ambiguous with the less-than operator and over-counting
	 * depth could hide a real separator.
	 */
	private static function hasTopLevelComma(s: String): Bool {
		var depth: Int = 0;
		var i: Int = 0;
		final n: Int = s.length;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(s, i);
			switch c {
				case '('.code | '['.code | '{'.code:
					depth++;
				case ')'.code | ']'.code | '}'.code:
					if (depth > 0) depth--;
				case '"'.code | "'".code:
					i = skipString(s, i, c);
				case ','.code:
					if (depth == 0) return true;
				case _:
			}
			i++;
		}
		return false;
	}

	/**
	 * Index of the closing `quote` of the string opened at `open`, honouring
	 * `\`-escapes; the source length minus one if unterminated (the caller's
	 * `i++` then ends the scan). Lets `hasTopLevelComma` skip commas inside a
	 * string initializer.
	 */
	private static function skipString(s: String, open: Int, quote: Int): Int {
		final n: Int = s.length;
		var i: Int = open + 1;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(s, i);
			if (c == '\\'.code) {
				i += 2;
				continue;
			}
			if (c == quote) return i;
			i++;
		}
		return n - 1;
	}

}
