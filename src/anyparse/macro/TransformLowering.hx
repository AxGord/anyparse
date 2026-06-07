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
 * single shallow `map` function — the `haxe.macro.ExprTools.map` analog
 * for the grammar's root AST family.
 *
 * `map(node, f)` rebuilds `node` applying `f` to every IMMEDIATE child
 * that is itself a node of the root family (directly, as an
 * `Array<Family>` element, or as an optional `Null<Family>`). Children
 * that are not family nodes (`Terminal` leaves, references to terminal
 * rules) are copied unchanged. `map` is shallow — it never recurses into
 * a returned family node; deep traversal is composed by the caller
 * calling `map` inside `f`, exactly as with `ExprTools.map`.
 *
 * The family boundary is `shape.root`: a `Ref` whose `base.ref` equals
 * the root type path is where `f` is applied. Non-family container rules
 * that still reach a family node (e.g. a JSON object entry whose `value`
 * is a `JValue`) are rebuilt structurally so the nested family child is
 * still mapped — this keeps `map` "one level of family" while honouring
 * the cross-type nesting the grammar may introduce.
 *
 * Generated code never calls enum constructors directly inside a
 * `macro {}` block (that would trigger macro-time type checking).
 * Constructors are rebuilt via `MacroStringTools.toFieldExpr` +
 * `ECall`, matching how `Lowering` reconstructs AST nodes.
 */
class TransformLowering {

	private final shape:ShapeBuilder.ShapeResult;

	public function new(shape:ShapeBuilder.ShapeResult) {
		this.shape = shape;
	}

	/**
	 * Build the single `map(node, f)` rule for the root family. The root
	 * rule must be an `Alt` (an enum family) — the only shape for which a
	 * meaningful `ExprTools.map` analog exists.
	 */
	public function generate():TransformRule {
		final rootNode:ShapeNode = shape.rules.get(shape.root);
		if (rootNode == null) {
			Context.fatalError('TransformLowering: root rule ${shape.root} not found in shape', Context.currentPos());
			throw 'unreachable';
		}
		if (rootNode.kind != Alt) {
			Context.fatalError('TransformLowering: root ${shape.root} is ${rootNode.kind}, only Alt (enum) families support map', Context.currentPos());
			throw 'unreachable';
		}
		final familyCT:ComplexType = pathToComplexType(shape.root);
		final body:Expr = lowerAlt(rootNode, shape.root);
		return {fnName: 'map', familyCT: familyCT, body: body};
	}

	/**
	 * Lower an `Alt` family node to a `switch node { case Ctor(...): ... }`
	 * that rebuilds each constructor with `f` applied to its family
	 * children. The switch is exhaustive over the enum's constructors, so
	 * no default case is emitted.
	 */
	private function lowerAlt(node:ShapeNode, typePath:String):Expr {
		final cases:Array<Case> = [for (branch in node.children) lowerBranch(branch, typePath)];
		final switchExpr:Expr = {
			expr: ESwitch(macro node, cases, null),
			pos: Context.currentPos(),
		};
		return macro return $switchExpr;
	}

	/**
	 * Lower one enum constructor to a `case Ctor(a0, a1, ...): Ctor(<rebuild a0>, ...)`.
	 * Nullary constructors map to `case Ctor: Ctor`.
	 */
	private function lowerBranch(branch:ShapeNode, typePath:String):Case {
		final ctor:String = branch.annotations.get('base.ctor');
		final ctorPath:String = typePath + '.' + ctor;
		final ctorRef:Expr = MacroStringTools.toFieldExpr(ctorPath.split('.'));

		if (branch.children.length == 0) {
			// Nullary constructor — pattern and rebuild are both the bare ctor.
			return {values: [ctorRef], expr: ctorRef};
		}

		final argNames:Array<String> = [for (i in 0...branch.children.length) '_a$i'];
		final pattern:Expr = {
			expr: ECall(ctorRef, [for (name in argNames) macro $i{name}]),
			pos: Context.currentPos(),
		};
		final rebuiltArgs:Array<Expr> = [
			for (i in 0...branch.children.length)
				rebuildExpr(branch.children[i], macro $i{argNames[i]})
		];
		final rebuilt:Expr = {
			expr: ECall(ctorRef, rebuiltArgs),
			pos: Context.currentPos(),
		};
		return {values: [pattern], expr: rebuilt};
	}

	/**
	 * Produce an expression that rebuilds `node`'s value from `valueExpr`,
	 * applying `f` at every root-family boundary. Optionality is handled
	 * once, at the top, since `base.optional` may sit on any node kind.
	 */
	private function rebuildExpr(node:ShapeNode, valueExpr:Expr):Expr {
		final optional:Bool = node.annotations.get('base.optional') == true;
		if (!optional) return rebuildCore(node, valueExpr);
		// Null<Family> (or Null<container reaching Family>): map only the
		// present value, preserve null. Containers that never reach the
		// family fall through to a plain copy via the containsFamily guard.
		if (!containsFamily(node)) return valueExpr;
		final inner:Expr = rebuildCore(node, valueExpr);
		return macro $valueExpr == null ? null : $inner;
	}

	/**
	 * Non-optional rebuild dispatch. A node that does not transitively
	 * reach the root family is copied unchanged — this both avoids
	 * needless allocation and stops descent at terminals.
	 */
	private function rebuildCore(node:ShapeNode, valueExpr:Expr):Expr {
		if (!containsFamily(node)) return valueExpr;
		return switch node.kind {
			case Ref:
				final ref:String = node.annotations.get('base.ref');
				// The family boundary: apply `f`. Any other Ref reaching the
				// family is a container rule whose shape we descend into.
				if (ref == shape.root) macro f($valueExpr);
				else rebuildRef(ref, valueExpr);
			case Star:
				// Array<X>: map each element through the element rebuild.
				final elem:ShapeNode = node.children[0];
				final perElem:Expr = rebuildExpr(elem, macro _e);
				macro [for (_e in $valueExpr) $perElem];
			case Seq:
				rebuildStruct(node, valueExpr);
			case _:
				// Alt/Opt/Terminal as a direct child reaching the family are
				// not produced by the shape builder for this slice's grammars
				// (the family is always reached via Ref/Star/Seq). Guard so a
				// future grammar surfaces the gap instead of silently copying.
				Context.fatalError('TransformLowering: cannot rebuild ${node.kind} child reaching family', Context.currentPos());
				throw 'unreachable';
		};
	}

	/**
	 * Rebuild a reference to a non-family container rule (e.g. a struct
	 * typedef like `JEntry`). The referenced rule's own shape drives the
	 * reconstruction, so a family child nested one struct level deep is
	 * still mapped.
	 */
	private function rebuildRef(ref:String, valueExpr:Expr):Expr {
		final refNode:ShapeNode = shape.rules.get(ref);
		if (refNode == null) {
			Context.fatalError('TransformLowering: referenced rule $ref not found in shape', Context.currentPos());
			throw 'unreachable';
		}
		return switch refNode.kind {
			case Seq: rebuildStruct(refNode, valueExpr);
			case Star:
				final elem:ShapeNode = refNode.children[0];
				final perElem:Expr = rebuildExpr(elem, macro _e);
				macro [for (_e in $valueExpr) $perElem];
			case _:
				Context.fatalError('TransformLowering: cannot descend into ${refNode.kind} rule $ref', Context.currentPos());
				throw 'unreachable';
		};
	}

	/**
	 * Rebuild an anonymous-struct (`Seq`) value: emit `{field0: <rebuild>,
	 * field1: <copy>, ...}`. Fields that do not reach the family are
	 * copied via plain field access; only family-bearing fields allocate.
	 */
	private function rebuildStruct(node:ShapeNode, valueExpr:Expr):Expr {
		final objFields:Array<ObjectField> = [
			for (child in node.children) {
				final fieldName:String = child.annotations.get('base.fieldName');
				final access:Expr = {
					expr: EField(valueExpr, fieldName),
					pos: Context.currentPos(),
				};
				{field: fieldName, expr: rebuildExpr(child, access)};
			}
		];
		return {
			expr: EObjectDecl(objFields),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Whether `node` transitively reaches the root family — i.e. whether
	 * `f` would ever be applied inside its rebuild. Terminals and
	 * references to terminal-only rules return `false` (copied unchanged);
	 * the family `Ref`, arrays of family, and structs holding a family
	 * field return `true`.
	 *
	 * `seen` guards against cyclic container rules (a rule referencing
	 * itself only through the family is already caught by the family
	 * short-circuit, but mutually recursive containers are guarded here).
	 */
	private function containsFamily(node:ShapeNode, ?seen:Array<String>):Bool {
		final visited:Array<String> = seen ?? [];
		return switch node.kind {
			case Ref:
				final ref:String = node.annotations.get('base.ref');
				if (ref == shape.root) return true;
				if (visited.contains(ref)) return false;
				visited.push(ref);
				final refNode:ShapeNode = shape.rules.get(ref);
				refNode != null && containsFamily(refNode, visited);
			case Star:
				containsFamily(node.children[0], visited);
			case Seq, Alt:
				node.children.exists(c -> containsFamily(c, visited));
			case Terminal, Opt:
				false;
		};
	}

	private static function pathToComplexType(typePath:String):ComplexType {
		final idx:Int = typePath.lastIndexOf('.');
		final pack:Array<String> = idx == -1 ? [] : typePath.substring(0, idx).split('.');
		final name:String = idx == -1 ? typePath : typePath.substring(idx + 1);
		return TPath({pack: pack, name: name, params: []});
	}
}

/**
 * One generated transform function. This slice emits exactly one rule —
 * the family-root `map` — but the struct mirrors `WriterRule` so the
 * codegen split stays parallel and a future cross-family slice can grow
 * the list without reshaping the pipeline.
 */
typedef TransformRule = {
	/** Generated function name (`map`). */
	final fnName:String;

	/** The root family ComplexType — both `node` param and return type. */
	final familyCT:ComplexType;

	/** Body expression (a `return switch ... { ... }`). */
	final body:Expr;
};
#end
