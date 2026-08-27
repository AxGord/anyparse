package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;

using Lambda;

/**
 * Which AST family a generated predicate class is typed against. One
 * marker class per family serves every pipeline that produces values
 * of that family:
 *
 *  - `PredPlain` — plain grammar enums (`HxExpr`, …). Fast/Tolerant
 *    parsers and the plain writer.
 *  - `PredSpans` — the `SpanTypeSynth` paired `*S` enums. Spans parser.
 *  - `PredTrivia` — the `TriviaTypeSynth` paired `*T` enums (bearing
 *    rules) mixed with plain types (non-bearing rules). Trivia parser
 *    and trivia writer.
 */
enum AstPredMode {

	PredPlain;

	PredSpans;

	PredTrivia;

}

/**
 * Base for plugin-side AST-predicate lowerings — the typed replacement
 * for the runtime-introspection adapters (`Dynamic -> Bool` fields on
 * `WriteOptions`, `schema.instance.<pred>` parser gates). A grammar
 * package subclasses this with its domain predicate tables and emits
 * one statics-only marker class per `AstPredMode`; parser/writer
 * emission sites then call the mode's class through the fixed naming
 * convention below instead of dispatching through `Dynamic`.
 *
 * What the base owns is exactly what must not drift between the synth
 * passes and a hand-written predicate: the per-mode constructor PATH
 * (plain enum vs `spans.Pairs.<R>S` vs `trivia.Pairs.<R>T`) and the
 * per-mode constructor ARITY (declared args, `+ _span` for spans,
 * `+ TriviaTypeSynth.extraAltArgs` for trivia-bearing rules). Patterns
 * are built with wildcards everywhere except the explicitly requested
 * bindings, addressed by DECLARED argument index — synth slots are
 * appended at the tail by both synth passes, so declared indices are
 * stable across modes by construction, and the generated pattern (not
 * an `Array<Dynamic>` read) is what enforces it.
 *
 * Naming convention: the marker classes live in the grammar root's
 * package as `<pack>.AstPreds` / `AstPredsT` / `AstPredsS`, so
 * macro-neutral emission sites can address them without referencing
 * any grammar type by name. Synth-module pack derivation deliberately
 * MIRRORS the writer's existing per-mode conventions rather than the
 * synth passes' own definition sites: the spans arm uses
 * `packOf(root)` (as `PairedShapeLowering` does), the trivia arm uses
 * `packOf(rule)` (as `WriterLowering.ruleValueCT` / `ruleCtorPath`
 * do) — equivalent while every rule shares the root's package, and
 * kept in lockstep with the writer so the two generators cannot
 * diverge on the same value.
 */
class AstPredLowering {

	/** Marker-class simple name for `PredPlain`; `T` / `S` suffixed for the paired modes. */
	public static inline final CLASS_BASE_NAME: String = 'AstPreds';

	private final _shape: ShapeBuilder.ShapeResult;
	private final _mode: AstPredMode;

	public function new(shape: ShapeBuilder.ShapeResult, mode: AstPredMode) {
		_shape = shape;
		_mode = mode;
	}

	/** Whether `rule` is trivia-bearing AND this lowering targets the trivia family. */
	private function isTriviaBearing(rule: String): Bool {
		if (_mode != PredTrivia) return false;
		final node: Null<ShapeNode> = _shape.rules[rule];
		return node != null && node.annotations.get(AnnotationKeys.TRIVIA_BEARING) == true;
	}

	/**
	 * The mode's value type for a rule — what a generated predicate's
	 * parameter is annotated with. Mirrors `WriterLowering.ruleValueCT`
	 * (trivia) and `PairedShapeLowering.pairedComplexType` (spans).
	 */
	private function ruleCT(rule: String): ComplexType {
		final simple: String = simpleName(rule);
		return switch _mode {
			case PredSpans if (!isTerminalRule(rule)):
				TPath({
					pack: packOf(_shape.root).concat(['spans']),
					name: 'Pairs',
					sub: '${simple}S',
					params: []
				});
			case PredTrivia if (isTriviaBearing(rule)):
				TPath({
					pack: packOf(rule).concat(['trivia']),
					name: 'Pairs',
					sub: '${simple}T',
					params: []
				});
			case _:
				TPath({ pack: packOf(rule), name: simple, params: [] });
		};
	}

	/** `Null<ruleCT(rule)>` — predicates accept nullable values and answer their default on null. */
	private function ruleNullCT(rule: String): ComplexType {
		return TPath({ pack: [], name: 'Null', params: [TPType(ruleCT(rule))] });
	}

	/** Whether a rule name resolves to a Terminal (primitive leaf — never paired by the synth passes). */
	private function isTerminalRule(rule: String): Bool {
		final node: Null<ShapeNode> = _shape.rules[rule];
		return node == null || node.kind == Terminal;
	}

	/** The `Alt` branch node of `rule`'s ctor `ctor`; fatal when the table names a ctor the grammar lacks. */
	private function branchOf(rule: String, ctor: String): ShapeNode {
		final node: Null<ShapeNode> = _shape.rules[rule];
		if (node == null || node.kind != Alt) {
			Context.fatalError('AstPredLowering: $rule is not an Alt rule', Context.currentPos());
			throw 'unreachable';
		}
		final branch: Null<ShapeNode> = node.children.find(b -> (b.annotations.get(AnnotationKeys.BASE_CTOR): String) == ctor);
		if (branch != null) return branch;
		Context.fatalError('AstPredLowering: $rule has no ctor $ctor', Context.currentPos());
		throw 'unreachable';
	}

	/**
	 * Total pattern arity of `rule.ctor` in this mode: declared args
	 * plus the trailing `_span` (spans) or the `TriviaTypeSynth` synth
	 * slots (trivia-bearing rules). The single-source arity contract —
	 * see `TriviaTypeSynth.extraAltArgs`.
	 */
	private function ctorArity(rule: String, ctor: String): Int {
		final branch: ShapeNode = branchOf(rule, ctor);
		final declared: Int = branch.children.length;
		return switch _mode {
			case PredSpans: declared + 1;
			case PredTrivia if (isTriviaBearing(rule)): declared + TriviaTypeSynth.extraAltArgs(branch);
			case _: declared;
		};
	}

	/** Enum-constructor field-path parts in this mode — mirrors `WriterLowering.ruleCtorPath` / `PairedShapeLowering.ctorPattern`. */
	private function ctorPathParts(rule: String, ctor: String): Array<String> {
		final simple: String = simpleName(rule);
		return switch _mode {
			case PredSpans: packOf(_shape.root).concat(['spans', 'Pairs', '${simple}S', ctor]);
			case PredTrivia if (isTriviaBearing(rule)): packOf(rule).concat(['trivia', 'Pairs', '${simple}T', ctor]);
			case _: packOf(rule).concat([simple, ctor]);
		};
	}

	/**
	 * `Ctor(_, name, _, …)` pattern over the mode's enum: wildcards at
	 * mode arity, with `binds` (declared-index → binding name) naming
	 * the requested operands. Nullary-and-no-synth ctors yield the bare
	 * ctor path.
	 */
	private function pat(rule: String, ctor: String, ?binds: Map<Int, String>): Expr {
		final ctorRef: Expr = MacroStringTools.toFieldExpr(ctorPathParts(rule, ctor));
		final arity: Int = ctorArity(rule, ctor);
		// A bind index past the arity would silently degrade to an
		// all-wildcard pattern and surface later as an unresolved
		// identifier inside the generated class — validate here so the
		// error names the table entry.
		if (binds != null)
			for (i in binds.keys())
				if (i >= arity) Context.fatalError('AstPredLowering: $rule.$ctor has no operand $i (arity $arity)', Context.currentPos());
		if (arity == 0) return ctorRef;
		final args: Array<Expr> = [
			for (i in 0...arity) ident(binds != null && binds.exists(i) ? (binds[i]: String) : '_')
		];
		return { expr: ECall(ctorRef, args), pos: Context.currentPos() };
	}

	/** One switch Case matching each of `ctors` (all-wildcard patterns) with a shared body. */
	private function caseOf(rule: String, ctors: Array<String>, body: Expr): Case {
		return { values: [for (c in ctors) pat(rule, c)], expr: body, guard: null };
	}

	/** One switch Case matching a single ctor with operand bindings. */
	private function caseBind(rule: String, ctor: String, binds: Map<Int, String>, body: Expr): Case {
		return { values: [pat(rule, ctor, binds)], expr: body, guard: null };
	}

	/**
	 * One switch Case or-matching several ctors with the SAME operand
	 * bindings (same declared index, same name — Haxe requires or-pattern
	 * captures to agree in name and type, so the bound operands must be
	 * the same type across all `ctors`).
	 */
	private function caseBindMulti(rule: String, ctors: Array<String>, binds: Map<Int, String>, body: Expr): Case {
		return { values: [for (c in ctors) pat(rule, c, binds)], expr: body, guard: null };
	}

	/** `switch (<subject>) { <cases…>; case _: <dflt>; }` over a non-null enum value. */
	private function sw(subject: Expr, cases: Array<Case>, dflt: Expr): Expr {
		return { expr: ESwitch(subject, cases, dflt), pos: Context.currentPos() };
	}

	/**
	 * `switch (<subject>) { case null: <onNull>; <cases…>; case _: <dflt>; }`
	 * — the standard predicate body over a nullable enum value.
	 */
	private function nullSwitch(subject: Expr, onNull: Expr, cases: Array<Case>, dflt: Expr): Expr {
		return sw(subject, [({ values: [macro null], expr: onNull, guard: null }: Case)].concat(cases), dflt);
	}

	/**
	 * `public static function <name>(<args>): <ret> return <body>;` —
	 * a generated predicate field for the marker class.
	 */
	private function predField(name: String, args: Array<FunctionArg>, ret: ComplexType, body: Expr, ?doc: String): Field {
		return {
			name: name,
			access: [APublic, AStatic],
			kind: FFun({ args: args, ret: ret, expr: macro return $body }),
			pos: Context.currentPos(),
			doc: doc
		};
	}

	/** The standard single-value predicate argument: `<name>: Null<mode-type-of-rule>`. */
	private function valueArg(name: String, rule: String): FunctionArg {
		return { name: name, type: ruleNullCT(rule) };
	}

	/** Non-null single-value predicate argument — for a Star element, which is never null. */
	private function bareArg(name: String, rule: String): FunctionArg {
		return { name: name, type: ruleCT(rule) };
	}

	/**
	 * Whether elements of the `Seq` rule's Star field are
	 * `Trivial<…>`-wrapped in this lowering's family — trivia mode,
	 * bearing owner, `trivia.starCollects` on the field. Plain / spans
	 * elements are always bare.
	 */
	private function starElemWrapped(ownerRule: String, fieldName: String): Bool {
		if (_mode != PredTrivia) return false;
		// Unknown rule / field would silently disable the `.node` unwrap
		// — an author error in the predicate table, not a mode question.
		final node: Null<ShapeNode> = _shape.rules[ownerRule];
		if (node == null || node.kind != Seq) {
			Context.fatalError('AstPredLowering: $ownerRule is not a Seq rule', Context.currentPos());
			throw 'unreachable';
		}
		final child: Null<ShapeNode> = node.children.find(c -> (c.annotations.get(AnnotationKeys.BASE_FIELD_NAME): String) == fieldName);
		if (child != null) return isTriviaBearing(ownerRule) && child.annotations.get(AnnotationKeys.TRIVIA_STAR_COLLECTS) == true;
		Context.fatalError('AstPredLowering: $ownerRule has no field $fieldName', Context.currentPos());
		throw 'unreachable';
	}

	/** `<elemExpr>.node` when this family wraps the Star's elements in `Trivial<…>`, else the element unchanged. */
	private function starElem(ownerRule: String, fieldName: String, elemExpr: Expr): Expr {
		return starElemWrapped(ownerRule, fieldName) ? field(elemExpr, 'node') : elemExpr;
	}

	private function ident(name: String): Expr {
		return { expr: EConst(CIdent(name)), pos: Context.currentPos() };
	}

	private function field(target: Expr, name: String): Expr {
		return { expr: EField(target, name), pos: Context.currentPos() };
	}

	/** Simple (unqualified) name of a type path. */
	public static inline function simpleName(typePath: String): String {
		return PairedShapeLowering.simpleName(typePath);
	}

	/** Package parts of a type path, empty for a root-package type. */
	public static inline function packOf(typePath: String): Array<String> {
		return PairedShapeLowering.packOf(typePath);
	}

	/**
	 * Fully-qualified path parts of the predicate marker class serving
	 * the pipeline described by (`trivia`, `spans`) for the grammar
	 * rooted at `rootTypePath`. Emission sites feed their own build
	 * flags: a trivia build's values are the `*T` family even for
	 * non-bearing rules (whose predicates the `T` class still carries,
	 * typed plain), so the choice depends only on the build mode.
	 */
	public static function predClassParts(rootTypePath: String, trivia: Bool, spans: Bool): Array<String> {
		// The two flags describe mutually exclusive pipelines; a caller
		// passing both has confused its build context — fail at macro
		// time instead of silently preferring one family.
		if (trivia && spans) Context.fatalError('AstPredLowering: a build cannot be both trivia and spans', Context.currentPos());
		final suffix: String = if (spans)
			'S'
		else if (trivia)
			'T'
		else
			'';
		return packOf(rootTypePath).concat(['$CLASS_BASE_NAME$suffix']);
	}

	/**
	 * `<PredClass>.<name>(<args>)` call expression for an emission site
	 * in `Lowering` / `WriterLowering` — the typed replacement for
	 * `opt.<adapter>(raw)` / `schema.instance.<pred>(raw)`.
	 */
	public static function predCallExpr(rootTypePath: String, trivia: Bool, spans: Bool, name: String, args: Array<Expr>): Expr {
		final callee: Expr = predFnExpr(rootTypePath, trivia, spans, name);
		return { expr: ECall(callee, args), pos: Context.currentPos() };
	}

	/**
	 * `<PredClass>.<name>` function-reference expression — for emission
	 * sites that must apply the predicate to receivers only they know
	 * (built where the Star's element rule is in scope, applied deeper
	 * in the static emit pipeline).
	 */
	public static function predFnExpr(rootTypePath: String, trivia: Bool, spans: Bool, name: String): Expr {
		return MacroStringTools.toFieldExpr(predClassParts(rootTypePath, trivia, spans).concat([name]));
	}

}
#end
