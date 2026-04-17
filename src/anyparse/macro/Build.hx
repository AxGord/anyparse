package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.ExprTools;
import haxe.macro.Type;
import anyparse.core.LoweringCtx;
import anyparse.core.Mode;
import anyparse.macro.strategy.Bin;
import anyparse.macro.strategy.Kw;
import anyparse.macro.strategy.Lit;
import anyparse.macro.strategy.Postfix;
import anyparse.macro.strategy.Pratt;
import anyparse.macro.strategy.Prefix;
import anyparse.macro.strategy.Re;
import anyparse.macro.strategy.Skip;
import anyparse.macro.strategy.Ternary;

/**
 * `@:build` entry point. Applied to a marker class like
 * `JValueParser` with the grammar root type as an argument:
 *
 * ```haxe
 * @:build(anyparse.macro.Build.buildParser(anyparse.grammar.json.JValue))
 * class JValueParser {}
 * ```
 *
 * The marker-class pattern is deliberate: placing `@:build` on the
 * grammar enum itself was tried first but Haxe's enum constructor
 * information is not available at `@:build` time on the enum — the
 * macro sees an empty `names` list and ends up generating an empty
 * parser. A side-class reads the grammar type *after* it has been
 * fully elaborated, which is exactly what we need.
 *
 * The pipeline runs:
 *
 *  1. Resolve the grammar root (`Context.getType(fullTypePath)`).
 *  2. Read `@:schema(Format)` off the grammar and resolve the format.
 *  3. `ShapeBuilder` walks the root into a `ShapeTree`.
 *  4. `StrategyRegistry` runs the annotate pass.
 *  5. `Lowering` produces one `GeneratedRule` per discovered rule.
 *  6. `Codegen` turns the rules into `Array<Field>` and returns them
 *     so that Haxe installs them as the marker class's body.
 */
class Build {

	public static macro function buildParser(target:Expr):Array<Field> {
		final targetTypePath:String = ExprTools.toString(target);
		final rootType:Type = Context.getType(targetTypePath);

		final rootMeta:Metadata = switch rootType {
			case TEnum(ref, _): ref.get().meta.get();
			case TType(ref, _): ref.get().meta.get();
			case TAbstract(ref, _): ref.get().meta.get();
			case TInst(ref, _): ref.get().meta.get();
			case _:
				Context.fatalError('Build.buildParser: unsupported target type $targetTypePath', Context.currentPos());
				throw 'unreachable';
		};

		final schemaTypePath:String = readSchemaMeta(rootMeta, targetTypePath);
		final formatInfo:FormatReader.FormatInfo = FormatReader.resolve(schemaTypePath);

		final ctx:LoweringCtx = new LoweringCtx();
		ctx.mode = Mode.Fast;

		final shapeBuilder:ShapeBuilder = new ShapeBuilder();
		final shape:ShapeBuilder.ShapeResult = shapeBuilder.build(rootType);

		final registry:StrategyRegistry = new StrategyRegistry();
		registry.register(new Bin());
		registry.register(new Kw());
		registry.register(new Lit());
		registry.register(new Postfix());
		registry.register(new Pratt());
		registry.register(new Ternary());
		registry.register(new Prefix());
		registry.register(new Re());
		registry.register(new Skip());
		registry.prepare();
		registry.runAnnotate(shape, ctx);

		final lowering:Lowering = new Lowering(shape, formatInfo, ctx);
		final rules:Array<GeneratedRule> = lowering.generate();

		final rootSimple:String = simpleName(shape.root);
		final rootReturnCT:ComplexType = TPath({pack: packOf(shape.root), name: rootSimple, params: []});
		final fields:Array<Field> = Codegen.emit(rules, shape.root, rootReturnCT, formatInfo);

		#if anyparse_dump
		final printer:haxe.macro.Printer = new haxe.macro.Printer();
		for (f in fields) Sys.println('// field: ${printer.printField(f)}');
		#end

		return fields;
	}

	public static macro function buildWriter(target:Expr, ?options:Expr):Array<Field> {
		final targetTypePath:String = ExprTools.toString(target);
		final rootType:Type = Context.getType(targetTypePath);

		final rootMeta:Metadata = switch rootType {
			case TEnum(ref, _): ref.get().meta.get();
			case TType(ref, _): ref.get().meta.get();
			case TAbstract(ref, _): ref.get().meta.get();
			case TInst(ref, _): ref.get().meta.get();
			case _:
				Context.fatalError('Build.buildWriter: unsupported target type $targetTypePath', Context.currentPos());
				throw 'unreachable';
		};

		final schemaTypePath:String = readSchemaMeta(rootMeta, targetTypePath);
		final formatInfo:FormatReader.FormatInfo = FormatReader.resolve(schemaTypePath);

		final optionsTypePath:Null<String> = extractTypePath(options);
		if (optionsTypePath == null && !formatInfo.isBinary)
			Context.fatalError('Build.buildWriter: text writer requires an options typedef — '
				+ 'use @:build(Build.buildWriter($targetTypePath, <OptionsT>))', Context.currentPos());
		if (optionsTypePath != null && formatInfo.isBinary)
			Context.fatalError('Build.buildWriter: binary writer does not accept an options typedef '
				+ '— drop the second argument', Context.currentPos());

		final ctx:LoweringCtx = new LoweringCtx();
		ctx.mode = Mode.Fast;

		final shapeBuilder:ShapeBuilder = new ShapeBuilder();
		final shape:ShapeBuilder.ShapeResult = shapeBuilder.build(rootType);

		final registry:StrategyRegistry = new StrategyRegistry();
		registry.register(new Bin());
		registry.register(new Kw());
		registry.register(new Lit());
		registry.register(new Postfix());
		registry.register(new Pratt());
		registry.register(new Ternary());
		registry.register(new Prefix());
		registry.register(new Re());
		registry.register(new Skip());
		registry.prepare();
		registry.runAnnotate(shape, ctx);

		final rules:Array<WriterLowering.WriterRule> = if (formatInfo.isBinary)
			new BinaryWriterLowering(shape).generate()
		else
			new WriterLowering(shape, formatInfo).generate();

		final rootSimple:String = simpleName(shape.root);
		final rootReturnCT:ComplexType = TPath({pack: packOf(shape.root), name: rootSimple, params: []});
		final fields:Array<Field> = WriterCodegen.emit(rules, shape.root, rootReturnCT, formatInfo, optionsTypePath);

		#if anyparse_dump
		final printer:haxe.macro.Printer = new haxe.macro.Printer();
		for (f in fields) Sys.println('// writer field: ${printer.printField(f)}');
		#end

		return fields;
	}

	private static function extractTypePath(e:Null<Expr>):Null<String> {
		if (e == null) return null;
		// Haxe passes a null-literal Expr (`EConst(CIdent("null"))`) when the
		// caller omits an optional macro arg at a `@:build(...)` meta call,
		// rather than letting the macro see a plain `null` reference.
		return switch e.expr {
			case EConst(CIdent('null')): null;
			case _: ExprTools.toString(e);
		};
	}

	private static function readSchemaMeta(meta:Metadata, targetTypePath:String):String {
		for (entry in meta) if (entry.name == ':schema') {
			if (entry.params.length != 1) {
				Context.fatalError('@:schema expects exactly one argument', entry.pos);
			}
			return ExprTools.toString(entry.params[0]);
		}
		Context.fatalError('@:peg grammar $targetTypePath is missing @:schema(Format)', Context.currentPos());
		throw 'unreachable';
	}

	private static function simpleName(typePath:String):String {
		final idx:Int = typePath.lastIndexOf('.');
		return idx == -1 ? typePath : typePath.substring(idx + 1);
	}

	private static function packOf(typePath:String):Array<String> {
		final idx:Int = typePath.lastIndexOf('.');
		return idx == -1 ? [] : typePath.substring(0, idx).split('.');
	}
}
#end
