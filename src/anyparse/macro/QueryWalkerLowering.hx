package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.core.ShapeTree;

using Lambda;

/**
 * Pass 3Q of the macro pipeline - query-walker lowering.
 *
 * Walks the same `ShapeTree` as `Lowering` / `WriterLowering` /
 * `TransformLowering`, and emits the translation from the span-paired typed AST
 * (`SpanTypeSynth`'s `*S` types) into the engine's language-agnostic
 * `QueryNode` tree.
 *
 * This replaces a hand-written reflective walk. Every dispatch it emits was
 * previously a runtime probe over the same information: `Type.typeof` for
 * `Alt` / `Seq` / `Star`, `Reflect.fields` for a `Seq`'s field list,
 * `Type.enumParameters` for an `Alt` ctor's args, `Std.isOfType(p, Span)` for
 * the trailing span arg that `SpanTypeSynth` itself appends. The grammar shape
 * is known at compile time, so none of it needs discovering at run time - and
 * the generated switch is exhaustive, so a new grammar ctor becomes a compile
 * error instead of a silently missing node.
 *
 * Three mutually recursive functions are emitted per non-Terminal rule:
 *
 *  - `_walk<Leaf>S(v, into, withTypeRefs)` - append this value's `QueryNode`s
 *    to `into`. An `Alt` contributes one node per ctor (kind = ctor name, span
 *    = the ctor's `_span` arg); a plain `Seq` is TRANSPARENT and contributes
 *    its fields' nodes directly; a `@:spanned` `Seq` contributes one
 *    addressable node of its `_kind`.
 *  - `_nameOf<Leaf>S(v)` - the typed form of the old `extractName`: the
 *    node's display name, resolved through the same slot priority.
 *  - `_typeRefs<Leaf>S(v, into, fallbackSpan)` - the `TypeRef` projection used
 *    by `parseFileTypeRefs`, emitted only for rules reachable from a `type`
 *    field (in the Haxe grammar: `HxType` and what it reaches).
 *
 * Enum constructors are never called inside a `macro {}` block (that would
 * trigger macro-time type checking); patterns are built with `ECall` over a
 * `MacroStringTools.toFieldExpr` ctor reference, matching `TransformLowering`.
 */
class QueryWalkerLowering extends PairedShapeLowering {

	/** Struct fields consulted, in order, for a String-valued display name. */
	private static final NAME_STRING_SLOTS: Array<String> = ['name', 'type', 'varName'];

	/**
	 * Struct fields consulted, in order, for a name that lives one level deeper; the FIRST present one decides, even if it yields null.
	 *
	 * `decl` serves `HxVarMore` (`@:spanned('VarMore')`), whose single field holds the binding
	 * after a comma in `var a = 1, b = 2;`. It is inert on the only other `decl`-bearing struct,
	 * the TRANSPARENT `HxTopLevelDecl` — a Seq with no `@:spanned` tag materialises no node, so
	 * nothing ever asks it for a name.
	 */
	private static final NAME_UNWRAP_SLOTS: Array<String> = ['param', 'node', 'fn', 'decl'];

	/** Ctors of a single-Ref wrapper enum whose payload carries the name (`HxAnonVarBody`). */
	private static final NAME_UNWRAP_CTORS: Array<String> = ['Optional', 'Plain'];

	/** The `HxType` ctor whose body is a decl host - the one `type` field value the walk descends instead of skipping. */
	private static inline final ANON_CTOR: String = 'Anon';

	/** `HxType` ctors whose first operand names a nominal type - the `TypeRef` emit sites. */
	private static final TYPE_REF_NAME_CTORS: Array<String> = ['Named', 'DollarType'];

	/** Rule names reachable from a `type` field - the rules that need a `_typeRefs` function. */
	private final _typeRefRules: Array<String> = [];

	public function new(shape: ShapeBuilder.ShapeResult) {
		super(shape);
		collectTypeRefRules();
	}

	/**
	 * Build every generated function: one `_walk` and one `_nameOf` per
	 * non-Terminal rule, one `_typeRefs` per rule reachable from a `type` field,
	 * and the public entry rooted on `shape.root`.
	 */
	public function generate(): QueryWalkerResult {
		final ruleNames: Array<String> = sortedRuleNames();
		final walks: Array<WalkerFn> = [];
		final names: Array<WalkerFn> = [];
		final typeRefs: Array<WalkerFn> = [];
		for (rule in ruleNames) {
			final node: Null<ShapeNode> = _shape.rules.get(rule);
			if (node == null || node.kind == Terminal) continue;
			final ct: ComplexType = pairedComplexType(rule);
			walks.push({
				typePath: rule,
				fnName: walkFnName(rule),
				paramCT: ct,
				body: lowerWalk(rule, node)
			});
			names.push({
				typePath: rule,
				fnName: nameFnName(rule),
				paramCT: ct,
				body: lowerName(rule, node)
			});
			if (_typeRefRules.contains(rule)) typeRefs.push({
				typePath: rule,
				fnName: typeRefsFnName(rule),
				paramCT: ct,
				body: lowerTypeRefs(rule, node)
			});
		}

		return {
			rootTypePath: _shape.root,
			rootCT: pairedComplexType(_shape.root),
			rootFnName: walkFnName(_shape.root),
			walks: walks,
			names: names,
			typeRefs: typeRefs,
		};
	}

	// ---------------- paired-type resolution (mirrors SpanTypeSynth) ----------------
	/** Whether a Terminal rule's underlying primitive is `String` - the only shape the name resolution can read directly. */
	// ---------------- shape helpers ----------------

	/**
	 * Seed `_typeRefRules` from every `type` field in the grammar and close over
	 * what those rules reach, so a `_typeRefs` function exists exactly where the
	 * `parseFileTypeRefs` projection can reach and nowhere else.
	 */
	private function collectTypeRefRules(): Void {
		final seeds: Array<String> = [];
		for (node in _shape.rules) for (child in node.children) {
			// An Alt's children are ctors, whose own children are the args.
			final args: Array<ShapeNode> = node.kind == Alt ? child.children : [child];
			for (arg in args) if (fieldNameOf(arg) == 'type') {
				final ref: Null<String> = refOf(arg);
				if (ref != null && !isTerminalRule(ref) && !seeds.contains(ref)) seeds.push(ref);
			}
		}
		final pending: Array<String> = seeds.copy();
		while (pending.length > 0) {
			final rule: String = pending.shift();
			if (_typeRefRules.contains(rule)) continue;
			_typeRefRules.push(rule);
			final node: Null<ShapeNode> = _shape.rules.get(rule);
			if (node == null) continue;
			for (reached in reachableRules(node)) if (!_typeRefRules.contains(reached)) pending.push(reached);
		}
	}

	// ---------------- _walk lowering ----------------

	/**
	 * Body of `_walk<Leaf>S`. An `Alt` switches over its ctors; a `Seq` is
	 * transparent (its fields' nodes go straight into `into`) unless it carries
	 * an envelope `node` field or opted into addressability with `@:spanned`.
	 */
	private function lowerWalk(rule: String, node: ShapeNode): Expr {
		return switch node.kind {
			case Alt:
				{ expr: ESwitch(ident('v'), [for (branch in node.children) walkCase(rule, branch)], null), pos: Context.currentPos() };
			case Seq: lowerWalkSeq(rule, node);
			case Star:
				block(descend(node.children[0], ident('_e0'), 'into', 0).length == 0 ? [] : [
					macro for (_e0 in v) $e{block(descend(node.children[0], ident('_e0'), 'into', 0))}
				]);
			case Ref: block(descend(node, ident('v'), 'into', 0));
			case Terminal, Opt: macro {};
		};
	}

	/**
	 * One `case Ctor(_a0, ..., _span):` arm. Collects the ctor's args' nodes
	 * into a local, then contributes ONE node whose kind is the ctor name and
	 * whose span is the ctor's own trailing `_span` arg.
	 */
	private function walkCase(rule: String, branch: ShapeNode): Case {
		final ctor: String = branch.annotations[AnnotationKeys.BASE_CTOR];
		final argNames: Array<String> = [for (i in 0...branch.children.length) '_a$i'];
		final pattern: Expr = ctorPattern(rule, ctor, argNames);

		final body: Array<Expr> = [macro final _children: Array<anyparse.query.QueryNode> = []];
		for (i in 0...branch.children.length) for (e in descend(branch.children[i], ident(argNames[i]), '_children', 0)) body.push(e);
		final nameExpr: Expr = firstNonNullName([
			for (i in 0...branch.children.length) nameOfValue(branch.children[i], ident(argNames[i]))
		]);
		body.push(macro into.push(
			new anyparse.query.QueryNode($v{ctor}, $nameExpr, anyparse.query.QueryWalkSupport.orderBySpan(_children), _span)
		));
		return { values: [pattern], expr: block(body) };
	}

	/**
	 * Body of `_walk<Leaf>S` for a `Seq` rule, in the order the reflective walk
	 * tested these cases: an envelope `node` field makes the struct transparent
	 * on that one field; `@:spanned` makes it an addressable node of its own
	 * `_kind`; otherwise it is transparent and its fields append to the caller's
	 * accumulator.
	 */
	private function lowerWalkSeq(rule: String, node: ShapeNode): Expr {
		final envelope: Null<ShapeNode> = seqField(node, PairedShapeLowering.ENVELOPE_FIELD);
		if (envelope != null) return block(descend(envelope, field(ident('v'), PairedShapeLowering.ENVELOPE_FIELD), 'into', 0));

		if (!isSpanned(node)) {
			final out: Array<Expr> = [for (child in node.children) for (e in seqFieldDescent(child, 'into', null)) e];
			return block(out);
		}

		final body: Array<Expr> = [macro final _children: Array<anyparse.query.QueryNode> = []];
		for (child in node.children) for (e in seqFieldDescent(child, '_children', field(ident('v'), PairedShapeLowering.SPAN_FIELD)))
			body.push(e);
		final nameExpr: Expr = call(nameFnName(rule), [ident('v')]);
		body.push(macro into.push(
			new anyparse.query.QueryNode(v._kind, $nameExpr, anyparse.query.QueryWalkSupport.orderBySpan(_children), v._span)
		));
		return block(body);
	}

	/**
	 * Descend one `Seq` FIELD. The `name` slot is the node's display name, never
	 * a child. A `type` slot is a name-slot leaf and is skipped - except an
	 * `HxType.Anon`, whose body hosts declarations, and except under
	 * `withTypeRefs`, where the skipped type is surfaced as `TypeRef` nodes.
	 */
	private function seqFieldDescent(child: ShapeNode, intoName: String, fallbackSpan: Null<Expr>): Array<Expr> {
		final name: String = fieldNameOf(child);
		if (name == 'name') return [];
		final access: Expr = field(ident('v'), name);
		if (name != 'type') return descend(child, access, intoName, 0);

		final ref: Null<String> = refOf(child);
		// A `Null<HxType>` slot is bound to a local first: the switch below must
		// not run on null (`case _` does not match it), and the reflective
		// version reached `isLeafValue(null)` and did nothing.
		final optional: Bool = isOptional(child);
		final value: Expr = optional ? ident('_ty') : access;
		final fallback: Expr = fallbackSpan ?? macro null;
		final refsCall: Expr = ref != null && _typeRefRules.contains(ref)
			? call(typeRefsFnName(ref), [value, ident(intoName), fallback])
			: macro {};
		final skipArm: Expr = macro if (withTypeRefs) $refsCall;
		final core: Expr = if (ref == null || !altHasCtor(ref, ANON_CTOR))
			skipArm;
		else {
			final anonPattern: Expr = ctorPattern(ref, ANON_CTOR, [for (_ in 0...ctorArity(ref, ANON_CTOR)) '_']);
			final descendArm: Expr = block(descendCore(child, value, intoName, 0));
			{
				expr: ESwitch(value, [
					{ values: [anonPattern], expr: descendArm },
					{ values: [macro _], expr: skipArm }
				], null),
				pos: Context.currentPos()
			};
		}

		return !optional ? [core] : [
			block([
				{ expr: EVars([{ name: '_ty', type: null, expr: access }]), pos: Context.currentPos() },
				macro if (_ty != null) $core
			])
		];
	}

	/**
	 * Descend one value into `intoName`, guarding an optional field and looping
	 * a `Star`. A Terminal contributes nothing - it is a primitive leaf.
	 * `depth` keeps nested `Star` loop variables from colliding.
	 */
	private function descend(child: ShapeNode, access: Expr, intoName: String, depth: Int): Array<Expr> {
		final inner: Array<Expr> = descendCore(child, access, intoName, depth);
		if (inner.length == 0 || !isOptional(child)) return inner;
		final local: String = '_o$depth';
		final guarded: Array<Expr> = descendCore(child, ident(local), intoName, depth);
		return [
			block([
				{ expr: EVars([{ name: local, type: null, expr: access }]), pos: Context.currentPos() },
				macro if ($i{local} != null) $e{block(guarded)}
			])
		];
	}

	private inline function descendCore(child: ShapeNode, access: Expr, intoName: String, depth: Int): Array<Expr> {
		return switch child.kind {
			case Ref:
				final ref: String = child.annotations[AnnotationKeys.BASE_REF];
				isTerminalRule(ref) ? [] : [call(walkFnName(ref), [access, ident(intoName), ident('withTypeRefs')])];
			case Star:
				final loopVar: String = '_e$depth';
				final body: Array<Expr> = descend(child.children[0], ident(loopVar), intoName, depth + 1);
				body.length == 0 ? [] : [macro for ($i{loopVar} in $access) $e{block(body)}];
			case Terminal: [];
			case Seq, Alt, Opt:
				Context.fatalError(
					'QueryWalkerLowering: inline ${child.kind} child cannot be walked - named rules must arrive as Ref',
					Context.currentPos()
				);
				throw 'unreachable';
		};
	}

	/**
	 * `_nameOf` of one value, or null when the value can never carry a name. A
	 * `Star` never can: the reflective `extractName` fell through its `TClass`
	 * arm and returned null for an array, so a repeated field is not a name slot.
	 */
	private function nameOfValue(child: ShapeNode, access: Expr): Null<Expr> {
		final ref: Null<String> = refOf(child);
		return if (ref == null)
			null
		else if (isStringTerminal(ref))
			macro ($access: String)
		else if (isTerminalRule(ref))
			null
		else
			call(nameFnName(ref), [access]);
	}

	/** Fold candidate name expressions into `a ?? b ?? ... ?? null`, dropping the ones that can never yield a name. */
	private function firstNonNullName(candidates: Array<Null<Expr>>): Expr {
		var out: Expr = macro null;
		var i: Int = candidates.length - 1;
		while (i >= 0) {
			final c: Null<Expr> = candidates[i];
			if (c != null) out = macro $c ?? $out;
			i--;
		}
		return out;
	}

	// ---------------- _nameOf lowering ----------------

	/**
	 * Body of `_nameOf<Leaf>S` - the typed form of the reflective `extractName`,
	 * with its slot priority preserved exactly:
	 *
	 *  1. A `Seq`'s `name` / `type` / `varName` field, in that order, but ONLY
	 *     when that field is a String (a `type` holding an `HxType` is not one,
	 *     and the reflective version fell through on it).
	 *  2. Otherwise the FIRST present of `param` / `node` / `fn`, whose result is
	 *     returned even when null - the reflective version returned rather than
	 *     falling through, and later slots were never consulted.
	 *  3. For an `Alt`, only the single-Ref wrapper ctors `Optional` / `Plain`
	 *     surface a name; every other ctor is null, because a general recurse
	 *     would leak names onto non-decl nodes.
	 */
	private function lowerName(rule: String, node: ShapeNode): Expr {
		return switch node.kind {
			case Seq: lowerNameSeq(node);
			case Alt:
				final cases: Array<Case> = [for (branch in node.children) nameCase(rule, branch)];
				block([
					{ expr: ESwitch(ident('v'), cases, null), pos: Context.currentPos() },
					macro return null
				]);
			case Ref:
				final n: Null<Expr> = nameOfValue(node, ident('v'));
				n == null ? macro return null : macro return $n;
			case Star, Terminal, Opt: macro return null;
		};
	}

	private function lowerNameSeq(node: ShapeNode): Expr {
		final out: Array<Expr> = [];
		for (slot in NAME_STRING_SLOTS) {
			final f: Null<ShapeNode> = seqField(node, slot);
			if (f == null) continue;
			final ref: Null<String> = refOf(f);
			final isString: Bool = ref != null ? isStringTerminal(ref) : f.kind == Terminal && isStringShape(f);
			if (!isString) continue;
			final access: Expr = field(ident('v'), slot);
			out.push(macro if ($access != null) return ($access: String));
		}
		for (slot in NAME_UNWRAP_SLOTS) {
			final f: Null<ShapeNode> = seqField(node, slot);
			if (f == null) continue;
			final access: Expr = field(ident('v'), slot);
			final n: Null<Expr> = nameOfValue(f, access);
			// The reflective version RETURNED here, so only the first present
			// unwrap slot is ever consulted - later ones stay unreachable.
			out.push(n == null ? macro return null : (isOptional(f) ? macro return $access == null ? null : $n : macro return $n));
			break;
		}
		out.push(macro return null);
		return block(out);
	}

	/** `case Ctor(...): return <first non-null arg name>;` for a wrapper ctor, `case Ctor(...):` (fall to null) otherwise. */
	private function nameCase(rule: String, branch: ShapeNode): Case {
		final ctor: String = branch.annotations[AnnotationKeys.BASE_CTOR];
		final argNames: Array<String> = [for (i in 0...branch.children.length) '_a$i'];
		final pattern: Expr = ctorPattern(rule, ctor, NAME_UNWRAP_CTORS.contains(ctor) ? argNames : [for (_ in argNames) '_']);
		if (!NAME_UNWRAP_CTORS.contains(ctor)) return { values: [pattern], expr: macro {} };
		final nameExpr: Expr = firstNonNullName([
			for (i in 0...branch.children.length) nameOfValue(branch.children[i], ident(argNames[i]))
		]);
		return { values: [pattern], expr: macro return $nameExpr };
	}

	/** Whether an inline (unnamed) Terminal field's primitive is `String`. */
	// ---------------- _typeRefs lowering ----------------

	/**
	 * Body of `_typeRefs<Leaf>S` - the `parseFileTypeRefs` projection. Surfaces
	 * every nominal type name inside a type value as a `TypeRef` node so
	 * `apq uses` can see it. `Anon` is skipped here: its body is already
	 * surfaced by the decl-host descent in `_walk`.
	 */
	private function lowerTypeRefs(rule: String, node: ShapeNode): Expr {
		return switch node.kind {
			case Alt:
				{ expr: ESwitch(ident('v'), [for (branch in node.children) typeRefsCase(rule, branch)], null), pos: Context.currentPos() };
			case Seq:
				// `_s` is the span the recursion passes down; outside an Alt ctor
				// there is no own span, so the caller's fallback carries through.
				final bind: Expr = macro final _s: Null<anyparse.runtime.Span> = fallbackSpan;
				final envelope: Null<ShapeNode> = seqField(node, PairedShapeLowering.ENVELOPE_FIELD);
				if (envelope != null)
					return block([bind].concat(typeRefsDescend(envelope, field(ident('v'), PairedShapeLowering.ENVELOPE_FIELD), 0)));
				final out: Array<Expr> = [bind];
				for (child in node.children) if (fieldNameOf(child) != 'name')
					for (e in typeRefsDescend(child, field(ident('v'), fieldNameOf(child)), 0)) out.push(e);
				block(out);
			case Star:
				block(
					[(macro final _s: Null<anyparse.runtime.Span> = fallbackSpan)].concat(typeRefsDescend(node.children[0], ident('v'), 0))
				);
			case Ref:
				block([(macro final _s: Null<anyparse.runtime.Span> = fallbackSpan)].concat(typeRefsDescend(node, ident('v'), 0)));
			case Terminal, Opt: macro {};
		};
	}

	/**
	 * One ctor arm of `_typeRefs`. `Named` / `DollarType` emit the `TypeRef` for
	 * their head operand and then recurse it for nested type parameters; `Anon`
	 * emits nothing; every other ctor just recurses its operands. The ctor's own
	 * `_span` is the node position, replacing the caller's `fallbackSpan`.
	 */
	private function typeRefsCase(rule: String, branch: ShapeNode): Case {
		final ctor: String = branch.annotations[AnnotationKeys.BASE_CTOR];
		final argNames: Array<String> = [for (i in 0...branch.children.length) '_a$i'];

		if (ctor == ANON_CTOR) return { values: [ctorPattern(rule, ctor, [for (_ in argNames) '_'])], expr: macro {} };

		final pattern: Expr = ctorPattern(rule, ctor, argNames);
		final body: Array<Expr> = [];
		if (TYPE_REF_NAME_CTORS.contains(ctor)) {
			// Only the FIRST operand is the name head; the reflective version
			// broke out of its loop after it.
			if (branch.children.length > 0) {
				final head: ShapeNode = branch.children[0];
				final access: Expr = ident(argNames[0]);
				final n: Null<Expr> = nameOfValue(head, access);
				if (n != null) body.push(macro {
					final _nm: Null<String> = $n;
					if (_nm != null) into.push(new anyparse.query.QueryNode('TypeRef', _nm, [], _span));
				});
				for (e in typeRefsDescend(head, access, 0)) body.push(e);
			}
		} else
			for (i in 0...branch.children.length) for (e in typeRefsDescend(branch.children[i], ident(argNames[i]), 0)) body.push(e);

		return body.length == 0
			? {
				values: [pattern],
				expr: macro {}
			}
			: {
				values: [pattern],
				expr: block([macro final _s: anyparse.runtime.Span = _span].concat(body))
			};
	}

	/** Recurse one value for nested type refs, guarding optionality and looping arrays. */
	private function typeRefsDescend(child: ShapeNode, access: Expr, depth: Int): Array<Expr> {
		final inner: Array<Expr> = typeRefsDescendCore(child, access, depth);
		if (inner.length == 0 || !isOptional(child)) return inner;
		final local: String = '_t$depth';
		final guarded: Array<Expr> = typeRefsDescendCore(child, ident(local), depth);
		return [
			block([
				{ expr: EVars([{ name: local, type: null, expr: access }]), pos: Context.currentPos() },
				macro if ($i{local} != null) $e{block(guarded)}
			])
		];
	}

	private inline function typeRefsDescendCore(child: ShapeNode, access: Expr, depth: Int): Array<Expr> {
		return switch child.kind {
			case Ref:
				final ref: String = child.annotations[AnnotationKeys.BASE_REF];
				_typeRefRules.contains(ref) ? [call(typeRefsFnName(ref), [access, ident('into'), ident('_s')])] : [];
			case Star:
				final loopVar: String = '_r$depth';
				final body: Array<Expr> = typeRefsDescend(child.children[0], ident(loopVar), depth + 1);
				body.length == 0 ? [] : [macro for ($i{loopVar} in $access) $e{block(body)}];
			case Terminal, Seq, Alt, Opt: [];
		};
	}

	/** Every named rule a node's own children reference directly (through `Star` elements too), Terminals excluded. */
	private function reachableRules(node: ShapeNode): Array<String> {
		final out: Array<String> = [];
		inline function visit(n: ShapeNode): Void {
			final target: ShapeNode = n.kind == Star && n.children.length > 0 ? n.children[0] : n;
			final ref: Null<String> = refOf(target);
			if (ref != null && !isTerminalRule(ref) && !out.contains(ref)) out.push(ref);
		}
		for (child in node.children) {
			visit(child);
			for (arg in child.children) visit(arg);
		}
		return out;
	}

	/** Generated walk-function name for a rule type path (`anyparse.grammar.haxe.HxExpr` to `_walkHxExprS`). */
	public static inline function walkFnName(typePath: String): String {
		return '_walk${PairedShapeLowering.simpleName(typePath)}S';
	}

	/** Generated name-resolution function name for a rule type path. */
	public static inline function nameFnName(typePath: String): String {
		return '_nameOf${PairedShapeLowering.simpleName(typePath)}S';
	}

	/** Generated type-ref projection function name for a rule type path. */
	public static inline function typeRefsFnName(typePath: String): String {
		return '_typeRefs${PairedShapeLowering.simpleName(typePath)}S';
	}

}

/**
 * One generated walker function descriptor.
 */
typedef WalkerFn = {
	/** Full grammar type path this function serves. */
	final typePath: String;

	/** Generated function name. */
	final fnName: String;

	/** The paired `*S` type - the function's value parameter. */
	final paramCT: ComplexType;

	/** Body expression. */
	final body: Expr;
};

/**
 * Result of query-walker lowering: every function to emit plus the root entry.
 */
typedef QueryWalkerResult = {
	/** Full grammar root type path. */
	final rootTypePath: String;

	/** Paired root type - the public entry's `root` parameter. */
	final rootCT: ComplexType;

	/** `_walk` function name for the root type, which the public entry delegates to. */
	final rootFnName: String;

	/** One `_walk<T>` per non-Terminal rule. */
	final walks: Array<WalkerFn>;

	/** One `_nameOf<T>` per non-Terminal rule. */
	final names: Array<WalkerFn>;

	/** One `_typeRefs<T>` per rule reachable from a `type` field. */
	final typeRefs: Array<WalkerFn>;
};
#end
