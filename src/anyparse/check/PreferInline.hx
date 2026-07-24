package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a SIMPLE method — one whose body is a single expression — that can be marked
 * `inline`, per the user's rule: use `inline` on single-expression methods (trivial
 * getters / setters and thin delegation wrappers). `Severity.Info`; `--fix` inserts
 * `inline ` before the `function` keyword.
 *
 * A method qualifies when its body is exactly one expression — an arrow body
 * (`function f():T EXPR;`) or a block with a single `return` / expression statement
 * (`{ return EXPR; }` / `{ EXPR; }`). Everything else (empty / multi-statement bodies,
 * bodyless interface / abstract declarations) is not a candidate.
 *
 * ## Must-skip set (soundness — a miss over a wrong flag)
 *
 * - A method referenced anywhere in scope as a VALUE (callback registration, `.bind`,
 *   passed as an argument, stored in a var). A method-value reference cannot be inlined,
 *   so any value-position occurrence of the method's name — resolvable or not — skips it.
 *   Detected by a conservative name scan over every file: a name in value position (not a
 *   call callee) via `IdentExpr` / `FieldAccess` / `SafeFieldAccess` / `ForceFieldAccess`.
 * - An `override` method, and a method OVERRIDDEN by a subtype (`SymbolIndex.hasSubtype`
 *   plus a member-name lookup across strict subtypes) — inlining would break the override.
 * - A method an implemented interface declares (`SymbolIndex.typeProvablyLacksMember`, which
 *   also refuses when the interface is unresolvable) — the interface requires a real method.
 * - A `dynamic` method (re-bindable at runtime), a constructor (`new`), a `macro` method, a
 *   `@:keep` method, and any method whose name is passed to `Reflect.*` as a string literal
 *   anywhere in scope (reflection-accessed) — all skipped conservatively.
 * - A method whose single expression references itself (a bare `foo` / `this.foo`) — a
 *   potential recursive inline; a delegation to a same-named method on another receiver
 *   (`other.foo()`) is NOT a self-reference and stays a candidate.
 *
 * Only `ClassDecl` / `final class` (`ClassForm`) bodies are inspected; already-`inline`
 * methods are skipped (nothing to do). The gates mirror `trivial-getter`'s soundness model.
 */
@:nullSafety(Strict)
final class PreferInline implements Check {

	public function new() {}

	public function id(): String {
		return 'prefer-inline';
	}

	public function description(): String {
		return
			'a single-expression method (trivial getter/setter or thin delegation wrapper) markable inline; Info, --fix inserts inline. Skips methods referenced as a value, override / subtype-overridden, interface-declared, dynamic / macro / constructor / @:keep / Reflect-accessed methods';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final trees: Array<{ file: String, tree: QueryNode }> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) trees.push({ file: entry.file, tree: tree });
		}
		// Pass A: the names of every LOCALLY-eligible method (single-expression, and not
		// inline / dynamic / macro / override / @:keep / constructor / self-recursive) — the only
		// names the reference-kind scan below must resolve, keeping its blocked sets small.
		final candidateNames: Array<String> = [];
		for (t in trees) for (cls in classes(t.tree)) forEachMethod(cls, (name, fn, mods, metas) -> {
			if (isCandidateMethod(name, fn, mods, metas) && !candidateNames.contains(name)) candidateNames.push(name);
		});
		// Pass B: the reference-kind gate over the whole scope — a candidate name used as a VALUE
		// (a method-value reference forbids inlining) or passed to `Reflect.*` as a string literal.
		final valueBlocked: Array<String> = [];
		final reflectBlocked: Array<String> = [];
		for (t in trees) {
			collectValueRefs(t.tree, false, candidateNames, valueBlocked);
			collectReflectNames(t.tree, candidateNames, reflectBlocked);
		}
		// Pass C: emit a finding for each candidate the cross-file gates leave standing.
		final out: Array<Violation> = [];
		for (t in trees) for (cls in classes(t.tree)) considerClass(out, cls, t.file, index, valueBlocked, reflectBlocked);
		return out;
	}

	/**
	 * Insert `inline ` before the `function` keyword of each wanted method (its FnMember span
	 * start). The report already applied every soundness gate — the fix only re-locates each
	 * violated method by span and emits the single insertion, skipping a method somehow already
	 * `inline`.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final wanted: Array<String> = [];
		for (v in violations) {
			final s: Null<Span> = v.span;
			if (s != null) wanted.push('${s.from}:${s.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (cls in classes(tree)) forEachMethod(cls, (name, fn, mods, metas) -> {
			final span: Null<Span> = fn.span;
			if (span == null || mods.contains('Inline') || !wanted.contains('${span.from}:${span.to}')) return;
			edits.push({ span: new Span(span.from, span.from), text: 'inline ' });
		});
		return edits;
	}

	/** Every class-body node in the tree — `ClassDecl` and `final class`'s `ClassForm`. */
	private static function classes(root: QueryNode): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		collectClasses(root, out);
		return out;
	}

	private static function collectClasses(node: QueryNode, out: Array<QueryNode>): Void {
		if (node.kind == 'ClassDecl' || node.kind == 'ClassForm') out.push(node);
		for (child in node.children) collectClasses(child, out);
	}

	/**
	 * Flag each candidate single-expression method of `cls` that passes every soundness gate: not
	 * value-referenced / reflection-named anywhere, not overridden by a subtype, not required by an
	 * implemented interface, and (per `isCandidateMethod`) not a constructor / override / dynamic /
	 * macro / @:keep / already-inline / self-recursive method.
	 */
	private static function considerClass(
		out: Array<Violation>, cls: QueryNode, file: String, index: SymbolIndex, valueBlocked: Array<String>, reflectBlocked: Array<String>
	): Void {
		final className: Null<String> = cls.name;
		if (className == null) return;
		final subtypeMembers: Array<String> = index.hasSubtype(className) ? subtypeMemberNames(index, className) : [];
		final ifaces: Array<String> = implementedInterfaces(cls);
		forEachMethod(cls, (name, fn, mods, metas) -> {
			if (!isCandidateMethod(name, fn, mods, metas)) return;
			if (valueBlocked.contains(name) || reflectBlocked.contains(name) || subtypeMembers.contains(name)) return;
			if (interfaceRequires(index, ifaces, name)) return;
			final span: Null<Span> = fn.span;
			if (span == null) return;
			out.push({
				file: file,
				span: span,
				rule: 'prefer-inline',
				severity: Severity.Info,
				message: 'method \'$name\' is a single-expression method with no value references; mark it inline'
			});
		});
	}

	/**
	 * Invoke `cb(name, fnNode, mods, metas)` for every `FnMember` of `cls`, where `mods` is the
	 * member's preceding modifier-kind run (`Public` / `Static` / `Inline` / …) and `metas` its
	 * preceding metadata names (`@:keep` / …), both reset at each member boundary. `final function`
	 * (`FinalModifiedMember`) and fields reset the run but are not methods.
	 */
	private static function forEachMethod(cls: QueryNode, cb: (String, QueryNode, Array<String>, Array<String>) -> Void): Void {
		var mods: Array<String> = [];
		var metas: Array<String> = [];
		for (child in cls.children) switch child.kind {
			case 'FnMember':
				final name: Null<String> = child.name;
				if (name != null) cb(name, child, mods, metas);
				mods = [];
				metas = [];
			case 'VarMember' | 'FinalMember' | 'FinalModifiedMember':
				mods = [];
				metas = [];
			case 'Meta' | 'MetaCall':
				final nm: Null<String> = child.name;
				if (nm != null) metas.push(nm);
			case _:
				mods.push(child.kind);
		}
	}

	/**
	 * Whether `name` / `fn` is an inline candidate: a non-constructor method with a single-expression
	 * body, not already `inline` / `dynamic` / `macro` / `override`, not `@:keep`, and not
	 * self-recursive (a bare `name` / `this.name` in its body).
	 */
	private static function isCandidateMethod(name: String, fn: QueryNode, mods: Array<String>, metas: Array<String>): Bool {
		if (name == 'new') return false;
		if (mods.contains('Inline') || mods.contains('Dynamic') || mods.contains('Macro') || mods.contains('Override')) return false;
		if (metas.contains('@:keep')) return false;
		return isSingleExpressionBody(fn) && !referencesSelf(fn, name);
	}

	/** Whether `fn`'s body is a single expression — an `ExprBody`, or a `BlockBody` with one `return` / expression statement. */
	private static function isSingleExpressionBody(fn: QueryNode): Bool {
		final body: Null<QueryNode> = fn.children.find(c -> c.kind == 'ExprBody' || c.kind == 'BlockBody');
		if (body == null) return false;
		return switch body.kind {
			case 'ExprBody': body.children.length == 1;
			case 'BlockBody':
				body.children.length == 1 && (body.children[0].kind == 'ReturnStmt' || body.children[0].kind == 'ExprStmt');
			case _: false;
		}
	}

	/** Whether `node`'s subtree references `name` as a bare `IdentExpr` or a `this.<name>` `FieldAccess` — a self / recursive reference. */
	private static function referencesSelf(node: QueryNode, name: String): Bool {
		if (selfRefName(node) == name) return true;
		for (c in node.children) if (referencesSelf(c, name)) return true;
		return false;
	}

	/** The name a node references as a bare `IdentExpr <name>` or `this.<name>` `FieldAccess`, else null. */
	private static function selfRefName(node: QueryNode): Null<String> {
		return switch node.kind {
			case 'IdentExpr': node.name;
			case 'FieldAccess':
				node.children.length == 1 && node.children[0].kind == 'IdentExpr' && node.children[0].name == 'this' ? node.name : null;
			case _: null;
		}
	}

	/**
	 * Record into `out` each name in `candidateNames` that appears in a VALUE position (not a call
	 * callee) via an `IdentExpr` / `FieldAccess` / `SafeFieldAccess` / `ForceFieldAccess` node — the
	 * method-value references that forbid inlining. `inCalleePos` marks `node` as the callee child
	 * (child 0) of a `Call`, where an occurrence is an invocation, not a value.
	 */
	private static function collectValueRefs(node: QueryNode, inCalleePos: Bool, candidateNames: Array<String>, out: Array<String>): Void {
		final name: Null<String> = node.name;
		if (name != null && !inCalleePos && isAccessKind(node.kind) && candidateNames.contains(name) && !out.contains(name)) out.push(name);
		final isCall: Bool = node.kind == 'Call';
		final children: Array<QueryNode> = node.children;
		for (i in 0...children.length) collectValueRefs(children[i], isCall && i == 0, candidateNames, out);
	}

	/** Whether `kind` is an identifier / field-access value node whose name could be a method-value reference. */
	private static inline function isAccessKind(kind: String): Bool {
		return kind == 'IdentExpr' || kind == 'FieldAccess' || kind == 'SafeFieldAccess' || kind == 'ForceFieldAccess';
	}

	/** Record into `out` each name in `candidateNames` passed to a `Reflect.<m>(...)` call as a string literal — a method reached by reflection is not safe to inline. */
	private static function collectReflectNames(node: QueryNode, candidateNames: Array<String>, out: Array<String>): Void {
		if (node.kind == 'Call' && node.children.length >= 1) {
			final callee: QueryNode = node.children[0];
			if (
				callee.kind == 'FieldAccess' && callee.children.length == 1 && callee.children[0].kind == 'IdentExpr'
				&& callee.children[0].name == 'Reflect'
			) for (i in 1...node.children.length) {
				final lit: Null<String> = stringLiteralValue(node.children[i]);
				if (lit != null && candidateNames.contains(lit) && !out.contains(lit)) out.push(lit);
			}
		}
		for (c in node.children) collectReflectNames(c, candidateNames, out);
	}

	/** The unquoted value of a single- / double-quoted string-literal node, else null. */
	private static function stringLiteralValue(node: QueryNode): Null<String> {
		return switch node.kind {
			case 'DoubleStringExpr' | 'SingleStringExpr':
				final raw: Null<String> = node.name;
				raw == null || raw.length < 2 ? null : raw.substring(1, raw.length - 1);
			case _: null;
		}
	}

	/** The simple names of every interface in `cls`'s `implements` clauses. */
	private static function implementedInterfaces(cls: QueryNode): Array<String> {
		final out: Array<String> = [];
		for (child in cls.children) if (child.kind == 'ImplementsClause') for (named in child.children) {
			final nm: Null<String> = named.name;
			if (nm != null) out.push(simpleName(nm));
		}
		return out;
	}

	/** The last `.`-separated segment of `path` (its simple name). */
	private static inline function simpleName(path: String): String {
		final segments: Array<String> = path.split('.');
		return segments[segments.length - 1] ?? path;
	}

	/**
	 * Whether an implemented interface declares `name` — so a physical (non-inline) method is
	 * required. `typeProvablyLacksMember` returns false for an unresolvable interface, so an
	 * unreachable interface conservatively blocks the candidate.
	 */
	private static function interfaceRequires(index: SymbolIndex, ifaces: Array<String>, name: String): Bool {
		for (iface in ifaces) if (!index.typeProvablyLacksMember(iface, name)) return true;
		return false;
	}

	/** The member names declared by every STRICT subtype of `className` across the index — a method whose name appears here is overridden. */
	private static function subtypeMemberNames(index: SymbolIndex, className: String): Array<String> {
		final out: Array<String> = [];
		for (fi in index.allFiles()) for (t in fi.types) if (t.name != className && index.isSubtype(t.name, className)) for (m in t.members)
			if (!out.contains(m.name)) out.push(m.name);
		return out;
	}

}
