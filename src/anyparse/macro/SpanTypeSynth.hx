package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;

using anyparse.macro.MetaInspect;

/**
 * Atomic synthesis of paired `*S` typedefs / enums for every grammar
 * rule when `ctx.spans=true`.
 *
 * Sister to `TriviaTypeSynth` — same atomic `Context.defineModule`
 * pattern (needed because the rule graph is cyclic), same paired-type
 * naming scheme (`<Leaf>S` instead of `<Leaf>T`), placed in a sibling
 * subpackage at `<rootPack>.spans.Pairs`.
 *
 * Key differences from `TriviaTypeSynth`:
 *
 *  - **Every Alt and Seq rule is paired.** Trivia bearing cascades from
 *    `@:trivia` Star presence; spans bearing is universal — the whole
 *    typed AST needs spans so the apq query plugin can attach a span to
 *    every enum-shaped QueryNode regardless of how deeply nested it is.
 *    Terminals (rules whose body is a single regex producing a primitive
 *    String/Int/Float/Bool) are skipped — primitives cannot carry an
 *    extra field.
 *
 *  - **Spans live on enum ctors only, except `@:spanned` Seqs.** Each
 *    Alt ctor gains a trailing positional arg `_span:Span`. Seq paired
 *    types are structurally identical to the raw form (their Ref fields
 *    swap to `*S` variants to keep the reference graph sound) and
 *    normally carry no span field — a Seq's parent enum value's span
 *    covers it (Seqs are transparent in the QueryNode consumer at
 *    `HaxeQueryPlugin.appendNodes`). A Seq typedef annotated
 *    `@:spanned('<Kind>')` opts out of transparency: its paired struct
 *    gains `_span:Span` + `_kind:String` fields so the consumer can
 *    surface it as an addressable `QueryNode` of the named kind. Used
 *    for decl-bearing transparent structs (catch clause, lambda param)
 *    whose name must resolve in `apq refs`.
 *
 *  - **No trivia wrapping.** Star element types pass through unmodified
 *    (no `Trivial<T>` envelope) — span synthesis does not need per-
 *    element source-shape capture.
 *
 *  - **No `Converters` class.** Span synth has no `preWrite`-style
 *    plugin equivalent — raw↔paired conversion is unnecessary here.
 *
 * Trivia + Spans composition is deferred. When a grammar needs both,
 * the natural layering is Span over Trivia: `SpanTypeSynth` would
 * resolve bearing Refs through the trivia-paired types so the spans
 * pack references `<pack>.trivia.Pairs.<Leaf>T` types instead of raw
 * `<Leaf>`. Until a consumer actually needs both, this stays a future
 * slice — current `HaxeModuleSpanParser` is built with `{spans: true,
 * trivia: false}` and the two synth packs are disjoint by construction.
 */
class SpanTypeSynth {

	private static inline final PAIRED_SUFFIX: String = 'S';
	private static inline final SYNTH_SUBPACK: String = 'spans';
	private static inline final SYNTH_MODULE_LEAF: String = 'Pairs';
	private static inline final SPAN_FIELD_NAME: String = '_span';
	private static inline final KIND_FIELD_NAME: String = '_kind';
	private static inline final SPANNED_META: String = ':spanned';

	private static final shapes: Array<ShapeBuilder.ShapeResult> = [];
	private static final defined: Map<String, Bool> = [];

	public static function arm(shape: ShapeBuilder.ShapeResult): Void {
		if (shapes.indexOf(shape) == -1) shapes.push(shape);
		final rootPack: Array<String> = packOf(shape.root);
		final synthPack: Array<String> = rootPack.concat([SYNTH_SUBPACK]);
		final modulePath: String = synthPack.concat([SYNTH_MODULE_LEAF]).join('.');
		final paired: Array<TypeDefinition> = [];
		for (origName => node in shape.rules) if (node.kind != Terminal) {
			final pairedFqn: String = origName + PAIRED_SUFFIX;
			if (defined.exists(pairedFqn)) continue;
			defined[pairedFqn] = true;
			paired.push(buildTypeDefinition(origName, node, synthPack));
		}
		if (paired.length == 0) return;
		Context.defineModule(modulePath, paired);
	}

	private static function buildTypeDefinition(origName: String, origNode: ShapeNode, synthPack: Array<String>): TypeDefinition {
		final pairedSimple: String = leafOf(origName) + PAIRED_SUFFIX;
		final pos: Position = Context.currentPos();
		return switch origNode.kind {
			case Seq:
				final fields: Array<Field> = [for (child in origNode.children) buildStructField(child, pos, synthPack)];
				if (origNode.readMetaString(SPANNED_META) != null) {
					final spanCT: ComplexType = TPath({ pack: ['anyparse', 'runtime'], name: 'Span', params: [] });
					final stringCT: ComplexType = TPath({ pack: [], name: 'String', params: [] });
					fields.push({
						name: SPAN_FIELD_NAME,
						kind: FVar(spanCT),
						pos: pos,
						access: [],
						meta: []
					});
					fields.push({
						name: KIND_FIELD_NAME,
						kind: FVar(stringCT),
						pos: pos,
						access: [],
						meta: []
					});
				}
				final anon: ComplexType = TAnonymous(fields);
				{
					pos: pos,
					pack: synthPack,
					name: pairedSimple,
					kind: TDAlias(anon),
					fields: []
				};
			case Alt:
				final fields: Array<Field> = [for (branch in origNode.children) buildEnumCtor(branch, pos, synthPack)];
				{
					pos: pos,
					pack: synthPack,
					name: pairedSimple,
					kind: TDEnum,
					fields: fields
				};
			case _:
				Context.fatalError('SpanTypeSynth: unsupported kind ${origNode.kind} for $origName', pos);
				throw 'unreachable';
		};
	}

	private static function buildStructField(child: ShapeNode, pos: Position, synthPack: Array<String>): Field {
		final fieldName: String = child.annotations.get('base.fieldName');
		final ct: ComplexType = shapeToComplexType(child, synthPack);
		final optional: Bool = child.annotations.get('base.optional') == true;
		final meta: Metadata = optional ? [{ name: ':optional', params: [], pos: pos }] : [];
		return {
			name: fieldName,
			kind: FVar(ct),
			pos: pos,
			access: [],
			meta: meta
		};
	}

	private static function buildEnumCtor(branch: ShapeNode, pos: Position, synthPack: Array<String>): Field {
		final ctorName: String = branch.annotations.get('base.ctor');
		final spanCT: ComplexType = TPath({ pack: ['anyparse', 'runtime'], name: 'Span', params: [] });
		final args: Array<FunctionArg> = [
			for (arg in branch.children)
				{
					name: (arg.annotations.get('base.fieldName'): String),
					type: shapeToComplexType(arg, synthPack),
				}
		];
		args.push({ name: SPAN_FIELD_NAME, type: spanCT });
		return {
			name: ctorName,
			kind: FFun({ args: args, ret: null, expr: null }),
			pos: pos,
			access: []
		};
	}

	private static function shapeToComplexType(node: ShapeNode, synthPack: Array<String>): ComplexType {
		return switch node.kind {
			case Ref:
				final refName: String = node.annotations.get('base.ref');
				final base: ComplexType = refIsBearing(refName)
					? TPath({
						pack: synthPack,
						name: SYNTH_MODULE_LEAF,
						sub: leafOf(refName) + PAIRED_SUFFIX,
						params: []
					})
					: TPath({ pack: packOf(refName), name: leafOf(refName), params: [] });
				wrapOptional(node, base);
			case Star:
				final elementCT: ComplexType = shapeToComplexType(node.children[0], synthPack);
				wrapOptional(node, TPath({ pack: [], name: 'Array', params: [TPType(elementCT)] }));
			case Terminal:
				final tp: Null<String> = node.annotations.get('base.typePath');
				if (tp != null) return wrapOptional(node, TPath({ pack: packOf(tp), name: leafOf(tp), params: [] }));
				final under: String = node.annotations.get('base.underlying');
				wrapOptional(node, TPath({ pack: [], name: under, params: [] }));
			case _:
				Context.fatalError('SpanTypeSynth: unexpected node kind ${node.kind} in field-shape', Context.currentPos());
				throw 'unreachable';
		};
	}

	private static inline function wrapOptional(node: ShapeNode, base: ComplexType): ComplexType {
		return node.annotations.get('base.optional') == true ? TPath({ pack: [], name: 'Null', params: [TPType(base)] }) : base;
	}

	private static function refIsBearing(refName: String): Bool {
		for (shape in shapes) {
			final node: Null<ShapeNode> = shape.rules.get(refName);
			if (node != null) return node.kind != Terminal;
		}
		return false;
	}

	private static function packOf(qualifiedName: String): Array<String> {
		final idx: Int = qualifiedName.lastIndexOf('.');
		return idx == -1 ? [] : qualifiedName.substring(0, idx).split('.');
	}

	private static function leafOf(qualifiedName: String): String {
		final idx: Int = qualifiedName.lastIndexOf('.');
		return idx == -1 ? qualifiedName : qualifiedName.substring(idx + 1);
	}

}
#end
