package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;
import anyparse.core.ShapeTree;

using Lambda;

/**
 * Pass 3T of the macro pipeline — transform lowering.
 *
 * Walks the same `ShapeTree` as `Lowering`/`WriterLowering` but emits a
 * DEEP whole-tree transform with per-node-type rewrite hooks — the
 * multi-type generalization of `haxe.macro.ExprTools.map`.
 *
 * For every grammar type `T` reachable from the root, one
 * `_transformT(node:T, visit):T` function is generated. It performs a
 * bottom-up walk: each child that is itself a grammar type is recursed
 * first (by calling that child type's own `_transform`), the node is
 * rebuilt around the transformed children, then the per-type hook
 * `visit.<tCamel>(rebuilt)` is applied when non-null (otherwise the
 * rebuilt node is returned verbatim). The public `transform` entry
 * calls the root type's `_transform`.
 *
 * `visit` is an `HxTransform`-style anonymous struct with one optional
 * hook per grammar type. An empty `{}` is a structural identity. Setting
 * a single hook (e.g. `visit.hxIdentLit = renameFn`) rewrites every node
 * of that type across the whole tree — the rename primitive.
 *
 * Family boundaries are no longer special: in the JValue slice a single
 * root family `Ref` was where `f` applied. Here EVERY `Ref` to a named
 * rule dispatches into that rule's `_transform`, so cross-type nesting
 * (`HxModule` to `HxTopLevelDecl` to `HxDecl` to `HxClassDecl`, the
 * recursive Pratt `HxExpr`/`HxStatement`/`HxType` cycle, ...) is walked
 * end-to-end. Only INLINE primitive terminals (a bare `Bool`/`Int`/...
 * field with no named grammar type) are copied unchanged — every named
 * Terminal rule (`HxIdentLit`, `HxFloatLit`, ...) gets its own
 * `_transform` so a hook on it is a valid rewrite site.
 *
 * Generated code never calls enum constructors directly inside a
 * `macro {}` block (that would trigger macro-time type checking).
 * Constructors are rebuilt via `MacroStringTools.toFieldExpr` +
 * `ECall`, matching how `Lowering` reconstructs AST nodes.
 */
class TransformLowering {

	private final _shape: ShapeBuilder.ShapeResult;

	public function new(shape: ShapeBuilder.ShapeResult) {
		_shape = shape;
	}

	/**
	 * Build the deep multi-type transform: one `_transform<T>` per
	 * reachable rule, the per-type hook descriptors for the `visit`
	 * typedef, and the public `transform` entry rooted on `shape.root`.
	 */
	public function generate(): TransformResult {
		final ruleNames: Array<String> = [for (name in _shape.rules.keys()) name];
		// Deterministic order — keep generated field order stable across
		// compiles regardless of Map iteration order.
		ruleNames.sort((a: String, b: String) -> a < b ? -1 : (a > b ? 1 : 0));

		final fns: Array<TransformFn> = [];
		final hooks: Array<TransformHook> = [];
		for (name in ruleNames) {
			final node: ShapeNode = _shape.rules.get(name);
			if (node == null) continue;
			final ct: ComplexType = pathToComplexType(name);
			final hookName: String = hookFieldName(name);
			hooks.push({ name: hookName, ct: ct });
			fns.push({
				typePath: name,
				fnName: transformFnName(name),
				paramCT: ct,
				body: lowerRule(name, node, hookName),
			});
		}

		return {
			rootTypePath: _shape.root,
			rootCT: pathToComplexType(_shape.root),
			rootFnName: transformFnName(_shape.root),
			fns: fns,
			hooks: hooks,
		};
	}

	/**
	 * Lower one rule type to the body of its `_transform<T>` function.
	 * Dispatches on the rule kind, then applies the rule's own hook to
	 * the rebuilt value as the final step (bottom-up: children first,
	 * self last).
	 */
	private function lowerRule(typePath: String, node: ShapeNode, hookName: String): Expr {
		final rebuilt: Expr = switch node.kind {
			case Alt: lowerAlt(node, typePath);
			case Seq: rebuildStruct(node, macro node);
			case Star:
				// A top-level `Array<X>` rule (rare, but the shape model
				// allows it) — map each element through its rebuild.
				final perElem: Expr = rebuildExpr(node.children[0], macro _e);
				macro [for (_e in node) $perElem];
			case Ref:
				// A typedef that is a bare alias to another rule.
				rebuildCore(node, macro node);
			case Terminal:
				// Leaf rule — nothing to recurse into; the hook (applied
				// below) is the only possible rewrite.
				macro node;
			case Opt:
				// `Opt` never appears as a top-level rule (optionality is
				// an annotation on a field node, not a standalone kind).
				Context.fatalError('TransformLowering: rule $typePath has unexpected Opt kind', Context.currentPos());
				throw 'unreachable';
		};
		return applyHook(hookName, rebuilt);
	}

	/**
	 * Wrap a rebuilt value in the per-type hook application:
	 * `{ final _r = <rebuilt>; final _h = visit.<hook>; return _h != null ? _h(_r) : _r; }`.
	 * The intermediate `_r` keeps the rebuild from being evaluated twice;
	 * the local `_h` captures the optional hook so strict null-safety
	 * narrows it (a field access on `visit` would not narrow).
	 */
	private function applyHook(hookName: String, rebuilt: Expr): Expr {
		final hookAccess: Expr = { expr: EField(macro visit, hookName), pos: Context.currentPos() };
		return macro {
			final _r = $rebuilt;
			final _h = $hookAccess;
			return _h != null ? _h(_r) : _r;
		};
	}

	/**
	 * Lower an `Alt` family node to a `switch node { case Ctor(...): ... }`
	 * that recurses into each constructor's children and rebuilds it. The
	 * switch is exhaustive over the enum's constructors, so no default
	 * case is emitted.
	 */
	private function lowerAlt(node: ShapeNode, typePath: String): Expr {
		final cases: Array<Case> = [for (branch in node.children) lowerBranch(branch, typePath)];
		return { expr: ESwitch(macro node, cases, null), pos: Context.currentPos() };
	}

	/**
	 * Lower one enum constructor to `case Ctor(a0, a1, ...): Ctor(<rebuild a0>, ...)`.
	 * Nullary constructors map to `case Ctor: Ctor`.
	 */
	private function lowerBranch(branch: ShapeNode, typePath: String): Case {
		final ctor: String = branch.annotations.get('base.ctor');
		final ctorPath: String = typePath + '.' + ctor;
		final ctorRef: Expr = MacroStringTools.toFieldExpr(ctorPath.split('.'));

		if (branch.children.length == 0) {
			// Nullary constructor — pattern and rebuild are both the bare ctor.
			return { values: [ctorRef], expr: ctorRef };
		}

		final argNames: Array<String> = [for (i in 0...branch.children.length) '_a$i'];
		final pattern: Expr = {
			expr: ECall(ctorRef, [for (name in argNames) macro $i{name}]),
			pos: Context.currentPos(),
		};
		final rebuiltArgs: Array<Expr> = [
			for (i in 0...branch.children.length)
				rebuildExpr(branch.children[i], macro $i{argNames[i]})
		];
		final rebuilt: Expr = { expr: ECall(ctorRef, rebuiltArgs), pos: Context.currentPos() };
		return { values: [pattern], expr: rebuilt };
	}

	/**
	 * Produce an expression that rebuilds `node`'s value from `valueExpr`,
	 * recursing into every grammar-typed child. Optionality is handled
	 * once at the top, since `base.optional` may sit on any node kind.
	 */
	private function rebuildExpr(node: ShapeNode, valueExpr: Expr): Expr {
		final optional: Bool = node.annotations.get('base.optional') == true;
		if (!optional) return rebuildCore(node, valueExpr);
		// `Null<...>`: recurse only the present value, preserve null. Nodes
		// that never reach a transformable child fall through to a plain
		// copy via the transformable guard.
		if (!isTransformable(node)) return valueExpr;
		// Bind the nullable value to a local so strict null-safety narrows
		// it in the non-null branch (a field access on `node` would not
		// narrow). The inner rebuild is built against that local. Optional
		// wrappers never nest in the grammar (a field is `Null<T>`, never
		// `Null<Null<T>>`), so a fixed local name is collision-free.
		final inner: Expr = rebuildCore(node, macro _o);
		return macro {
			final _o = $valueExpr;
			_o == null ? null : $inner;
		};
	}

	/**
	 * Non-optional rebuild dispatch. A node that does not transitively
	 * reach any grammar type is copied unchanged — this both avoids
	 * needless allocation and stops descent at inline primitive leaves.
	 */
	private function rebuildCore(node: ShapeNode, valueExpr: Expr): Expr {
		return !isTransformable(node)
			? valueExpr
			: switch node.kind {
				case Ref:
					// Dispatch into the referenced rule's own `_transform`,
					// threading `visit` so its hooks fire deeper in the tree.
					final ref: String = node.annotations.get('base.ref');
					callTransform(ref, valueExpr);
				case Star:
					// Array<X>: map each element through the element rebuild.
					final perElem: Expr = rebuildExpr(node.children[0], macro _e);
					macro [for (_e in $valueExpr) $perElem];
				case Seq:
					rebuildStruct(node, valueExpr);
				case Alt, Opt, Terminal:
					// A direct anonymous Alt/Opt/Terminal child reaching a
					// grammar type is never produced by the shape builder —
					// named types always arrive as `Ref`. Guard so a future
					// grammar surfaces the gap instead of silently copying.
					Context.fatalError('TransformLowering: cannot rebuild ${node.kind} child reaching a grammar type', Context.currentPos());
					throw 'unreachable';
			};
	}

	/**
	 * Emit a call to the referenced rule's `_transform`. The callee is an
	 * unresolved identifier (`_transform<Ref>(value, visit)`) — the
	 * generated functions live on the same marker class, so a bare
	 * identifier call resolves at typing time without macro-time checks.
	 */
	private function callTransform(ref: String, valueExpr: Expr): Expr {
		final fn: String = transformFnName(ref);
		final callee: Expr = { expr: EConst(CIdent(fn)), pos: Context.currentPos() };
		return { expr: ECall(callee, [valueExpr, macro visit]), pos: Context.currentPos() };
	}

	/**
	 * Rebuild an anonymous-struct (`Seq`) value: emit `{field0: <rebuild>,
	 * field1: <copy>, ...}`. Fields that do not reach a grammar type are
	 * copied via plain field access; only transformable fields recurse.
	 */
	private function rebuildStruct(node: ShapeNode, valueExpr: Expr): Expr {
		final objFields: Array<ObjectField> = [
			for (child in node.children) {
				final fieldName: String = child.annotations.get('base.fieldName');
				final access: Expr = { expr: EField(valueExpr, fieldName), pos: Context.currentPos() };
				{ field: fieldName, expr: rebuildExpr(child, access) };
			}
		];
		return { expr: EObjectDecl(objFields), pos: Context.currentPos() };
	}

	/**
	 * Whether `node` transitively reaches a grammar type — i.e. whether
	 * any `_transform` call would be emitted inside its rebuild. Inline
	 * primitive terminals (a bare `Bool`/`Int`/... field with no `base.ref`)
	 * return `false` (copied unchanged); a `Ref` to any named rule, arrays
	 * of such, and structs holding such a field return `true`.
	 *
	 * No cycle guard is needed: a `Ref` short-circuits to a name-existence
	 * check (named rules are never inlined, they resolve to their own
	 * `_transform`), so descent only ever covers one node's own child
	 * field list (`Star` element / `Seq`/`Alt` field nodes), which is
	 * finite and acyclic.
	 */
	private function isTransformable(node: ShapeNode): Bool {
		return switch node.kind {
			case Ref:
				// Every named rule has a `_transform`, so any Ref to a rule
				// in the shape is a valid recursion target — including
				// Terminal rules, whose hook is the rename primitive.
				final ref: String = node.annotations.get('base.ref');
				_shape.rules.exists(ref);
			case Star:
				isTransformable(node.children[0]);
			case Seq, Alt:
				node.children.exists(c -> isTransformable(c));
			case Terminal, Opt:
				false;
		};
	}

	// ---------------- name helpers ----------------

	/**
	 * Generated `_transform` function name for a rule type path — the
	 * simple type name prefixed with `_transform` (e.g.
	 * `anyparse.grammar.haxe.HxExpr` to `_transformHxExpr`).
	 */
	public static function transformFnName(typePath: String): String {
		return '_transform' + simpleName(typePath);
	}

	/**
	 * Per-type hook field name on the `visit` struct — the simple type
	 * name lower-camelCased (e.g. `HxExpr` to `hxExpr`, `HxModule` to
	 * `hxModule`).
	 */
	public static function hookFieldName(typePath: String): String {
		final simple: String = simpleName(typePath);
		return simple.length == 0 ? simple : simple.charAt(0).toLowerCase() + simple.substring(1);
	}

	private static function simpleName(typePath: String): String {
		final idx: Int = typePath.lastIndexOf('.');
		return idx == -1 ? typePath : typePath.substring(idx + 1);
	}

	private static function pathToComplexType(typePath: String): ComplexType {
		final idx: Int = typePath.lastIndexOf('.');
		final pack: Array<String> = idx == -1 ? [] : typePath.substring(0, idx).split('.');
		final name: String = idx == -1 ? typePath : typePath.substring(idx + 1);
		return TPath({ pack: pack, name: name, params: [] });
	}

}

/**
 * One generated `_transform<T>` function descriptor.
 */
typedef TransformFn = {
	/** Full grammar type path this function transforms. */
	final typePath: String;

	/** Generated function name (`_transform<SimpleName>`). */
	final fnName: String;

	/** The transformed type's ComplexType — both `node` param and return type. */
	final paramCT: ComplexType;

	/** Body expression (the deep-rebuild + hook application). */
	final body: Expr;
};

/**
 * One per-type hook descriptor for the generated `visit` typedef.
 */
typedef TransformHook = {
	/** Hook field name on the `visit` struct (`hx<SimpleName>`). */
	final name: String;

	/** The transformed type's ComplexType — the hook is `T -> T`. */
	final ct: ComplexType;
};

/**
 * Result of transform lowering: every `_transform<T>` to emit, the
 * per-type hook list for the `visit` typedef, and the root entry info.
 */
typedef TransformResult = {
	/** Full grammar root type path (e.g. `anyparse.grammar.haxe.HxModule`). */
	final rootTypePath: String;

	/** Root grammar type ComplexType — `transform`'s `root` param + return. */
	final rootCT: ComplexType;

	/** `_transform` function name for the root type — `transform` delegates to it. */
	final rootFnName: String;

	/** All generated `_transform<T>` functions, one per reachable rule. */
	final fns: Array<TransformFn>;

	/** Per-type hooks for the generated `visit` typedef. */
	final hooks: Array<TransformHook>;
};
#end
