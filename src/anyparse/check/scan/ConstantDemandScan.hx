package anyparse.check.scan;

import anyparse.check.scan.ConstantFieldScan;
import anyparse.check.scan.ReflectionScan.ScopeFile;
import anyparse.query.MemberKinds;
import anyparse.query.ParseGate;

/**
 * What in a run depends on a constant's compile-time value or on its already being assigned: the one answer to "must
 * this constant stay inline". A name a position of those kinds spells is held, by simple name over its subtree, so the
 * answer can only over-keep; a keep costs a shared literal, a wrong drop does not compile or reads an unset field.
 *
 * Compile-time positions (the compiler refuses a non-inline read): a parameter default (a bare name or a qualified
 * one, in a member, lambda, constructor or another file), a `static inline` initializer, a field value of an abstract
 * (`implicitStaticFieldHostKinds`), the first argument of a `targetCodeCallNames` call.
 *
 * Init-order positions (a non-inline read compiles and sees an unset field on js, neko, interp and, by the order of the
 * classes' boot, hxcpp): any other static or module-level initializer, an instance field's initializer and a
 * constructor of any type (either can run while a static initializer of another type allocates it), a local static's
 * initializer, and a `staticInitFunctionNames` function, which runs before them all. A direct read is the bound: no
 * walk through the calls those make. `runsCode` answers the indirect form, an earlier initializer that may reach the
 * field through a call, and `staticInitRunsCode` the same through a static-init function of the constant's own type.
 *
 * Still unseen: a read through a function inside a static-init cycle between classes (the compiler warns on such a
 * cycle, `WStaticInitOrder`); a static-init function of ANOTHER type reaching the constant through a function; a
 * property getter run by an earlier static initializer; a macro that types its argument and needs a constant. See
 * `InlineConstant` for the rule that consults this.
 */
@:nullSafety(Strict)
final class ConstantDemandScan {

	public final names: Map<String, Bool>;

	private final _callKinds: Array<String>;
	private final _staticInitFunctionNames: Array<String>;

	private function new(names: Map<String, Bool>, callKinds: Array<String>, staticInitFunctionNames: Array<String>) {
		this.names = names;
		_callKinds = callKinds;
		_staticInitFunctionNames = staticInitFunctionNames;
	}

	/** Whether the initializer `init` holds a call or an allocation, so running it may reach any field of the type. */
	public inline function runsCode(init: QueryNode): Bool {
		return MemberKinds.subtreeContainsAnyKind(init, _callKinds);
	}

	/** Whether `member` is a static-init function holding a call or an allocation: it runs before every initializer. */
	public function staticInitRunsCode(member: QueryNode): Bool {
		return _staticInitFunctionNames.contains(member.name ?? '') && runsCode(member);
	}

	/** Every name the demanding positions of the run's whole scope (`scopeFiles`, not only the linted files) spell. */
	public static function of(files: Array<ScopeFile>, plugin: GrammarPlugin, constants: ConstantFieldSeams): ConstantDemandScan {
		final shape: RefShape = plugin.refShape();
		final functionKinds: Array<String> = shape.functionKinds ?? [];
		final staticInitFunctionNames: Array<String> = shape.execution?.staticInitFunctionNames ?? [];
		final seams: DemandSeams = {
			constants: constants,

			paramKinds: shape.paramKinds ?? [],
			moduleValueKinds: [for (k in shape.moduleValueDeclKinds) if (!functionKinds.contains(k)) k],
			staticLocalKinds: shape.staticLocalDeclKinds ?? [],
			staticInitFunctionNames: staticInitFunctionNames,
			constructorName: shape.constructorName,
			callKind: shape.callKind,
			targetCodeCallNames: shape.execution?.targetCodeCallNames ?? []
		};
		final names: Map<String, Bool> = [];
		for (entry in ReflectionScan.scopeFiles(files, plugin)) {
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, entry.source);
			if (tree != null) walk(tree, entry.source, seams, names);
		}
		final call: Null<String> = shape.callKind;
		final alloc: Null<String> = shape.newExprKind;
		return new ConstantDemandScan(names, [for (kind in [call, alloc]) if (kind != null) kind], staticInitFunctionNames);
	}

	/** Record the demanding positions under `node`. */
	private static function walk(node: QueryNode, source: String, seams: DemandSeams, out: Map<String, Bool>): Void {
		final constants: ConstantFieldSeams = seams.constants;
		for (child in node.children) {
			final kind: String = child.kind;
			if (constants.members.contains(kind)) {
				final isField: Bool = constants.finalFieldKinds.contains(kind) || constants.mutableFieldKinds.contains(kind);
				if (isField) demand(ConstantFieldScan.initializerOf(child), source, seams, out);
				if (seams.staticInitFunctionNames.contains(child.name ?? '') || isConstructor(child, seams)) spellNames(child, out);
			} else if (seams.moduleValueKinds.contains(kind) || seams.paramKinds.contains(kind)) {
				demand(ConstantFieldScan.initializerOf(child), source, seams, out);
			} else if (seams.staticLocalKinds.contains(kind)) {
				// The whole declaration: a multi-binding form nests the later initializers in continuation nodes.
				spellNames(child, out);
			} else if (isTargetCodeCall(child, seams)) {
				demand(child.children[1], source, seams, out);
			}
			walk(child, source, seams, out);
		}
	}

	/** Whether `node` is a call of a target-code name; the name alone answers, so an unrelated `x.code(a)` only over-keeps. */
	private static function isTargetCodeCall(node: QueryNode, seams: DemandSeams): Bool {
		return node.kind == seams.callKind && node.children.length > 1 && seams.targetCodeCallNames.contains(node.children[0].name ?? '');
	}

	/** Record the names `value` spells. A plain string literal is no read, whatever its content happens to be. */
	private static function demand(value: Null<QueryNode>, source: String, seams: DemandSeams, out: Map<String, Bool>): Void {
		if (value != null && !ConstantFieldScan.isPlainStringLiteral(value, source, seams.constants)) spellNames(value, out);
	}

	/**
	 * Record every name in `node`'s subtree: a qualified path and an interpolated segment project their parts as nodes.
	 * A string segment equal to a name only over-keeps.
	 */
	private static function spellNames(node: QueryNode, out: Map<String, Bool>): Void {
		final name: Null<String> = node.name;
		if (name != null) out[name] = true;
		for (child in node.children) spellNames(child, out);
	}

	/** Whether `member` is the type's constructor, which runs while every instance field initializer of the type does. */
	private static function isConstructor(member: QueryNode, seams: DemandSeams): Bool {
		return seams.constructorName != null && member.name == seams.constructorName;
	}

}

/** The grammar seams `ConstantDemandScan.walk` reads, resolved once per run. */
private typedef DemandSeams = {
	final constants: ConstantFieldSeams;
	final paramKinds: Array<String>;
	final moduleValueKinds: Array<String>;
	final staticLocalKinds: Array<String>;
	final staticInitFunctionNames: Array<String>;
	final constructorName: Null<String>;
	final callKind: Null<String>;
	final targetCodeCallNames: Array<String>;
};
