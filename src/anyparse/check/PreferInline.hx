package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberBranchScan;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.OracleRelaxable;

/**
 * Flags a method whose inlining BUYS something and that can therefore be marked `inline`, per the user's rule: use
 * `inline` on trivial getters / setters, thin delegation wrappers and no-op stubs. `Severity.Info`; `--fix` inserts
 * `inline ` before the `function` keyword.
 *
 * A method qualifies when its body is one of three BENEFIT classes: (A) an EMPTY block — the call compiles away, and
 * a FUTURE override of an inlined method fails loudly at the overriding site (the same subtype-gate evidence the
 * other classes rely on); (B) a single accessor / thin-forward / trivial-mutator expression — a bare field chain, a
 * call through a chain with only chain / literal arguments, an assignment or increment over a chain — which collapses
 * into a direct read / write / forwarded call; (C) a constant / small-arithmetic expression (literals, chains and
 * operators only) which can fold at the call site. B and C are bounded by `MAX_BODY_NODES` (~32 AST nodes).
 * Everything else fails the class test by construction — an allocation (`new`, an array / object /
 * interpolated-string literal, a `macro` reification), a lambda argument, a computed forward argument, a loop, a
 * switch, a multi-statement body: none of them gain anything from `inline`, inlining would only duplicate their
 * codegen at every call site.
 *
 * ## Must-skip set (soundness — a miss over a wrong flag)
 *
 * - A method referenced anywhere in scope as a VALUE (callback registration, `.bind`,
 *   passed as an argument, stored in a var). A method-value reference cannot be inlined,
 *   so any value-position occurrence of the method's name — resolvable or not — skips it.
 *   Detected by a conservative name scan over every file: a name in value position (not a
 *   call callee) via `IdentExpr` / `FieldAccess` / `SafeFieldAccess` / `ForceFieldAccess`.
 * - An `override` method, and a method OVERRIDDEN by a subtype (`SymbolIndex.hasSubtype`
 *   plus a member-name lookup across strict subtypes) — inlining would break the override; and a method FILLING an
 *   abstract-superclass slot (`SymbolIndex.supertypeDeclaresMember` — Haxe requires no `override` on such an
 *   implementation).
 * - A method an implemented interface declares (`SymbolIndex.typeProvablyLacksMember`, which
 *   also refuses when the interface is unresolvable) — the interface requires a real method.
 * - A `dynamic` method (re-bindable at runtime), a constructor (`new`), a `macro` method, a
 *   `@:keep` method, and any method whose name is passed to `Reflect.*` as a string literal
 *   anywhere in scope (reflection-accessed) — all skipped conservatively.
 * - A method whose single expression references itself (a bare `foo` / `this.foo`) — a
 *   potential recursive inline; a delegation to a same-named method on another receiver
 *   (`other.foo()`) is NOT a self-reference and stays a candidate.
 * - A method whose body carries a `null` literal in a VALUE slot (`bodyHasNullSafetyRisk`) — not a
 *   `==` / `!=` / `??` null-check operand. Haxe re-type-checks an inline body in the CALLER's
 *   null-safety mode, so a `null` argument / operand that compiles in its own (looser / off) context
 *   can fail Strict re-checking at a caller. Over-skips a safe null-value body (the sound direction;
 *   a precise split would need null-flow typing).
 *
 * Every class body — plain / `final` / `abstract class` (`CheckScan.isClassBodyKind`) — is inspected; already-`inline`
 * methods are skipped (nothing to do). The gates mirror `trivial-getter`'s soundness model.
 */
@:nullSafety(Strict)
final class PreferInline implements Check implements RiskyFix implements OracleRelaxable {

	/**
	 * The inline-candidate body budget in AST nodes. Calibrated on a large real tree: trivial getters
	 * run 3-6 nodes, thin delegations 8-16, small factories 15-25; past ~32 the bodies are string /
	 * object BUILDERS, `if`-chains, or comparator closures — real work whose codegen inlining would
	 * duplicate at every call site for no gain.
	 */
	private static inline final MAX_BODY_NODES: Int = 32;

	/** Field-access chain link kinds — a chain is `IdentExpr` at the leaf wrapped in any of these. */
	private static final CHAIN_KINDS: Array<String> = ['FieldAccess', 'SafeFieldAccess', 'ForceFieldAccess'];

	/** Scalar literal kinds — constants carrying no allocation (`NullLit` is mode-gated by the null-safety layer). */
	private static final SCALAR_LIT_KINDS: Array<String> = ['IntLit', 'FloatLit', 'HexLit', 'BoolLit', 'NullLit'];

	/** Assignment-family root kinds of a trivial mutator body (`x = v`, `_n += 1`, `_count++`). */
	private static final MUTATOR_KINDS: Array<String> = [
		      'Assign', 'AddAssign', 'SubAssign',      'MulAssign', 'DivAssign', 'ModAssign', 'BitOrAssign', 'BitAndAssign',
		'BitXorAssign', 'ShlAssign', 'ShrAssign', 'NullCoalAssign',  'PostIncr',   'PreIncr',    'PostDecr',      'PreDecr'
	];

	/** Operator kinds a constant / small-arithmetic body may consist of (plus chains and literals) — none allocate. */
	private static final CONST_OP_KINDS: Array<String> = [
		'Add',
		'Sub',
		'Mul',
		'Div',
		'Mod',
		'Neg',
		'Not',
		'And',
		'Or',
		'BitOr',
		'BitAnd',
		'BitXor',
		'Shl',
		'Shr',
		'UShr',
		'Eq',
		'NotEq',
		'Lt',
		'Gt',
		'LtEq',
		'GtEq',
		'NullCoal',
		'Ternary',
		'ParenExpr',
		'Is'
	];

	/** The `Call` node kind — shared by the forward classifier and both reference scans. */
	private static inline final CALL_KIND: String = 'Call';

	private var _oracleRelaxed: Bool = false;

	public function new() {}

	/**
	 * Enable RELAXED candidate selection: drop the null-safety gate (`bodyHasNullSafetyRisk`) so a
	 * benefit-class body carrying a `null` literal in a value slot (a null argument / operand) also
	 * becomes a candidate. The benefit classes themselves are unchanged — relaxed mode widens ONLY the
	 * null gate. Set by `Cli.applyLintFixes` ONLY when this check runs as a verified `RiskyFix` (a
	 * compiler oracle is configured), so the extra candidates are always applied through the
	 * typecheck-and-revert pipeline, never unverified.
	 */
	public function setOracleRelaxed(relaxed: Bool): Void {
		_oracleRelaxed = relaxed;
	}

	public function id(): String {
		return 'prefer-inline';
	}

	public function description(): String {
		return
			'a method whose inlining buys something — empty body, accessor / thin forward / trivial mutator, or a foldable constant/arithmetic expression (<=32 AST nodes); Info, --fix inserts inline. Allocations, builders, loops, switches, lambda/computed args are never candidates. Skips methods referenced as a value, override / subtype-overridden, interface-declared, dynamic / macro / constructor / @:keep / Reflect-accessed methods';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final shape: RefShape = plugin.refShape();
		final trees: Array<{ file: String, tree: QueryNode, branch: MemberBranchSeams }> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) trees.push({ file: entry.file, tree: tree, branch: MemberBranchScan.seamsOf(shape, entry.source) });
		}
		// Pass A: the names of every LOCALLY-eligible method (single-expression / empty, and not
		// inline / dynamic / macro / override / @:keep / constructor / self-recursive) — the only
		// names the reference-kind scan below must resolve, keeping its blocked sets small.
		final candidateNames: Array<String> = [];
		for (t in trees) for (cls in CheckScan.classBodies(t.tree)) forEachMethod(cls, t.branch, (name, fn, mods, metas) -> {
			if (isCandidateMethod(name, fn, mods, metas, _oracleRelaxed) && !candidateNames.contains(name)) candidateNames.push(name);
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
		for (t in trees) for (cls in CheckScan.classBodies(t.tree))
			considerClass(out, cls, t.file, index, valueBlocked, reflectBlocked, _oracleRelaxed, t.branch);
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
		final branch: MemberBranchSeams = MemberBranchScan.seamsOf(plugin.refShape(), source);
		for (cls in CheckScan.classBodies(tree)) forEachMethod(cls, branch, (name, fn, mods, metas) -> {
			final span: Null<Span> = fn.span;
			if (span == null || mods.contains('Inline') || !wanted.contains('${span.from}:${span.to}')) return;
			edits.push({ span: new Span(span.from, span.from), text: 'inline ' });
		});
		return edits;
	}

	/**
	 * Flag each candidate method of `cls` (a benefit-class body) that passes every soundness gate: not value-referenced / reflection-named anywhere, not overridden by a subtype, not implementing an abstract-superclass slot, not required by an implemented interface, and (per `isCandidateMethod`) not a constructor / override / dynamic / macro / @:keep / already-inline / self-recursive method, body in a benefit class.
	 */
	private static function considerClass(
		out: Array<Violation>, cls: QueryNode, file: String, index: SymbolIndex, valueBlocked: Array<String>,
		reflectBlocked: Array<String>, relaxed: Bool, branch: MemberBranchSeams
	): Void {
		final className: Null<String> = cls.name;
		if (className == null) return;
		// Re-bound to a non-null local: the narrowing does not reach into the nested callback below.
		final owner: String = className;
		final subtypeMembers: Array<String> = index.hasSubtype(owner) ? subtypeMemberNames(index, owner) : [];
		final ifaces: Array<String> = implementedInterfaces(cls);
		forEachMethod(cls, branch, (name, fn, mods, metas) -> {
			if (!isCandidateMethod(name, fn, mods, metas, relaxed)) return;
			if (valueBlocked.contains(name) || reflectBlocked.contains(name) || subtypeMembers.contains(name)) return;
			// An abstract-superclass implementation carries no `override` (Haxe does
			// not require it), so the modifier gate misses it — a resolvable
			// supertype declaring the member means this method fills a base slot and
			// must stay physical. An unresolvable supertype stays optimistic, like
			// the extends chain always was for this rule.
			if (index.supertypeDeclaresMember(owner, name)) return;
			if (interfaceRequires(index, ifaces, name)) return;
			final span: Null<Span> = fn.span;
			if (span == null) return;
			out.push({
				file: file,
				span: span,
				rule: 'prefer-inline',
				severity: Severity.Info,
				message: isEmptyBody(fn)
					? 'method \'$name\' has an empty body and no value references; mark it inline — the call compiles away'
					: 'method \'$name\' is a single-expression method with no value references; mark it inline'
			});
		});
	}

	/**
	 * Invoke `cb(name, fnNode, mods, metas)` for every `FnMember` of `cls`, where `mods` is the
	 * member's preceding modifier-kind run (`Public` / `Static` / `Inline` / …) and `metas` its
	 * preceding metadata names (`@:keep` / …), both reset at each member boundary. `final function`
	 * (`FinalModifiedMember`) and fields reset the run but are not methods.
	 */
	private static function forEachMethod(
		cls: QueryNode, branch: MemberBranchSeams, cb: (String, QueryNode, Array<String>, Array<String>) -> Void
	): Void {
		MemberBranchScan.eachMember(branch, cls, child -> MEMBER_KINDS.contains(child.kind), (member, run) -> {
			if (member.kind != 'FnMember') return;
			final name: Null<String> = member.name;
			if (name == null) return;
			final mods: Array<String> = [];
			final metas: Array<String> = [];
			for (mod in run) if (mod.kind == 'Meta' || mod.kind == 'MetaCall') {
				final nm: Null<String> = mod.name;
				if (nm != null) metas.push(nm);
			} else
				mods.push(mod.kind);
			cb(name, member, mods, metas);
		});
	}

	/**
	 * Whether `name` / `fn` is an inline candidate: a non-constructor method with a benefit-class body, not already `inline` / `dynamic` / `macro` / `override`, not `@:keep`, not self-recursive (a bare `name` / `this.name` in its body), and whose body is a benefit class (see `isBaseCandidateMethod`).
	 */
	private static function isCandidateMethod(name: String, fn: QueryNode, mods: Array<String>, metas: Array<String>, relaxed: Bool): Bool {
		return isBaseCandidateMethod(name, fn, mods, metas) && (relaxed || !bodyHasNullSafetyRisk(fn));
	}

	/**
	 * The candidate gates EXCEPT the context-sensitive null-safety one: a non-constructor method, not
	 * already `inline` / `dynamic` / `macro` / `override`, not `@:keep`, not self-recursive, whose body
	 * is a BENEFIT class — EMPTY (the call compiles away), or a single accessor / thin-forward /
	 * trivial-mutator / constant expression within the `MAX_BODY_NODES` budget. A body outside these
	 * classes (an allocation — `new`, array / object / interpolated-string literal, a reification —
	 * a lambda argument, a loop, a switch, a computed forward argument) gains nothing from `inline`
	 * and is never a candidate. `isCandidateMethod` layers the null-safety gate on top, unless
	 * `relaxed` (the oracle path) drops it.
	 */
	private static function isBaseCandidateMethod(name: String, fn: QueryNode, mods: Array<String>, metas: Array<String>): Bool {
		if (name == 'new') return false;
		if (mods.contains('Inline') || mods.contains('Dynamic') || mods.contains('Macro') || mods.contains('Override')) return false;
		if (metas.contains('@:keep')) return false;
		if (referencesSelf(fn, name)) return false;
		if (isEmptyBody(fn)) return true;
		final root: Null<QueryNode> = bodyRootExpr(fn);
		return root != null && (isAccessorOrForward(root) || isConstExpr(root)) && !bodyExceedsBudget(fn);
	}

	/**
	 * The single root expression of a candidate body: an `ExprBody`'s expression (a wrapping
	 * `ReturnExpr` peeled), or a one-statement `BlockBody`'s `ReturnStmt` / `ExprStmt` expression;
	 * null for every other shape (multi-statement, bodyless — the EMPTY body is class A, tested
	 * separately by `isEmptyBody`).
	 */
	private static function bodyRootExpr(fn: QueryNode): Null<QueryNode> {
		final body: Null<QueryNode> = bodyOf(fn);
		return body == null
			? null
			: switch body.kind {
				case 'ExprBody' if (body.children.length == 1): unwrapReturn(body.children[0]);
				case 'BlockBody' if (body.children.length == 1):
					final stmt: QueryNode = body.children[0];
					(stmt.kind == 'ReturnStmt' || stmt.kind == 'ExprStmt') && stmt.children.length == 1 ? stmt.children[0] : null;
				case _: null;
			}
	}

	/** `node` with a wrapping `ReturnExpr` peeled (an arrow `return EXPR` body projects the wrapper). */
	private static inline function unwrapReturn(node: QueryNode): QueryNode {
		return node.kind == 'ReturnExpr' && node.children.length == 1 ? node.children[0] : node;
	}

	/**
	 * Whether `node` is a bare field-access chain (`x`, `this.x`, `a.b.c`, `obj?.f`). A chain rooted at
	 * `super` is REJECTED — Haxe refuses `inline` on a body containing `super` ("Cannot inline function
	 * containing super"), and the no-oracle fix path would emit exactly that.
	 */
	private static function isChain(node: QueryNode): Bool {
		return switch node.kind {
			case 'IdentExpr': node.name != 'super';
			case k if (CHAIN_KINDS.contains(k)):
				node.children.length == 1 && isChain(node.children[0]);
			case _: false;
		}
	}

	/**
	 * Whether `node` is an allocation-free literal — a scalar, or a string literal WITHOUT
	 * interpolation parts (a plain single-quoted string carries only `Literal` children; any `Ident` /
	 * `Block` part makes it a runtime concatenation).
	 */
	private static inline function isPlainLiteral(node: QueryNode): Bool {
		return SCALAR_LIT_KINDS.contains(node.kind) || (node.kind == 'SingleStringExpr' || node.kind == 'DoubleStringExpr')
			&& !node.children.exists(c -> c.kind != 'Literal');
	}

	/** Whether `node` qualifies as a thin-forward argument / mutator operand: a bare chain or a plain literal. */
	private static inline function isSimpleOperand(node: QueryNode): Bool {
		return isChain(node) || isPlainLiteral(node);
	}

	/**
	 * Whether `root` is an accessor / thin-forward / trivial-mutator body: a bare chain read, a call
	 * whose callee is a chain and whose every argument is a simple operand, or an assignment-family
	 * node over a chain and a simple operand. Inlining any of these collapses the call into a direct
	 * read / write / forwarded call — the benefit class the rule exists for. A `.bind` callee is
	 * REJECTED: it allocates a closure, so the forward is not thin.
	 */
	private static function isAccessorOrForward(root: QueryNode): Bool {
		final kids: Array<QueryNode> = root.children;
		return isChain(root) || kids.length >= 1 && isChain(kids[0]) && kids[0].name != 'bind' && (
			root.kind == CALL_KIND
				? allSimpleOperands(kids, 1)
				: MUTATOR_KINDS.contains(root.kind) && (kids.length == 1 || isSimpleOperand(kids[1]))
		);
	}

	/** Whether every element of `nodes` from `start` on is a simple operand. */
	private static function allSimpleOperands(nodes: Array<QueryNode>, start: Int): Bool {
		for (i in start ... nodes.length) if (!isSimpleOperand(nodes[i])) return false;
		return true;
	}

	/**
	 * Whether `node` is a constant / small-arithmetic expression: literals, chains, and
	 * `CONST_OP_KINDS` operators only — nothing that allocates or calls, so the call site can fold
	 * it. The one non-expression child shape, `Is`'s type name (`Named`), is skipped.
	 */
	private static function isConstExpr(node: QueryNode): Bool {
		if (isSimpleOperand(node)) return true;
		if (!CONST_OP_KINDS.contains(node.kind)) return false;
		for (c in node.children) if (c.kind != 'Named' && !isConstExpr(c)) return false;
		return true;
	}

	/** Whether `fn`'s body is an empty `BlockBody` (the no-op arm's message discriminator). */
	private static inline function isEmptyBody(fn: QueryNode): Bool {
		final body: Null<QueryNode> = bodyOf(fn);
		return body != null && body.kind == 'BlockBody' && body.children.length == 0;
	}

	/** `fn`'s body child — its `ExprBody` or `BlockBody`, else null (a bodyless declaration). */
	private static function bodyOf(fn: QueryNode): Null<QueryNode> {
		return fn.children.find(c -> c.kind == 'ExprBody' || c.kind == 'BlockBody');
	}

	/** Whether `fn`'s body exceeds the `MAX_BODY_NODES` inline budget (node count of the body subtree). */
	private static inline function bodyExceedsBudget(fn: QueryNode): Bool {
		final body: Null<QueryNode> = bodyOf(fn);
		return body != null && nodeCount(body) > MAX_BODY_NODES;
	}

	/** The number of nodes in `node`'s subtree, itself included. */
	private static function nodeCount(node: QueryNode): Int {
		var total: Int = 1;
		for (c in node.children) total += nodeCount(c);
		return total;
	}

	/** Whether `node`'s subtree references `name` as a bare `IdentExpr` or a `this.<name>` `FieldAccess` — a self / recursive reference. */
	private static function referencesSelf(node: QueryNode, name: String): Bool {
		if (selfRefName(node) == name) return true;
		return node.children.exists(c -> referencesSelf(c, name));
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
		final isCall: Bool = node.kind == CALL_KIND;
		final children: Array<QueryNode> = node.children;
		for (i in 0...children.length) collectValueRefs(children[i], isCall && i == 0, candidateNames, out);
	}

	/** Whether `kind` is an identifier / field-access value node whose name could be a method-value reference. */
	private static inline function isAccessKind(kind: String): Bool {
		return kind == 'IdentExpr' || CHAIN_KINDS.contains(kind);
	}

	/**
	 * Record into `out` each name in `candidateNames` passed to a `Reflect.<m>(...)` call as a string
	 * literal — a method reached by reflection is not safe to inline.
	 */
	private static function collectReflectNames(node: QueryNode, candidateNames: Array<String>, out: Array<String>): Void {
		if (node.kind == CALL_KIND && node.children.length >= 1) {
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

	/**
	 * The unquoted value of a string-literal node, else null. A `DoubleStringExpr` carries the QUOTED
	 * text as its name; a plain `SingleStringExpr` carries the unquoted text in its one `Literal`
	 * child (an interpolated string has `Ident` / `Block` parts and yields null).
	 */
	private static function stringLiteralValue(node: QueryNode): Null<String> {
		return switch node.kind {
			case 'DoubleStringExpr':
				final raw: Null<String> = node.name;
				raw == null || raw.length < 2 ? null : raw.substring(1, raw.length - 1);
			case 'SingleStringExpr':
				node.children.length == 1 && node.children[0].kind == 'Literal' ? node.children[0].name : null;
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

	/**
	 * The member names declared by every STRICT subtype of `className` across the index — a method whose
	 * name appears here is overridden.
	 */
	private static function subtypeMemberNames(index: SymbolIndex, className: String): Array<String> {
		final out: Array<String> = [];
		for (fi in index.allFiles()) for (t in fi.types) if (t.name != className && index.isSubtype(t.name, className)) for (m in t.members)
			if (!out.contains(m.name)) out.push(m.name);
		return out;
	}

	/**
	 * Whether `fn`'s body contains a construct whose null-safety validity is CONTEXT-SENSITIVE, so
	 * inlining could break a caller: a `null` literal in a VALUE slot — a call argument, assignment
	 * RHS, return or ternary branch — but NOT a `==` / `!=` / `??` null-check operand (context-neutral).
	 * Haxe re-type-checks an inline body at every call site in the CALLER's null-safety mode, so a
	 * `null` that compiles in this class's (looser / off) context can fail Strict re-checking
	 * elsewhere. Over-skips a safe null-value body (the sound direction); a precise split would need
	 * null-flow typing.
	 */
	private static function bodyHasNullSafetyRisk(fn: QueryNode): Bool {
		final body: Null<QueryNode> = bodyOf(fn);
		return body != null && subtreeHasNullSafetyRisk(body, body.kind);
	}

	/** Whether `node`'s subtree contains a null literal in a value slot. */
	private static function subtreeHasNullSafetyRisk(node: QueryNode, parentKind: String): Bool {
		if (isRiskyHere(node, parentKind)) return true;
		for (c in node.children) if (subtreeHasNullSafetyRisk(c, node.kind)) return true;
		return false;
	}

	/**
	 * Whether `node` is a `null` literal in a VALUE slot (not a `==` / `!=` / `??` null-check operand) —
	 * the one context-sensitive construct a benefit-class body can still carry: a `null` argument /
	 * operand re-typechecks in the CALLER's null-safety mode once inlined.
	 */
	private static function isRiskyHere(node: QueryNode, parentKind: String): Bool {
		return node.kind == 'NullLit' && parentKind != 'Eq' && parentKind != 'NotEq' && parentKind != 'NullCoal';
	}


	/** The class-body member kinds that END a modifier run — a method and the three field forms. */
	private static final MEMBER_KINDS: Array<String> = ['FnMember', 'VarMember', 'FinalMember', 'FinalModifiedMember'];

}
