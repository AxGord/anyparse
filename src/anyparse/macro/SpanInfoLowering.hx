package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.core.ShapeTree;

/**
 * Pass 3S of the macro pipeline - span-info lowering.
 *
 * Emits the `SpanTypeInfo` projection: the six span-indexed maps a check asks
 * for when it needs detail the `QueryNode` tree drops (a binding's declared
 * type, a function's return type, a property's accessor kinds, the verbatim
 * source of a type annotation).
 *
 * This replaces a reflective walk plus a visitor that probed nodes BY FIELD
 * NAME - `Reflect.hasField(node, 'type' | 'returnType' | 'access' | 'name' |
 * 'target' | 'expr')` - across every grammar type. Which rules carry those
 * fields is a property of the grammar, so it is decided here, once, at compile
 * time; the generated code reads the fields directly.
 *
 * Per non-Terminal rule one `_spanInfo<Leaf>S(v, cur, b, source)` is emitted,
 * threading the nearest enclosing binding span exactly as the reflective walk
 * did: an `Alt` ctor contributes its own `_span` to everything below it and is
 * itself never a write site; a `Seq` writes at its own `_span` when it is
 * `@:spanned` and at the inherited span otherwise. Two small per-rule helpers
 * back the writes - `_nominalName<Leaf>S` (the `Named` ctor's simple type name)
 * and `_spanOf<Leaf>S` (any ctor's own span).
 */
class SpanInfoLowering extends PairedShapeLowering {

	/** The `HxType` ctor that names a nominal type; its first operand carries the name. */
	private static inline final NAMED_CTOR: String = 'Named';

	/** Struct field holding a binding's declared type - the `declaredTypes` / `declaredTypeSources` write site. */
	private static inline final TYPE_FIELD: String = 'type';

	/** Struct field holding a function's return type. */
	private static inline final RETURN_TYPE_FIELD: String = 'returnType';

	/** Struct field holding a property's accessor clause. */
	private static inline final ACCESS_FIELD: String = 'access';

	/** Struct field that, together with `name`, marks a type-parameter declaration - the `typeParamNames` collect site. */
	private static inline final CONSTRAINT_MORE_FIELD: String = 'constraintMore';

	/** Accessor ids that denote a plain stored slot; anything else runs code. */
	private static final STORED_ACCESSORS: Array<String> = ['default', 'null', 'never'];

	/** Rules a `type` / `returnType` field can point at that are enums - the only ones that yield a nominal name or a span. */
	private final _nominalRules: Array<String> = [];

	/** Element type of the accessor clause's `ids` array, or null when no rule has that shape - the emitted accessor test is typed on it. */
	private var _accessorIdCT: Null<ComplexType> = null;

	public function new(shape: ShapeBuilder.ShapeResult) {
		super(shape);
		collectNominalRules();
	}

	/** Generated span-info walk name for a rule type path. */
	public static inline function spanInfoFnName(typePath: String): String {
		return '_spanInfo${PairedShapeLowering.simpleName(typePath)}S';
	}

	/** Generated nominal-name helper name for a rule type path. */
	public static inline function nominalFnName(typePath: String): String {
		return '_nominalName${PairedShapeLowering.simpleName(typePath)}S';
	}

	/** Generated own-span helper name for a rule type path. */
	public static inline function spanOfFnName(typePath: String): String {
		return '_spanOf${PairedShapeLowering.simpleName(typePath)}S';
	}

	/**
	 * Build every generated function: one `_spanInfo` per non-Terminal rule, and
	 * the `_nominalName` / `_spanOf` pair for each enum rule a `type` or
	 * `returnType` field can point at.
	 */
	public function generate(): SpanInfoResult {
		final walks: Array<SpanInfoFn> = [];
		final nominals: Array<SpanInfoFn> = [];
		final spanOfs: Array<SpanInfoFn> = [];
		for (rule in sortedRuleNames()) {
			final node: Null<ShapeNode> = _shape.rules.get(rule);
			if (node == null || node.kind == Terminal) continue;
			final ct: ComplexType = pairedComplexType(rule);
			walks.push({
				typePath: rule,
				fnName: spanInfoFnName(rule),
				paramCT: ct,
				body: lowerSpanInfo(rule, node)
			});
			if (_nominalRules.contains(rule)) {
				nominals.push({
					typePath: rule,
					fnName: nominalFnName(rule),
					paramCT: ct,
					body: lowerNominalName(rule, node)
				});
				spanOfs.push({
					typePath: rule,
					fnName: spanOfFnName(rule),
					paramCT: ct,
					body: lowerSpanOf(rule, node)
				});
			}
		}
		return {
			rootTypePath: _shape.root,
			rootCT: pairedComplexType(_shape.root),
			rootFnName: spanInfoFnName(_shape.root),
			walks: walks,
			nominals: nominals,
			spanOfs: spanOfs,
			accessorIdCT: _accessorIdCT,
		};
	}

	/**
	 * Seed the nominal-rule set from every `type` / `returnType` field that
	 * points at an `Alt`. The reflective `nominalTypeName` / `typeFieldSpan`
	 * both opened with a `Type.typeof(v).match(TEnum(_))` test, so a `type`
	 * field of a struct or a String rule produced nothing - here that is simply
	 * a rule with no helper and no write site.
	 */
	private function collectNominalRules(): Void {
		for (_ => node in _shape.rules) for (child in node.children) {
			final args: Array<ShapeNode> = node.kind == Alt ? child.children : [child];
			for (arg in args) if (fieldNameOf(arg) == TYPE_FIELD || fieldNameOf(arg) == RETURN_TYPE_FIELD) {
				final ref: Null<String> = refOf(arg);
				if (ref == null || _nominalRules.contains(ref)) continue;
				final target: Null<ShapeNode> = _shape.rules.get(ref);
				if (target != null && target.kind == Alt) _nominalRules.push(ref);
			}
		}
	}

	/**
	 * Body of `_spanInfo<Leaf>S`. An `Alt` only rebinds the threaded span to its
	 * ctor's own `_span` and recurses; a `Seq` is the write site.
	 */
	private function lowerSpanInfo(rule: String, node: ShapeNode): Expr {
		return switch node.kind {
			case Alt:
				{ expr: ESwitch(ident('v'), [for (branch in node.children) spanInfoCase(rule, branch)], null), pos: Context.currentPos() };
			case Seq: lowerSpanInfoSeq(node);
			case Star: block(recurse(node.children[0], ident('v'), ident('cur'), 0));
			case Ref: block(recurse(node, ident('v'), ident('cur'), 0));
			case Terminal, Opt: macro {};
		};
	}

	/** `case Ctor(_a0, ..., _span):` - the ctor's span becomes the threaded span for everything below it. */
	private function spanInfoCase(rule: String, branch: ShapeNode): Case {
		final argNames: Array<String> = [for (i in 0...branch.children.length) '_a$i'];
		final pattern: Expr = ctorPattern(rule, branch.annotations.get(AnnotationKeys.BASE_CTOR), argNames);
		final body: Array<Expr> = [];
		for (i in 0...branch.children.length)
			for (e in recurse(branch.children[i], ident(argNames[i]), ident(PairedShapeLowering.SPAN_FIELD), 0)) body.push(e);
		return { values: [pattern], expr: body.length == 0 ? macro {} : block(body) };
	}

	/**
	 * Body of `_spanInfo<Leaf>S` for a `Seq`: bind the effective span, emit the
	 * writes this struct's fields justify, then recurse every field under that
	 * span. Unlike the `QueryNode` walk, NO field is skipped here - the
	 * reflective walk recursed `Reflect.fields` wholesale.
	 */
	private function lowerSpanInfoSeq(node: ShapeNode): Expr {
		final own: Expr = isSpanned(node) ? field(ident('v'), PairedShapeLowering.SPAN_FIELD) : ident('cur');
		final body: Array<Expr> = [
			{ expr: EVars([{ name: '_sp', type: null, expr: own }]), pos: Context.currentPos() }
		];
		// A type-parameter name is collected with NO span guard: the reflective
		// scan reached this visitor directly, not through the span-filtered one.
		final tpCollect: Null<Expr> = typeParamCollect(node);
		if (tpCollect != null) body.push(tpCollect);
		final writes: Array<Expr> = spanInfoWrites(node);
		if (writes.length > 0) body.push(macro if (_sp != null) $e{block(writes)});
		for (child in node.children) for (e in recurse(child, field(ident('v'), fieldNameOf(child)), ident('_sp'), 0)) body.push(e);
		return block(body);
	}

	/**
	 * The map writes a `Seq` justifies, keyed on its effective span `_sp`. Every
	 * condition the reflective visitor tested at run time - which of `type` /
	 * `returnType` / `access` the node carries, and for `castTargetSources`
	 * whether it has no `name` but does have a `target` or `expr` - is answered
	 * here from the shape instead.
	 */
	private function spanInfoWrites(node: ShapeNode): Array<Expr> {
		final out: Array<Expr> = [];

		final typeField: Null<ShapeNode> = seqField(node, TYPE_FIELD);
		final typeRule: Null<String> = typeField == null ? null : refOf(typeField);
		if (typeField != null && typeRule != null && _nominalRules.contains(typeRule)) {
			// A cast-like node is one the grammar gives a type and an operand but
			// no name - `cast (e : T)` and friends, which the consumer wants
			// separated from ordinary declared types.
			final isCastSite: Bool = seqField(node, 'name') == null && (seqField(node, 'target') != null || seqField(node, 'expr') != null);
			final castWrite: Expr = isCastSite ? macro b.castTargetSources[_sp.from] = _src : macro {};
			out.push(guardOptional(
				typeField, field(ident('v'), TYPE_FIELD), '_tv', macro {
					final _nm: Null<String> = $e{call(nominalFnName(typeRule), [ident('_tv')])};
					if (_nm != null) b.declaredTypes[_sp.from] = _nm;
					final _ts: Null<anyparse.runtime.Span> = $e{call(spanOfFnName(typeRule), [ident('_tv')])};
					if (_ts != null) {
						final _src: String = source.substring(_ts.from, _ts.to);
						b.declaredTypeSources[_sp.from] = _src;
						$castWrite;
					}
				}
			));
		}

		final retField: Null<ShapeNode> = seqField(node, RETURN_TYPE_FIELD);
		final retRule: Null<String> = retField == null ? null : refOf(retField);
		if (retField != null && retRule != null && _nominalRules.contains(retRule)) out.push(guardOptional(
			retField, field(ident('v'), RETURN_TYPE_FIELD), '_rv', macro {
				final _rn: Null<String> = $e{call(nominalFnName(retRule), [ident('_rv')])};
				if (_rn != null) b.returnTypes[_sp.from] = _rn;
			}
		));

		final accessField: Null<ShapeNode> = seqField(node, ACCESS_FIELD);
		final ids: Null<ShapeNode> = accessField == null ? null : accessorIdsOf(accessField);
		if (ids != null) {
			if (_accessorIdCT == null) _accessorIdCT = accessorIdElemCT(ids);
			out.push(guardOptional(
				accessField, field(ident('v'), ACCESS_FIELD), '_ac', macro {
					b.propertyAccessors[_sp.from] = _accessorRunsCode(_ac.ids, 0);
					b.propertyWriteAccessors[_sp.from] = _accessorRunsCode(_ac.ids, 1);
				}
			));
		}

		return out;
	}

	/**
	 * The type-parameter name collect for a `Seq`, or null when it is not one. A
	 * type-parameter declaration is the shape carrying BOTH a `name` and a
	 * `constraintMore` - the same pair the reflective scan tested for.
	 */
	private function typeParamCollect(node: ShapeNode): Null<Expr> {
		final nameField: Null<ShapeNode> = seqField(node, 'name');
		if (nameField == null || seqField(node, CONSTRAINT_MORE_FIELD) == null) return null;
		final n: Null<Expr> = nominalOperandName(nameField, field(ident('v'), 'name'));
		if (n == null) return null;
		// `tp` is the generated function's PARAMETER: inside a `macro {}` block a
		// bare `tp.contains(...)` resolves at macro time and fails, so the
		// identifier is built by hand.
		final acc: Expr = ident('tp');
		return macro {
			final _tp: Null<String> = $n;
			if (_tp != null && !$acc.contains(_tp)) $acc.push(_tp);
		};
	}

	/** The `ids` field of the rule an `access` slot points at, or null when the slot is not the accessor-clause shape. */
	private function accessorIdsOf(accessField: ShapeNode): Null<ShapeNode> {
		final ref: Null<String> = refOf(accessField);
		if (ref == null) return null;
		final target: Null<ShapeNode> = _shape.rules.get(ref);
		return target == null ? null : seqField(target, 'ids');
	}

	/** Bind `access` to `local` and run `body` under it, adding a null guard when the field is optional. */
	private function guardOptional(child: ShapeNode, access: Expr, local: String, body: Expr): Expr {
		final bind: Expr = { expr: EVars([{ name: local, type: null, expr: access }]), pos: Context.currentPos() };
		return isOptional(child) ? block([bind, macro if ($i{local} != null) $body]) : block([bind, body]);
	}

	/** Recurse one value under the threaded span `spanExpr`, guarding optionality and looping arrays. */
	private function recurse(child: ShapeNode, access: Expr, spanExpr: Expr, depth: Int): Array<Expr> {
		final inner: Array<Expr> = recurseCore(child, access, spanExpr, depth);
		if (inner.length == 0 || !isOptional(child)) return inner;
		final local: String = '_n$depth';
		return [
			block([
				{ expr: EVars([{ name: local, type: null, expr: access }]), pos: Context.currentPos() },
				macro if ($i{local} != null) $e{block(recurseCore(child, ident(local), spanExpr, depth))}
			])
		];
	}

	private inline function recurseCore(child: ShapeNode, access: Expr, spanExpr: Expr, depth: Int): Array<Expr> {
		return switch child.kind {
			case Ref:
				final ref: String = child.annotations.get(AnnotationKeys.BASE_REF);
				isTerminalRule(ref) ? [] : [
					call(spanInfoFnName(ref), [access, spanExpr, ident('b'), ident('source'), ident('tp')])
				];
			case Star:
				final loopVar: String = '_s$depth';
				final body: Array<Expr> = recurse(child.children[0], ident(loopVar), spanExpr, depth + 1);
				body.length == 0 ? [] : [macro for ($i{loopVar} in $access) $e{block(body)}];
			case Terminal: [];
			case Seq, Alt, Opt:
				Context.fatalError(
					'SpanInfoLowering: inline ${child.kind} child cannot be walked - named rules must arrive as Ref', Context.currentPos()
				);
				throw 'unreachable';
		};
	}

	/**
	 * Body of `_nominalName<Leaf>S`: the simple name of a `Named` value, package
	 * stripped. Every other ctor is null - the reflective version keyed on the
	 * ctor name the same way.
	 */
	private function lowerNominalName(rule: String, node: ShapeNode): Expr {
		final cases: Array<Case> = [];
		for (branch in node.children) {
			final ctor: String = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			final argNames: Array<String> = [for (i in 0...branch.children.length) '_a$i'];
			if (ctor != NAMED_CTOR) {
				cases.push({ values: [ctorPattern(rule, ctor, [for (_ in argNames) '_'])], expr: macro {} });
				continue;
			}
			final candidates: Array<Expr> = [];
			for (i in 0...branch.children.length) {
				final n: Null<Expr> = nominalOperandName(branch.children[i], ident(argNames[i]));
				if (n != null) candidates.push(n);
			}
			if (candidates.length == 0) {
				cases.push({ values: [ctorPattern(rule, ctor, [for (_ in argNames) '_'])], expr: macro {} });
				continue;
			}
			var picked: Expr = macro null;
			var i: Int = candidates.length - 1;
			while (i >= 0) {
				final c: Expr = candidates[i];
				picked = macro $c ?? $picked;
				i--;
			}
			cases.push({
				values: [ctorPattern(rule, ctor, argNames)],
				expr: macro {
					final _raw: Null<String> = $picked;
					if (_raw != null) {
						final _dot: Int = _raw.lastIndexOf('.');
						return _dot == -1 ? _raw : _raw.substring(_dot + 1);
					}
				}
			});
		}
		return block([
			{ expr: ESwitch(ident('v'), cases, null), pos: Context.currentPos() },
			macro return null
		]);
	}

	/** The walker's `_nameOf` for one `Named` operand, or null when the operand can carry no name. */
	private function nominalOperandName(child: ShapeNode, access: Expr): Null<Expr> {
		final ref: Null<String> = refOf(child);
		return ref == null
			? null
			: isStringTerminal(ref)
				? macro ($access: String)
				: isTerminalRule(ref) ? null : call(QueryWalkerLowering.nameFnName(ref), [access]);
	}

	/** Body of `_spanOf<Leaf>S`: a paired ctor always carries its own `_span`, so every arm returns it. */
	private function lowerSpanOf(rule: String, node: ShapeNode): Expr {
		final cases: Array<Case> = [
			for (branch in node.children)
				{
					values: [
						ctorPattern(rule, branch.annotations.get(AnnotationKeys.BASE_CTOR), [for (_ in 0...branch.children.length) '_'])
					],
					expr: macro return _span
				}
		];
		return block([
			{ expr: ESwitch(ident('v'), cases, null), pos: Context.currentPos() },
			macro return null
		]);
	}

	/** The declared element type of an accessor `ids` array, so the emitted test names it instead of going through Dynamic. */
	private function accessorIdElemCT(ids: ShapeNode): Null<ComplexType> {
		if (ids.kind != Star || ids.children.length == 0) return null;
		final ref: Null<String> = refOf(ids.children[0]);
		return ref == null ? null : pairedComplexType(ref);
	}

	/** The accessor ids that denote a plain stored slot, as an array-literal expression for the emitted test. */
	public static function storedAccessorsExpr(): Expr {
		final elems: Array<Expr> = [
			for (id in STORED_ACCESSORS) ({ expr: EConst(CString(id)), pos: Context.currentPos() }: Expr)
		];
		return { expr: EArrayDecl(elems), pos: Context.currentPos() };
	}

}

/**
 * One generated span-info function descriptor.
 */
typedef SpanInfoFn = {
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
 * Result of span-info lowering: every function to emit plus the root entry.
 */
typedef SpanInfoResult = {
	/** Full grammar root type path. */
	final rootTypePath: String;

	/** Paired root type - the public entry's `root` parameter. */
	final rootCT: ComplexType;

	/** `_spanInfo` function name for the root type, which the public entry delegates to. */
	final rootFnName: String;

	/** One `_spanInfo<T>` per non-Terminal rule. */
	final walks: Array<SpanInfoFn>;

	/** One `_nominalName<T>` per enum rule a `type` / `returnType` field points at. */
	final nominals: Array<SpanInfoFn>;

	/** One `_spanOf<T>` for the same rule set as `nominals`. */
	final spanOfs: Array<SpanInfoFn>;

	/** Element type of an accessor clause's `ids` array, or null when the grammar has no such shape. */
	final accessorIdCT: Null<ComplexType>;
};
#end
