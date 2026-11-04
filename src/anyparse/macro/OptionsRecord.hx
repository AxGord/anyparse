package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

/**
 * The one answer to "how does a grammar's write-options record stay a value every target loads".
 *
 * A struct literal on the JVM target is a call to a synthesized constructor taking every field as an argument, and
 * a method descriptor holds `JVM_ARG_SLOTS` slots beside `this`; past that the jar loads into a `ClassFormatError`.
 * An options typedef therefore has a ceiling (`refuseOverSlotLimit` names it at build time), and a grammar that
 * outgrows it declares a class through `build`, whose only constructor takes at most one argument.
 *
 * Why the class keeps no initializer of its own: Haxe runs initializers in the constructor, so a clone would run the
 * defaults and allocate each default's nested records before overwriting them. `build` moves them behind the branch.
 */
final class OptionsRecord {

	/** A JVM method descriptor's argument slots, `this` excluded: a class file refuses a 255th. */
	private static inline final JVM_ARG_SLOTS: Int = 254;

	/**
	 * The fields of a `@:build` options class, with its constructor generated: `new T()` is the defaults, `new T(from)`
	 * a clone assigning the fields in one order, so both produce one object shape for the engine and a read at a
	 * site that sees either stays monomorphic. A knob with no initializer has no default to give, so the build refuses it.
	 */
	public static function build(): Array<Field> {
		final fields: Array<Field> = Context.getBuildFields();
		final localRef: Null<Ref<ClassType>> = Context.getLocalClass();
		if (localRef == null) throw new Error('OptionsRecord.build runs as the @:build of a class', Context.currentPos());
		final local: ClassType = localRef.get();
		final self: ComplexType = TPath({ pack: local.pack, name: local.name, params: [] });
		final defaults: Array<Expr> = [];
		final copies: Array<Expr> = [];
		for (f in fields) {
			final name: String = f.name;
			switch (f.kind) {
				case FVar(t, init):
					if (init == null) Context.error('OptionsRecord: ${local.name}.$name declares no default', f.pos);
					f.kind = FVar(t, null);
					defaults.push(macro this.$name = $init);
					copies.push(macro this.$name = from.$name);
				case _:
					Context.error('OptionsRecord: ${local.name}.$name is not a plain field; a record holds knobs only', f.pos);
			}
		}
		fields.push({
			name: 'new',
			access: [APublic],
			kind: FFun({
				args: [{ name: 'from', opt: true, type: self }],
				ret: macro : Void,
				expr: macro if (from != null)
					$b{copies}
				else
					$b{defaults}
			}),
			pos: Context.currentPos()
		});
		return fields;
	}

	/** Refuses, naming the count, an options struct whose literal the JVM target could not construct. */
	public static function refuseOverSlotLimit(optionsTypePath: String, fields: Array<ClassField>, pos: Position): Void {
		var slots: Int = 0;
		for (f in fields) slots += argSlots(f.type);
		if (slots > JVM_ARG_SLOTS)
			Context.error(
				'OptionsRecord: options struct $optionsTypePath takes $slots JVM argument slots, past the limit of $JVM_ARG_SLOTS: '
				+ 'declare it as a class with @:build(anyparse.macro.Build.buildOptionsRecord())',
				pos
			);
	}

	/**
	 * A `double` or a `long` argument takes two slots, a boxed `Null<Float>` one, which the follow helpers would peel to a `Float`.
	 */
	private static function argSlots(t: Type): Int {
		return switch (t) {
			case TType(_, _), TLazy(_): argSlots(Context.follow(t, true));
			case TAbstract(_.toString() => 'Null', _): 1;
			case TAbstract(_.toString() => 'haxe.Int64', _): 2;
			case _: Context.followWithAbstracts(t).match(TAbstract(_.toString() => 'Float', _)) ? 2 : 1;
		};
	}

}
#end
