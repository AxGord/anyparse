package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.ExprTools;
import haxe.macro.Type;
import haxe.macro.TypeTools;
#end

/**
 * The one answer to "how does a record of options name the type of each knob as data": `OptionKnobs.of(Rec)` reads a class declared
 * with `OptionsRecord` and builds one `OptionKnob` per field, whose `OptionShape` is what `OptionsSource` needs to spell a value
 * as Haxe source. A type without a spelling becomes `Opaque`, so a new knob of an exotic type breaks no build; it is refused when
 * an edit changes it.
 */
final class OptionKnobs {

	/** The knobs of the options record class named by `record`, in declaration order. */
	public static macro function of(record: Expr): Expr {
		final path: String = ExprTools.toString(record);
		final type: Type = Context.getType(path);
		final fields: Array<ClassField> = switch type {
			case TInst(ref, _): ref.get().fields.get();
			case _: Context.error('OptionKnobs.of: $path is not a class', record.pos);
		};
		final recordType: ComplexType = TypeTools.toComplexType(type);
		final knobs: Array<Expr> = [];
		for (f in fields) switch f.kind {
			case FVar(_, _):
				final name: String = f.name;
				final shape: Expr = shapeOf(f.type, []);
				knobs.push(macro {
					name: $v{name},
					shape: $shape,
					read: (o: Dynamic) -> {
						final r: $recordType = o;
						(r.$name: Dynamic);
					}
				});
			case _:
		}
		return macro ($a{knobs}: Array<anyparse.format.OptionsSource.OptionKnob>);
	}

	#if macro
	private static function shapeOf(type: Type, open: Array<String>): Expr {
		switch type {
			case TLazy(resolve):
				return shapeOf(resolve(), open);
			case TAbstract(ref, params):
				final a: AbstractType = ref.get();
				if (isStd(a.pack, a.name, 'Null'))
					return macro anyparse.format.OptionsSource.OptionShape.Nullable(${shapeOf(params[0], open)});
				if (isStd(a.pack, a.name, 'Bool') || isStd(a.pack, a.name, 'Int') || isStd(a.pack, a.name, 'Float'))
					return macro anyparse.format.OptionsSource.OptionShape.Scalar;
				return a.meta.has(':enum') ? constantsOf(type, a) : opaque(type);
			case TInst(ref, params):
				final c: ClassType = ref.get();
				if (isStd(c.pack, c.name, 'String')) return macro anyparse.format.OptionsSource.OptionShape.Text;
				if (isStd(c.pack, c.name, 'Array'))
					return macro anyparse.format.OptionsSource.OptionShape.List(${shapeOf(params[0], open)});
				return opaque(type);
			case TType(ref, _):
				final d: DefType = ref.get();
				final id: String = '${d.module}.${d.name}';
				if (open.contains(id)) return macro anyparse.format.OptionsSource.OptionShape.Again($v{id});
				final under: Type = TypeTools.follow(type);
				return switch under {
					case TAnonymous(anon): recordOf(id, anon.get().fields, open.concat([id]));
					case _: shapeOf(under, open);
				};
			case TAnonymous(anon):
				return recordOf(TypeTools.toString(type), anon.get().fields, open);
			case _:
				return opaque(type);
		}
	}

	private static function recordOf(id: String, fields: Array<ClassField>, open: Array<String>): Expr {
		final entries: Array<Expr> = [
			for (f in fields) macro { name: $v{f.name}, optional: $v{f.meta.has(':optional')}, shape: ${shapeOf(f.type, open)} }
		];
		return macro anyparse.format.OptionsSource.OptionShape.Record($v{id}, $a{entries});
	}

	private static function constantsOf(type: Type, a: AbstractType): Expr {
		final parts: Array<String> = a.module.split('.');
		final importPath: String = parts[parts.length - 1] == a.name ? a.module : '${a.module}.${a.name}';
		if (parts[parts.length - 1] != a.name) parts.push(a.name);
		final impl: Null<Ref<ClassType>> = a.impl;
		if (impl == null) return opaque(type);
		final names: Array<Expr> = [
			for (s in impl.get().statics.get()) if (s.meta.has(':enum')) {
				final path: Array<String> = parts.concat([s.name]);
				macro { name: $v{s.name}, value: ($p{path}: Dynamic) };
			}
		];
		return macro anyparse.format.OptionsSource.OptionShape.Constants($v{a.name}, $v{importPath}, $a{names});
	}

	private static function opaque(type: Type): Expr {
		return macro anyparse.format.OptionsSource.OptionShape.Opaque($v{TypeTools.toString(type)});
	}

	private static inline function isStd(pack: Array<String>, name: String, expected: String): Bool {
		return pack.length == 0 && name == expected;
	}
	#end

}
