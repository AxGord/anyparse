package anyparse.check.scan;

import anyparse.check.scan.ConstantFieldScan;
import anyparse.check.scan.ReflectionScan.ScopeFile;
import anyparse.query.MemberKinds;
import anyparse.query.ParseGate;

/**
 * What in a run depends on a constant's compile-time value or on its already being assigned: the one answer to "must
 * this constant stay inline". A name a position of those kinds spells is held over its subtree, by simple name and what
 * qualifies it (`holds`), so the answer can only over-keep; a keep costs a shared literal, a wrong drop does not compile or
 * reads an unset field.
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

	/** Simple name -> every spelling of it in a demanding position, with what qualifies it. */
	private final _spelled: Map<String, Array<DemandSpelling>>;

	/** Simple type name -> the member names its declarations in the scope declare. */
	private final _typeMembers: Map<String, Array<String>>;

	private final _callKinds: Array<String>;
	private final _staticInitFunctionNames: Array<String>;

	private function new(
		spelled: Map<String, Array<DemandSpelling>>, typeMembers: Map<String, Array<String>>, callKinds: Array<String>,
		staticInitFunctionNames: Array<String>
	) {
		_spelled = spelled;
		_typeMembers = typeMembers;
		_callKinds = callKinds;
		_staticInitFunctionNames = staticInitFunctionNames;
	}

	/** Whether the initializer `init` holds a call or an allocation, so running it may reach any field of the type. */
	public inline function runsCode(init: QueryNode): Bool {
		return MemberKinds.subtreeContainsAnyKind(init, _callKinds);
	}

	/**
	 * Whether a demanding position may name the constant `name` of the type `typeName`. A spelling qualified by another
	 * type the scope declares, or a bare one inside another type declaring its own `name`, names that type's member; any
	 * other spelling (an unknown qualifier, a value receiver, a module-level read) holds every constant of the name.
	 */
	public function holds(name: String, typeName: Null<String>): Bool {
		final spellings: Null<Array<DemandSpelling>> = _spelled[name];
		if (spellings == null) return false;
		for (spelling in spellings) {
			final held: Bool = switch spelling {
				case Qualified(qualifier):
					qualifier == typeName || !_typeMembers.exists(qualifier);
				case Bare(enclosing):
					enclosing == null || enclosing == typeName || !(_typeMembers[enclosing] ?? []).contains(name);
				case Unqualified: true;
			};
			if (held) return true;
		}
		return false;
	}

	/** Whether `member` is a static-init function holding a call or an allocation: it runs before every initializer. */
	public function staticInitRunsCode(member: QueryNode): Bool {
		return _staticInitFunctionNames.contains(member.name ?? '') && runsCode(member);
	}

	/** Every spelling the demanding positions of the run's whole scope (`scopeFiles`, not only the linted files) hold. */
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
			targetCodeCallNames: shape.execution?.targetCodeCallNames ?? [],
			fieldAccessKind: shape.fieldAccessKind,
			bareNameKinds: [for (k in [shape.identKind, shape.stringInterpIdentKind]) if (k != null) k]
		};
		final out: DemandOut = { spelled: [], typeMembers: [] };
		for (entry in ReflectionScan.scopeFiles(files, plugin)) {
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, entry.source);
			if (tree != null) walk(tree, entry.source, seams, null, out);
		}
		final call: Null<String> = shape.callKind;
		final alloc: Null<String> = shape.newExprKind;
		return new ConstantDemandScan(
			out.spelled, out.typeMembers, [for (kind in [call, alloc]) if (kind != null) kind], staticInitFunctionNames
		);
	}

	/** Record the demanding positions under `node`, inside the type named `enclosing` (null at module level). */
	private static function walk(node: QueryNode, source: String, seams: DemandSeams, enclosing: Null<String>, out: DemandOut): Void {
		final constants: ConstantFieldSeams = seams.constants;
		for (child in node.children) {
			final kind: String = child.kind;
			var inner: Null<String> = enclosing;
			if (constants.containers.contains(kind) && child.name != null) {
				inner = child.name;
				recordMembers(child, constants, out);
			}
			if (constants.members.contains(kind)) {
				final isField: Bool = constants.finalFieldKinds.contains(kind) || constants.mutableFieldKinds.contains(kind);
				if (isField) demand(ConstantFieldScan.initializerOf(child), source, seams, enclosing, out);
				if (seams.staticInitFunctionNames.contains(child.name ?? '') || isConstructor(child, seams))
					spellNames(child, seams, enclosing, out);
			} else if (seams.moduleValueKinds.contains(kind) || seams.paramKinds.contains(kind)) {
				demand(ConstantFieldScan.initializerOf(child), source, seams, enclosing, out);
			} else if (seams.staticLocalKinds.contains(kind)) {
				// The whole declaration: a multi-binding form nests the later initializers in continuation nodes.
				spellNames(child, seams, enclosing, out);
			} else if (isTargetCodeCall(child, seams)) {
				demand(child.children[1], source, seams, enclosing, out);
			}
			walk(child, source, seams, inner, out);
		}
	}

	/** Add the member names `container` declares to its type name's entry: same-named types merge, which only over-keeps. */
	private static function recordMembers(container: QueryNode, constants: ConstantFieldSeams, out: DemandOut): Void {
		final typeName: String = container.name ?? '';
		final members: Array<String> = out.typeMembers[typeName] ?? [];
		for (member in container.children) {
			final name: Null<String> = member.name;
			if (name != null && constants.members.contains(member.kind)) members.push(name);
		}
		out.typeMembers[typeName] = members;
	}

	/** Whether `node` is a call of a target-code name; the name alone answers, so an unrelated `x.code(a)` only over-keeps. */
	private static function isTargetCodeCall(node: QueryNode, seams: DemandSeams): Bool {
		return node.kind == seams.callKind && node.children.length > 1 && seams.targetCodeCallNames.contains(node.children[0].name ?? '');
	}

	/** Record the names `value` spells. A plain string literal is no read, whatever its content happens to be. */
	private static function demand(
		value: Null<QueryNode>, source: String, seams: DemandSeams, enclosing: Null<String>, out: DemandOut
	): Void {
		if (value != null && !ConstantFieldScan.isPlainStringLiteral(value, source, seams.constants))
			spellNames(value, seams, enclosing, out);
	}

	/**
	 * Record every name in `node`'s subtree with what qualifies it: a qualified path and an interpolated segment project
	 * their parts as nodes. A named node that is neither a bare name nor a field access holds every constant of its name.
	 */
	private static function spellNames(node: QueryNode, seams: DemandSeams, enclosing: Null<String>, out: DemandOut): Void {
		final name: Null<String> = node.name;
		if (name != null) {
			final spellings: Array<DemandSpelling> = out.spelled[name] ?? [];
			spellings.push(spellingOf(node, seams, enclosing));
			out.spelled[name] = spellings;
		}
		for (child in node.children) spellNames(child, seams, enclosing, out);
	}

	/** What qualifies the named `node`: the receiver's last segment for a field access, the enclosing type for a bare name. */
	private static function spellingOf(node: QueryNode, seams: DemandSeams, enclosing: Null<String>): DemandSpelling {
		if (node.kind != seams.fieldAccessKind) return seams.bareNameKinds.contains(node.kind) ? Bare(enclosing) : Unqualified;
		final receiver: Null<String> = node.children.length > 0 ? node.children[0].name : null;
		return receiver == null ? Unqualified : Qualified(receiver);
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
	final fieldAccessKind: Null<String>;
	final bareNameKinds: Array<String>;
};

/** What `ConstantDemandScan.walk` collects over the run's scope. */
private typedef DemandOut = { final spelled: Map<String, Array<DemandSpelling>>; final typeMembers: Map<String, Array<String>>; };

/** What qualifies one spelling of a name in a demanding position. */
private enum DemandSpelling {

	/** `Q.name`: `Q` the receiver's last segment. */
	Qualified(qualifier: String);

	/** A bare `name` inside the type named `enclosing`, null at module level. */
	Bare(enclosing: Null<String>);

	/** Any other named node, which may name any constant of its name. */
	Unqualified;

}
