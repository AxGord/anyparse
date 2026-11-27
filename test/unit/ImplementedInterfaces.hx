package unit;

/**
 * The one answer to "which interfaces does a class implement, itself and through its superclasses and
 * super-interfaces": read at compile time from the class's type, one full dotted name per path that reaches one.
 */
class ImplementedInterfaces {

	/** The full dotted names of the interfaces the class `path` implements, as an array literal. */
	public static macro function of(path: String): haxe.macro.Expr {
		final names: Array<String> = [];
		function walk(ct: haxe.macro.Type.ClassType): Void {
			for (i in ct.interfaces) {
				final iface: haxe.macro.Type.ClassType = i.t.get();
				names.push(iface.pack.concat([iface.name]).join('.'));
				walk(iface);
			}
			if (ct.superClass != null) walk(ct.superClass.t.get());
		}
		switch haxe.macro.Context.getType(path) {
			case TInst(c, _):
				walk(c.get());
			case _:
				haxe.macro.Context.error('not a class: $path', haxe.macro.Context.currentPos());
		}
		return macro $v{names};
	}

}
