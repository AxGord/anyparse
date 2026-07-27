package anyparse.grammar.haxe;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.ExprTools;
import haxe.macro.Type;
import anyparse.macro.AstPredLowering.AstPredMode;
import anyparse.macro.FormatReader;
import anyparse.macro.FormatReader.FormatInfo;
import anyparse.macro.ShapeBuilder;
import anyparse.macro.ShapeBuilder.ShapeResult;
import anyparse.macro.SpanTypeSynth;
import anyparse.macro.TriviaAnalysis;
import anyparse.macro.TriviaTypeSynth;

using Lambda;

/**
 * `@:build` entry for the `AstPreds` / `AstPredsT` / `AstPredsS`
 * marker classes — the per-mode typed AST predicates the generated
 * parsers and writers call at their shape-gate emission sites (see
 * `AstPredLowering` for the naming convention and `HxAstPredLowering`
 * for the predicate tables).
 *
 * The schema-resolution prologue mirrors `Build.buildQueryWalker`;
 * the shape pass mirrors `Build.buildParser`'s
 * `buildShapeWithTrivia` + spans arm: build the same `ShapeTree` the
 * parser/writer builds see, run `TriviaAnalysis` always (bearing
 * marks), arm the mode's type synth (idempotent — the parser build
 * arms the same batch), then hand the shape to the domain lowering.
 * No strategy annotate pass: the predicate generator reads only base
 * shape and raw metas.
 */
class HxPredBuild {

	private static inline final ROOT: String = 'anyparse.grammar.haxe.HxModule';

	public static macro function build(?options: Expr): Array<Field> {
		final trivia: Bool = readFlag(options, 'trivia');
		final spans: Bool = readFlag(options, 'spans');
		final rootType: Type = Context.getType(ROOT);
		final rootMeta: Metadata = switch rootType {
			case TEnum(ref, _): ref.get().meta.get();
			case TType(ref, _): ref.get().meta.get();
			case TAbstract(ref, _): ref.get().meta.get();
			case TInst(ref, _): ref.get().meta.get();
			case _:
				Context.fatalError('HxPredBuild: unsupported root type $ROOT', Context.currentPos());
				throw 'unreachable';
		};
		// First-match + explicit arity error, same semantics as
		// `Build.readSchemaMeta` (private there, so re-stated here).
		final schemaEntry: Null<MetadataEntry> = rootMeta.find(e -> e.name == ':schema');
		if (schemaEntry == null) {
			Context.fatalError('HxPredBuild: $ROOT is missing @:schema(Format)', Context.currentPos());
			throw 'unreachable';
		}
		if (schemaEntry.params.length != 1) Context.fatalError('@:schema expects exactly one argument', schemaEntry.pos);
		final formatInfo: FormatInfo = FormatReader.resolve(ExprTools.toString(schemaEntry.params[0]));
		final shape: ShapeResult = new ShapeBuilder(formatInfo).build(rootType);
		TriviaAnalysis.run(shape);
		if (trivia) TriviaTypeSynth.arm(shape);
		if (spans) SpanTypeSynth.arm(shape);
		final mode: AstPredMode = spans ? PredSpans : trivia ? PredTrivia : PredPlain;
		return new HxAstPredLowering(shape, mode).generate();
	}

	/** Read a literal-`true` Bool field off the `{trivia: true}`-style options struct. */
	private static function readFlag(options: Null<Expr>, name: String): Bool {
		if (options == null) return false;
		return switch options.expr {
			case EConst(CIdent('null')): false;
			case EObjectDecl(fields):
				fields.exists(f -> f.field == name && f.expr.expr.match(EConst(CIdent('true'))));
			case _:
				Context.fatalError('HxPredBuild: options must be an anonymous-struct literal (e.g. `{trivia: true}`)', options.pos);
				throw 'unreachable';
		};
	}

}
#end
