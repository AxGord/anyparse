package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.core.ShapeTree;

using Lambda;
using anyparse.macro.MetaInspect;

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

	/** The `HxType` ctor whose body is a decl host - the one `type` field value the walk descends instead of skipping. */
	private static inline final ANON_CTOR: String = 'Anon';

	/**
	 * Grammar opt-in on a `type` field: project it in the DEFAULT walk too, not
	 * only under `withTypeRefs`.
	 *
	 * A `type` slot is normally a name-slot leaf the default projection drops,
	 * which keeps `ast` / `search` / `refs` / `meta` lean. That is the right
	 * default for an annotation whose owner already names itself (a var, a
	 * member, a parameter): the type is looked up through `uses` / `blast`,
	 * which read `parseFileTypeRefs`.
	 *
	 * It is the WRONG default where the type is the only thing distinguishing
	 * two otherwise identical nodes. An anonymous structure has no name of its
	 * own — its identity IS its field names and their types — so dropping the
	 * types made `{ xml:Xml, text:String }` and `{ xml:Int, text:Int }` render
	 * the byte-identical `(Anon (Required xml) (Required text))`, and any rule
	 * or rewrite keyed on that tree would have merged two different types.
	 *
	 * The tag routes the slot through the SAME `_typeRefs` function
	 * `parseFileTypeRefs` uses, so the two projections agree on the shape by
	 * construction rather than by a second, parallel emit.
	 */
	private static inline final QUERY_TYPE_REF_META: String = ':queryTypeRef';

	/**
	 * Grammar opt-in on a `type` field: WALK it in the default tree, exactly as
	 * an ordinary field is walked.
	 *
	 * The sibling of `QUERY_TYPE_REF_META`, and the other answer to the same
	 * question. `@:queryTypeRef` routes the slot through `_typeRefs`, which
	 * FLATTENS a type into one `TypeRef` node per nominal name; that is right for
	 * an anon field, whose identity is its field names and their types and whose
	 * consumers only ever ask "which names appear". `@:queryType` keeps the
	 * type's own shape: one node whose kind is the `HxType` ctor (`Named`,
	 * `Anon`, `Arrow`, `ArrowFn`, …), the projection a function's return type and
	 * an `extends` clause already carry.
	 *
	 * Two properties are load-bearing where a DECLARATION hosts the slot. The
	 * node count is FIXED at one, so every consumer indexing a declaration's
	 * children moves by a constant rather than by an amount that depends on how
	 * many nominals the annotation happens to mention. And nesting survives:
	 * `Map<String, Array<Int>>` is `(Named Map (Named String) (Named Array (Named
	 * Int)))`, where the flat form cannot tell a second argument from the second
	 * argument's own argument.
	 *
	 * The tag moves the DEFAULT tree only — `parseFileTypeRefs` keeps its flat
	 * `TypeRef` projection, so the two trees stay the two answers they are.
	 */
	private static inline final QUERY_TYPE_META: String = ':queryType';

	/**
	 * Grammar opt-in on a `type` field: project it into the ENCLOSING addressable
	 * node's `QueryNode.type` SLOT, leaving that node's children exactly as they were.
	 *
	 * The third answer to the `type`-slot question, and the only one a DECLARATION can
	 * take. `@:queryType` makes the annotation a child, which is right where the host
	 * has no other children to displace (a type argument, an `extends` clause) and wrong
	 * on a `var` / `final`: a declaration's children are its initializer and its
	 * comma-continuations, and the checks read them positionally — `decl.children[0]` IS
	 * the initializer in some forty rules. Measured on this tree: tagging
	 * `HxVarDecl.type` `@:queryType` turned 25611 assertions into 369 failures and 64
	 * errors across ~50 test classes, every one of them an index that moved.
	 *
	 * A dedicated child KIND would not have rescued it either. `declTypeChildKinds`
	 * already exists for exactly this filtering, and it cannot express the Haxe answer:
	 * `Arrow` is both `HxType.Arrow` (`Int->Void`, an annotation) and `HxExpr.Arrow`
	 * (`k => v`, an initializer), so "which child is the type" has no kind-level answer.
	 * A slot has no such ambiguity, which is the same reason `name` is a slot.
	 *
	 * The tagged field is walked into a private accumulator and the FIRST node lands in
	 * the slot; whatever the pre-existing arm contributed to `into` is untouched, so the
	 * `Anon` decl-host descent (`var x:{a:Int}` publishes its fields as declarations)
	 * keeps working and every children-walking consumer sees a byte-identical tree.
	 */
	private static inline final QUERY_TYPE_SLOT_META: String = ':queryTypeSlot';

	/** Name of the `_walk` parameter carrying the enclosing node's type slot, and of the local a node-forming rule allocates for its own. */
	private static inline final TYPE_OUT_PARAM: String = 'typeOut';

	private static inline final TYPE_SLOT_LOCAL: String = '_typeSlot';

	/** Name of the local a `@:queryTypeSlot` field walks into before its first node becomes the slot. */
	private static inline final TYPE_SLOT_OWN_LOCAL: String = '_typeSlotOwn';

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

	/**
	 * Ctors whose first operand names a nominal type - the `TypeRef` emit sites.
	 *
	 * Matched by ctor NAME, so the match is qualified by `_typeRefSeeds`: a rule
	 * that only sits INSIDE a type expression may carry a same-named ctor that
	 * means something else (`HxArrowParam.Named(body)` is a NAMED PARAMETER of a
	 * new-form arrow type, whose head operand resolves to the parameter's name).
	 * Without the qualifier that name is emitted as a type reference, and every
	 * consumer that rewrites what the projection reports - `CrossRename` above all
	 * - would rename a parameter as if it were a type.
	 */
	private static final TYPE_REF_NAME_CTORS: Array<String> = ['Named', 'DollarType'];

	/** Rule names reachable from a `type` field - the rules that need a `_typeRefs` function. */
	private final _typeRefRules: Array<String> = [];

	/**
	 * Rules that DIRECTLY front a `type` field - the seeds of `_typeRefRules`,
	 * and the only rules whose `TYPE_REF_NAME_CTORS` ctor names a type.
	 */
	private final _typeRefSeeds: Array<String> = [];

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

	private inline function descendCore(child: ShapeNode, access: Expr, intoName: String, typeOutName: String, depth: Int): Array<Expr> {
		return switch child.kind {
			case Ref:
				final ref: String = child.annotations[AnnotationKeys.BASE_REF];
				isTerminalRule(ref) ? [] : [
					call(walkFnName(ref), [access, ident(intoName), ident(typeOutName), ident('withTypeRefs')])
				];
			case Star:
				final loopVar: String = '_e$depth';
				final body: Array<Expr> = descend(child.children[0], ident(loopVar), intoName, typeOutName, depth + 1);
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

	// ---------------- paired-type resolution (mirrors SpanTypeSynth) ----------------
	/** Whether a Terminal rule's underlying primitive is `String` - the only shape the name resolution can read directly. */
	// ---------------- shape helpers ----------------

	/**
	 * Seed `_typeRefRules` from every `type` field in the grammar and close over
	 * what those rules reach, so a `_typeRefs` function exists exactly where the
	 * `parseFileTypeRefs` projection can reach and nowhere else.
	 */
	private function collectTypeRefRules(): Void {
		for (node in _shape.rules) for (child in node.children) {
			// An Alt's children are ctors, whose own children are the args.
			final args: Array<ShapeNode> = node.kind == Alt ? child.children : [child];
			for (arg in args) if (fieldNameOf(arg) == 'type') {
				final ref: Null<String> = refOf(arg);
				if (ref != null && !isTerminalRule(ref) && !_typeRefSeeds.contains(ref)) _typeRefSeeds.push(ref);
			}
		}
		final pending: Array<String> = _typeRefSeeds.copy();
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
				block(descend(node.children[0], ident('_e0'), 'into', TYPE_OUT_PARAM, 0).length == 0 ? [] : [
					macro for (_e0 in v) $e{block(descend(node.children[0], ident('_e0'), 'into', TYPE_OUT_PARAM, 0))}
				]);
			case Ref: block(descend(node, ident('v'), 'into', TYPE_OUT_PARAM, 0));
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

		final body: Array<Expr> = [
			(macro final _children: Array<anyparse.query.QueryNode> = []),
			(macro final _typeSlot: Array<anyparse.query.QueryNode> = [])
		];
		for (i in 0...branch.children.length) for (e in descend(branch.children[i], ident(argNames[i]), '_children', TYPE_SLOT_LOCAL, 0))
			body.push(e);
		final nameExpr: Expr = firstNonNullName([
			for (i in 0...branch.children.length) nameOfValue(branch.children[i], ident(argNames[i]))
		]);
		body.push(macro into.push(new anyparse.query.QueryNode(
			$v{ctor}, $nameExpr, anyparse.query.QueryWalkSupport.orderBySpan(_children), _span,
			anyparse.query.QueryWalkSupport.first(_typeSlot)
		)));
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
		if (envelope != null)
			return block(descend(envelope, field(ident('v'), PairedShapeLowering.ENVELOPE_FIELD), 'into', TYPE_OUT_PARAM, 0));

		// A transparent Seq forwards the CALLER's slot: `HxVarDecl` materialises no node
		// of its own, so its `type` field belongs to the `VarStmt` / `VarMember` / … ctor
		// node that hosts it.
		if (!isSpanned(node)) {
			final out: Array<Expr> = [
				for (child in node.children) for (e in seqFieldDescent(child, 'into', TYPE_OUT_PARAM, null)) e
			];
			return block(out);
		}

		final body: Array<Expr> = [
			(macro final _children: Array<anyparse.query.QueryNode> = []),
			(macro final _typeSlot: Array<anyparse.query.QueryNode> = [])
		];
		for (child in node.children)
			for (e in seqFieldDescent(child, '_children', TYPE_SLOT_LOCAL, field(ident('v'), PairedShapeLowering.SPAN_FIELD))) body.push(e);
		final nameExpr: Expr = call(nameFnName(rule), [ident('v')]);
		body.push(macro into.push(new anyparse.query.QueryNode(
			v._kind, $nameExpr, anyparse.query.QueryWalkSupport.orderBySpan(_children), v._span,
			anyparse.query.QueryWalkSupport.first(_typeSlot)
		)));
		return block(body);
	}

	/**
	 * Descend one `Seq` FIELD. The `name` slot is the node's display name, never
	 * a child. A `type` slot is a name-slot leaf and is skipped - except an
	 * `HxType.Anon`, whose body hosts declarations, except under
	 * `withTypeRefs`, where the skipped type is surfaced as `TypeRef` nodes,
	 * except a slot the grammar tagged `@:queryTypeRef`, which surfaces
	 * those same `TypeRef` nodes unconditionally (see `QUERY_TYPE_REF_META`),
	 * and except a slot tagged `@:queryType`, which is WALKED like any ordinary
	 * field in the default tree (see `QUERY_TYPE_META`).
	 */
	private function seqFieldDescent(child: ShapeNode, intoName: String, typeOutName: String, fallbackSpan: Null<Expr>): Array<Expr> {
		final name: String = fieldNameOf(child);
		if (name == 'name') return [];
		final access: Expr = field(ident('v'), name);
		if (name != 'type') return descend(child, access, intoName, typeOutName, 0);

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
		final walkArm: Expr = block(descendCore(child, value, intoName, typeOutName, 0));
		final skipArm: Expr = child.hasMeta(QUERY_TYPE_REF_META) ? refsCall : macro if (withTypeRefs) $refsCall;
		final refsAware: Expr = if (ref == null || !altHasCtor(ref, ANON_CTOR))
			skipArm;
		else {
			final anonPattern: Expr = ctorPattern(ref, ANON_CTOR, [for (_ in 0...ctorArity(ref, ANON_CTOR)) '_']);
			{
				expr: ESwitch(value, [
					{ values: [anonPattern], expr: walkArm },
					{ values: [macro _], expr: skipArm }
				], null),
				pos: Context.currentPos()
			};
		}

		// `@:queryType` moves the DEFAULT tree only. Under `withTypeRefs` the arm
		// is the unchanged one, so `parseFileTypeRefs` - and every consumer keyed
		// on its flat `TypeRef` kind: `uses`, `blast`, `mentions`, `CrossRename`,
		// `MoveSymbol`, `Naming`, `UnusedImport` - sees a byte-identical tree.
		final core: Expr = if (child.hasMeta(QUERY_TYPE_META))
			macro if (withTypeRefs)
				$refsAware
			else
				$walkArm;
		else if (child.hasMeta(QUERY_TYPE_SLOT_META)) {
			// The slot is filled from a walk of its own, so the pre-existing arm's
			// contribution to `into` stays exactly what it was.
			final slotWalk: Expr = block(descendCore(child, value, TYPE_SLOT_OWN_LOCAL, TYPE_SLOT_OWN_LOCAL, 0));
			macro {
				$refsAware;
				// The slot is a DEFAULT-tree projection: `parseFileTypeRefs` answers with its
				// flat `TypeRef` run and its consumers never read the slot, so filling it
				// there would only cost a second walk of every annotation and print twice.
				if (!withTypeRefs) {
					final _typeSlotOwn: Array<anyparse.query.QueryNode> = [];
					final withTypeRefs: Bool = false;
					$slotWalk;
					if (_typeSlotOwn.length > 0) $i{typeOutName}.push(_typeSlotOwn[0]);
				}
			};
		} else
			refsAware;

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
	private function descend(child: ShapeNode, access: Expr, intoName: String, typeOutName: String, depth: Int): Array<Expr> {
		final inner: Array<Expr> = descendCore(child, access, intoName, typeOutName, depth);
		if (inner.length == 0 || !isOptional(child)) return inner;
		final local: String = '_o$depth';
		final guarded: Array<Expr> = descendCore(child, ident(local), intoName, typeOutName, depth);
		return [
			block([
				{ expr: EVars([{ name: local, type: null, expr: access }]), pos: Context.currentPos() },
				macro if ($i{local} != null) $e{block(guarded)}
			])
		];
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
	 * `apq uses` can see it. `Anon` recurses here like any other ctor: the
	 * decl-host descent in `_walk` reaches an anon only when the anon IS the
	 * value of a `type` slot, so one nested inside a type expression
	 * (`Array<{ f: T }>`, `{ f: T } -> Void`, `?{ f: T }`) arrives here — and
	 * skipping it dropped the whole struct, with every nominal name in it.
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
	 * One ctor arm of `_typeRefs`. On a rule that fronts a `type` slot,
	 * `Named` / `DollarType` emit the `TypeRef` for their head operand and
	 * then recurse it for nested type parameters; on any deeper rule those
	 * ctor names mean something else and recurse like any other operand.
	 * every other ctor, `Anon` included, just recurses its operands.
	 * The ctor's own `_span` is the node position, replacing the
	 * caller's `fallbackSpan`.
	 */
	private function typeRefsCase(rule: String, branch: ShapeNode): Case {
		final ctor: String = branch.annotations[AnnotationKeys.BASE_CTOR];
		final argNames: Array<String> = [for (i in 0...branch.children.length) '_a$i'];

		final pattern: Expr = ctorPattern(rule, ctor, argNames);
		final body: Array<Expr> = [];
		if (TYPE_REF_NAME_CTORS.contains(ctor) && _typeRefSeeds.contains(rule)) {
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
