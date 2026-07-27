package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;
import anyparse.core.ShapeTree;

using Lambda;
using anyparse.macro.MetaInspect;

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
 * package as `<pack>.AstPreds` / `AstPredsT` / `AstPredsS` — the same
 * root-derived convention as the `spans.Pairs` / `trivia.Pairs` synth
 * modules, so macro-neutral emission sites can address them without
 * referencing any grammar type by name.
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

	/**
	 * Fully-qualified path parts of the predicate marker class serving
	 * the pipeline described by (`trivia`, `spans`) for the grammar
	 * rooted at `rootTypePath`. Emission sites feed their own build
	 * flags: a trivia build's values are the `*T` family even for
	 * non-bearing rules (whose predicates the `T` class still carries,
	 * typed plain), so the choice depends only on the build mode.
	 */
	public static function predClassParts(rootTypePath: String, trivia: Bool, spans: Bool): Array<String> {
		final suffix: String = spans ? 'S' : trivia ? 'T' : '';
		return packOf(rootTypePath).concat(['$CLASS_BASE_NAME$suffix']);
	}

	/**
	 * `<PredClass>.<name>(<args>)` call expression for an emission site
	 * in `Lowering` / `WriterLowering` — the typed replacement for
	 * `opt.<adapter>(raw)` / `schema.instance.<pred>(raw)`.
	 */
	public static function predCallExpr(rootTypePath: String, trivia: Bool, spans: Bool, name: String, args: Array<Expr>): Expr {
		final callee: Expr = MacroStringTools.toFieldExpr(predClassParts(rootTypePath, trivia, spans).concat([name]));
		return { expr: ECall(callee, args), pos: Context.currentPos() };
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

	/** Whether `rule` is trivia-bearing AND this lowering targets the trivia family. */
	private function isTriviaBearing(rule: String): Bool {
		if (_mode != PredTrivia) return false;
		final node: Null<ShapeNode> = _shape.rules.get(rule);
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
				TPath({ pack: packOf(_shape.root).concat(['spans']), name: 'Pairs', sub: '${simple}S', params: [] });
			case PredTrivia if (isTriviaBearing(rule)):
				TPath({ pack: packOf(rule).concat(['trivia']), name: 'Pairs', sub: '${simple}T', params: [] });
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
		final node: Null<ShapeNode> = _shape.rules.get(rule);
		return node == null || node.kind == Terminal;
	}

	/** The `Alt` branch node of `rule`'s ctor `ctor`; fatal when the table names a ctor the grammar lacks. */
	private function branchOf(rule: String, ctor: String): ShapeNode {
		final node: Null<ShapeNode> = _shape.rules.get(rule);
		if (node == null || node.kind != Alt) {
			Context.fatalError('AstPredLowering: $rule is not an Alt rule', Context.currentPos());
			throw 'unreachable';
		}
		final branch: Null<ShapeNode> = node.children.find(
			b -> (b.annotations.get(AnnotationKeys.BASE_CTOR): String) == ctor
		);
		if (branch == null) {
			Context.fatalError('AstPredLowering: $rule has no ctor $ctor', Context.currentPos());
			throw 'unreachable';
		}
		return branch;
	}

	/**
	 * Total pattern arity of `rule.ctor` in this mode: declared args
	 * plus the trailing `_span` (spans) or the `TriviaTypeSynth` synth
	 * slots (trivia-bearing rules). The single-source arity contract —
	 * see `TriviaTypeSynth.extraAltArgs`.
	 */
	private function ctorArity(rule: String, ctor: String): Int {
		final declared: Int = branchOf(rule, ctor).children.length;
		return switch _mode {
			case PredSpans: declared + 1;
			case PredTrivia if (isTriviaBearing(rule)): declared + TriviaTypeSynth.extraAltArgs(branchOf(rule, ctor));
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
	 * `switch (<subject>) { case null: <onNull>; <cases…>; case _: <dflt>; }`
	 * — the standard predicate body over a nullable enum value.
	 */
	private function nullSwitch(subject: Expr, onNull: Expr, cases: Array<Case>, dflt: Expr): Expr {
		final all: Array<Case> = [{ values: [macro null], expr: onNull, guard: null }];
		for (c in cases) all.push(c);
		return { expr: ESwitch(subject, all, dflt), pos: Context.currentPos() };
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
			doc: doc,
		};
	}

	/** The standard single-value predicate argument: `<name>: Null<mode-type-of-rule>`. */
	private function valueArg(name: String, rule: String): FunctionArg {
		return { name: name, type: ruleNullCT(rule) };
	}

	private function ident(name: String): Expr {
		return { expr: EConst(CIdent(name)), pos: Context.currentPos() };
	}

	private function field(target: Expr, name: String): Expr {
		return { expr: EField(target, name), pos: Context.currentPos() };
	}

}
#end
