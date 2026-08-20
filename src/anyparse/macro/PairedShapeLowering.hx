package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;

using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Shared base for the lowering passes that walk the SPAN-PAIRED typed AST -
 * `QueryWalkerLowering` (AST to `QueryNode`) and `SpanInfoLowering` (AST to the
 * span-indexed type/accessor maps).
 *
 * Both consume the same `ShapeResult` and both have to answer the same
 * questions about it: what is a rule's paired `*S` type, which of its fields
 * are grammar nodes, what does one of its enum ctors look like as a pattern.
 * Those answers live here so the two passes cannot drift on them; each subclass
 * adds only what it emits.
 *
 * The naming and pairing rules mirror `SpanTypeSynth`, which is what DEFINES
 * the paired types this reads - a change there has to be reflected here.
 */
class PairedShapeLowering {

	/** Field name `SpanTypeSynth` gives the trailing span arg of every paired enum ctor and every `@:spanned` struct. */
	public static inline final SPAN_FIELD: String = '_span';

	/** Suffix `SpanTypeSynth` appends to a paired type's simple name. */
	public static inline final PAIRED_SUFFIX: String = 'S';

	/** Sub-package `SpanTypeSynth` defines the paired module in. */
	public static inline final SYNTH_SUBPACK: String = 'spans';

	/** Module leaf `SpanTypeSynth` defines the paired types in. */
	public static inline final SYNTH_MODULE: String = 'Pairs';

	/** Struct field whose presence makes a `Seq` a transparent envelope - the walk descends it and ignores the rest. */
	public static inline final ENVELOPE_FIELD: String = 'node';

	private final _shape: ShapeBuilder.ShapeResult;

	public function new(shape: ShapeBuilder.ShapeResult) {
		_shape = shape;
	}

	/** A `Seq` field's / `Alt` ctor arg's declared name. */
	private inline function fieldNameOf(child: ShapeNode): String {
		return child.annotations[AnnotationKeys.BASE_FIELD_NAME];
	}

	/** Whether a field node is `Null<...>` and so needs a null guard before descent. */
	private inline function isOptional(child: ShapeNode): Bool {
		return child.annotations[AnnotationKeys.BASE_OPTIONAL] == true;
	}

	/** The rule a field node references, or null when it is not a `Ref` to a named rule. */
	private function refOf(child: ShapeNode): Null<String> {
		return switch child.kind {
			case Ref: child.annotations[AnnotationKeys.BASE_REF];
			case _: null;
		};
	}

	/**
	 * Whether an inline (unnamed) Terminal node's primitive is `Bool` — the mirror of
	 * `isStringShape`, and the one primitive whose VALUE is the entire content of the
	 * node it sits under (`BoolLit(true)` / `BoolLit(false)` share a kind, have no
	 * children, and project no text).
	 */
	private function isBoolShape(node: ShapeNode): Bool {
		if (node.kind != Terminal) return false;
		if (node.annotations['base.underlying'] == 'Bool') return true;
		final tp: Null<String> = node.annotations[AnnotationKeys.BASE_TYPE_PATH];
		return tp != null && simpleName(tp) == 'Bool';
	}

	/** Whether an inline (unnamed) Terminal node's primitive is `String`. */
	private function isStringShape(node: ShapeNode): Bool {
		final under: Null<String> = node.annotations['base.underlying'];
		if (under == 'String') return true;
		final tp: Null<String> = node.annotations[AnnotationKeys.BASE_TYPE_PATH];
		return tp != null && simpleName(tp) == 'String';
	}

	private function ident(name: String): Expr {
		return { expr: EConst(CIdent(name)), pos: Context.currentPos() };
	}

	private function field(target: Expr, name: String): Expr {
		return { expr: EField(target, name), pos: Context.currentPos() };
	}

	private function call(fnName: String, args: Array<Expr>): Expr {
		return { expr: ECall(ident(fnName), args), pos: Context.currentPos() };
	}

	private function block(exprs: Array<Expr>): Expr {
		return { expr: EBlock(exprs), pos: Context.currentPos() };
	}

	/** Rule names in a deterministic order, so generated field order does not follow Map iteration order. */
	private function sortedRuleNames(): Array<String> {
		final names: Array<String> = [for (name in _shape.rules.keys()) name];
		names.sort((a: String, b: String) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		return names;
	}

	/** The paired `*S` type of a rule, or its raw type when the rule is a Terminal (Terminals are not paired). */
	private function pairedComplexType(rule: String): ComplexType {
		return !isTerminalRule(rule)
			? TPath({
				pack: packOf(_shape.root).concat([SYNTH_SUBPACK]),
				name: SYNTH_MODULE,
				sub: simpleName(rule) + PAIRED_SUFFIX,
				params: []
			})
			: TPath({ pack: packOf(rule), name: simpleName(rule), params: [] });
	}

	/** Whether a rule name resolves to a Terminal - a primitive leaf with no paired type and no generated functions. */
	private function isTerminalRule(rule: String): Bool {
		final node: Null<ShapeNode> = _shape.rules[rule];
		return node == null || node.kind == Terminal;
	}

	/** Whether a Terminal RULE's underlying primitive is `String` - the only shape a name can be read from directly. */
	private function isStringTerminal(rule: String): Bool {
		final node: Null<ShapeNode> = _shape.rules[rule];
		return node != null && node.kind == Terminal && isStringShape(node);
	}

	/** Whether an `Alt` rule declares a ctor of this name. */
	private function altHasCtor(rule: String, ctor: String): Bool {
		final node: Null<ShapeNode> = _shape.rules[rule];
		if (node == null || node.kind != Alt) return false;
		return node.children.exists(b -> (b.annotations.get(AnnotationKeys.BASE_CTOR): String) == ctor);
	}

	/** Declared arg count of an `Alt` ctor, excluding the synthesised trailing `_span`. */
	private function ctorArity(rule: String, ctor: String): Int {
		final node: Null<ShapeNode> = _shape.rules[rule];
		if (node == null || node.kind != Alt) return 0;
		final branch: Null<ShapeNode> = node.children.find(b -> (b.annotations.get(AnnotationKeys.BASE_CTOR): String) == ctor);
		return branch == null ? 0 : branch.children.length;
	}

	/** The declared field of a `Seq` rule with this name, or null. */
	private function seqField(node: ShapeNode, name: String): Null<ShapeNode> {
		return node.kind != Seq ? null : node.children.find(c -> fieldNameOf(c) == name);
	}

	/** Whether a `Seq` rule opted out of transparency with `@:spanned('<Kind>')`, gaining `_kind` + `_span`. */
	private function isSpanned(node: ShapeNode): Bool {
		return node.kind == Seq && node.readMetaString(':spanned') != null;
	}

	/**
	 * `Ctor(<argNames...>, _span)` as an expression over the PAIRED enum, usable
	 * as a switch pattern. The ctor is addressed through its fully qualified
	 * paired path so the pattern never depends on what the generated module
	 * happens to have imported.
	 */
	private function ctorPattern(rule: String, ctor: String, argNames: Array<String>): Expr {
		final path: Array<String> = packOf(_shape.root).concat([
			SYNTH_SUBPACK,
			SYNTH_MODULE,
			simpleName(rule) + PAIRED_SUFFIX,
			ctor
		]);
		final args: Array<Expr> = [for (n in argNames) ident(n)];
		args.push(ident(SPAN_FIELD));
		return { expr: ECall(haxe.macro.MacroStringTools.toFieldExpr(path), args), pos: Context.currentPos() };
	}

	/** Simple (unqualified) name of a type path. */
	public static function simpleName(typePath: String): String {
		final idx: Int = typePath.lastIndexOf('.');
		return idx == -1 ? typePath : typePath.substring(idx + 1);
	}

	/** Package parts of a type path, empty for a root-package type. */
	public static function packOf(typePath: String): Array<String> {
		final idx: Int = typePath.lastIndexOf('.');
		return idx == -1 ? [] : typePath.substring(0, idx).split('.');
	}

}
#end
