package anyparse.core;

#if macro
import haxe.macro.Type;

/**
 * Structural kind of a `ShapeNode`, assigned by the `BaseShape` pass
 * from the user's grammar declaration. Each kind corresponds to a
 * shape of `haxe.macro.Type`:
 *
 * - `Seq`      — `class` or `typedef` with fields.
 * - `Alt`      — `enum` with constructors.
 * - `Star`     — `Array<T>`.
 * - `Opt`      — `Null<T>`.
 * - `Ref`      — reference to another `@:peg`-annotated type.
 * - `Terminal` — `abstract` over a primitive, awaiting strategy
 *                annotation (e.g. `@:re` or `@:lit`).
 */
enum ShapeKind {
	Seq;
	Alt;
	Star;
	Opt;
	Ref;
	Terminal;
}

/**
 * Neutral intermediate representation between `haxe.macro.Type` analysis
 * and `CoreIR` lowering. Strategies walk the tree and write to their
 * own namespaced slots in `annotations` before the lowering pass turns
 * the tree into `CoreIR`.
 *
 * `annotations` is `Map<String, Dynamic>` on purpose: each strategy
 * owns a namespace (e.g. `lit.leadText`, `indent.mode`) and stores
 * whatever shape it needs under keys prefixed by its name. Strategies
 * must never read another strategy's slots directly — that would
 * silently couple them.
 */
class ShapeNode {

	public final kind:ShapeKind;
	public final type:Null<Type>;
	public final children:Array<ShapeNode> = [];
	public final annotations:Map<String, Dynamic> = [];

	public function new(kind:ShapeKind, ?type:Type) {
		this.kind = kind;
		this.type = type;
	}
}
#end
