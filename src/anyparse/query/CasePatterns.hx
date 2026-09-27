package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;

using Lambda;

/**
 * The ONE definition of which names a `case` pattern BINDS. The scope resolver (`Refs`), the
 * case-arm lint rules (`CasePatternScan`) and every consumer that has to tell a capture from a
 * reference ask this class, so no two of them can disagree about the same pattern.
 *
 * A pattern position is read as a WHITELIST: an identifier, a `var x` capture, an `=`-capture's
 * left slot, a constructor call's ARGUMENTS (never its callee), an array element, a structure
 * field's value, a parenthesised sub-pattern, an extractor's RIGHT side (its left side is an
 * expression evaluated on the subject, so identifiers there are reads) and the constant leaves — a
 * dotted path and the literals. Any other shape makes the scan UNMODELLED, and every bare name
 * inside it is `Undecided`: an unmodelled shape may bind a name this scan would otherwise report
 * as a reference.
 *
 * A bare identifier CAPTURES unless its spelling rules that out (`isCaptureSpelling`) or a
 * declaration the caller knows of may make it a pattern CONSTANT (`constantNames`): Haxe matches a
 * lowercase `enum abstract` value, a lowercase enum constructor and a `static inline` field as a
 * value, and an ordinary local, parameter or field never — `case closeAction:` over a field of that
 * name matches every subject.
 */
@:nullSafety(Strict)
final class CasePatterns {

	/** An `=`-capture and an extractor both have exactly two children. */
	private static inline final PAIR_CHILD_COUNT: Int = 2;

	/** The last segment of a wildcard import path. */
	private static inline final WILDCARD_SEGMENT: String = '*';

	/**
	 * The LEADING run of `branch`'s pattern children — the `case A, B:` alternatives. A top-level
	 * `var x` capture projects as its own kind rather than through the plain wrapper, so both count.
	 */
	public static function patternRun(branch: QueryNode, shape: RefShape): Array<QueryNode> {
		final plainKind: Null<String> = shape.plainCasePatternKind;
		final binderKinds: Array<String> = shape.casePatternBinderKinds ?? [];
		final out: Array<QueryNode> = [];
		for (child in branch.children) {
			if (child.kind != plainKind && !binderKinds.contains(child.kind)) break;
			out.push(child);
		}
		return out;
	}

	/**
	 * Whether a bare pattern identifier spelled `name` may bind at all: not the wildcard, and not a
	 * name the grammar's spelling reserves for a constructor or a constant
	 * (`RefShape.upperInitialNeverCaptures`).
	 */
	public static function isCaptureSpelling(name: String, shape: RefShape): Bool {
		return name.length > 0 && name != shape.wildcardPatternName
			&& !(shape.upperInitialNeverCaptures == true && SourceText.isUpperInitial(name));
	}

	/**
	 * Whether a pattern name the scan reports as a `Capture` is PROVEN to capture - the positive rule every
	 * consumer that acts on a capture reads. A name bound by syntax (`var x`, `x = p`) always is. A BARE name
	 * is only when no import of the file may bring a constant of that name in (`importsMayBind`) and the
	 * type it is matched against is proven to carry no constant: Haxe resolves a bare lowercase pattern name
	 * against the enum constructors and `enum abstract` values of that EXPECTED type, and against imported
	 * `static inline` fields, before it falls back to a capture - and ahead of any local of the same name.
	 * The expected type comes from the `site`: the subjects for the whole pattern, a dynamic subjects for
	 * an array element or structure field, an in-file enum constructors parameter for its argument.
	 * Anything else is unproven.
	 */
	public static function isDecidedCapture(ident: PatternIdent, subject: SubjectProof, root: QueryNode, shape: RefShape): Bool {
		if (ident.role != Capture) return false;
		if (ident.explicit) return true;
		if (importsMayBind(root, shape, ident.name)) return false;
		return switch ident.site {
			case Whole: subject.typed;
			case Structural: subject.isDynamic;
			case Slot(callee, index): ctorArgRulesOutConstants(root, shape, callee, index);
			case Opaque: false;
		};
	}

	/**
	 * Whether the pattern name carried by `node` in `arm` (of `switchNode`) is a PROVEN capture — the
	 * `isDecidedCapture` answer for a caller that holds a node rather than a scan. `resolve` answers the
	 * declaration a subject identifier binds to. False when `node` is no capture of the arm at all.
	 */
	public static function provesCaptureAt(
		arm: QueryNode, switchNode: Null<QueryNode>, root: QueryNode, shape: RefShape, node: QueryNode,
		resolve: QueryNode -> Null<QueryNode>
	): Bool {
		final ident: Null<PatternIdent> = scan(arm, shape, []).idents.find(i -> i.node == node);
		return ident != null && isDecidedCapture(ident, subjectProof(switchNode, root, shape, resolve), root, shape);
	}

	/**
	 * What the type of `switchNode`s subject is proven to be: `typed` when it carries no pattern constant (a
	 * literal of a built-in type, or an identifier whose declaration `resolve` answers with a written type
	 * `typeRulesOutConstants` accepts), `isDynamic` when it is a dynamic type, whose elements and fields are
	 * dynamic as well. A field of a dynamic identifier is both. Anything else (a call, another field, an
	 * unannotated local, a type from another file) proves nothing.
	 */
	public static function subjectProof(
		switchNode: Null<QueryNode>, root: QueryNode, shape: RefShape, resolve: QueryNode -> Null<QueryNode>
	): SubjectProof {
		final none: SubjectProof = { typed: false, isDynamic: false };
		if (switchNode == null || switchNode.children.length == 0) return none;
		var subject: QueryNode = switchNode.children[0];
		while (subject.kind == shape.parenKind && subject.children.length == 1) subject = subject.children[0];
		if ((shape.literalTypeNames ?? []).exists(subject.kind)) return { typed: true, isDynamic: false };
		var receiver: QueryNode = subject;
		while (receiver.kind == shape.fieldAccessKind && receiver.children.length == 1) receiver = receiver.children[0];
		if (receiver.kind != shape.identKind) return none;
		final decl: Null<QueryNode> = resolve(receiver);
		if (decl == null) return none;
		final isDynamic: Bool = isDynamicType(decl.type, shape);
		// A field read off a dynamic value is dynamic too; any other field has a type this file does not see.
		if (receiver != subject) return isDynamic ? { typed: true, isDynamic: true } : none;
		return { typed: typeRulesOutConstants(decl.type, root, shape), isDynamic: isDynamic };
	}

	/**
	 * Whether a written type is proven to carry no pattern constant: a structure or function type, a
	 * built-in value type, the grammar's array type, a dynamic type, a nullable wrapper around one of
	 * these, or a class, interface, enum or `enum abstract` DECLARED in `root` (every value of the last
	 * two is a `constantNames` member, which a capture name never is). A typedef or plain abstract may
	 * stand for anything, and a type from another file is unknown.
	 */
	public static function typeRulesOutConstants(type: Null<QueryNode>, root: QueryNode, shape: RefShape): Bool {
		if (type == null) return false;
		final name: Null<String> = type.name;
		if (name == null) return true;
		final wrappers: Array<String> = shape.nullableWrapperTypeNames ?? [];
		if (wrappers.contains(name))
			return type.children.length == 0 || (type.children.length == 1 && typeRulesOutConstants(type.children[0], root, shape));
		final literals: Map<String, String> = shape.literalTypeNames ?? [];
		if ((shape.nonNullableTypeNames ?? []).contains(name) || (shape.arrayTypeNames ?? []).contains(name)) return true;
		for (builtin in literals) if (builtin == name) return true;
		return declaresProvenType(root, shape, name);
	}

	/** Whether a written type is a dynamic one — a nullable-wrapper name carrying no type argument. */
	public static function isDynamicType(type: Null<QueryNode>, shape: RefShape): Bool {
		final name: Null<String> = type?.name;
		return type != null && name != null && type.children.length == 0 && (shape.nullableWrapperTypeNames ?? []).contains(name);
	}

	/**
	 * Whether argument `index` of the constructor `callee` is proven to carry no pattern constant: `root`
	 * declares exactly one closed constructor type with a constructor of that name, and that constructor
	 * declares the parameter with a written type `typeRulesOutConstants` accepts.
	 */
	public static function ctorArgRulesOutConstants(root: QueryNode, shape: RefShape, callee: String, index: Int): Bool {
		final aliases: Array<String> = shape.aliasingDeclKinds ?? [];
		final enumKinds: Array<String> = [
			for (kind in shape.bareConstructorTypeKinds ?? []) if (!aliases.contains(kind)) kind
		];
		final paramKinds: Array<String> = shape.paramKinds ?? [];
		final ctors: Array<QueryNode> = [];
		function walk(node: QueryNode): Void {
			if (enumKinds.contains(node.kind)) for (ctor in node.children) if (ctor.name == callee) ctors.push(ctor);
			for (child in node.children) walk(child);
		}
		walk(root);
		if (ctors.length != 1) return false;
		final params: Array<QueryNode> = [for (c in ctors[0].children) if (paramKinds.contains(c.kind)) c];
		return index < params.length && typeRulesOutConstants(params[index].type, root, shape);
	}

	/**
	 * Whether an import of `root` may bring a pattern constant named `name` in unqualified: an import
	 * (`modulePathKinds`, the package declaration aside) whose last segment is `name`, an alias of that name,
	 * or a wildcard over a TYPEs statics (a module path ending in `*` after an upper-initial segment). A
	 * grammar that declares no module path kinds answers true - nothing can then be ruled out.
	 */
	public static function importsMayBind(root: QueryNode, shape: RefShape, name: String): Bool {
		final modulePaths: Null<Array<String>> = shape.modulePathKinds;
		if (modulePaths == null) return true;
		final aliases: Array<String> = shape.importAliasKinds ?? [];
		for (node in root.children) {
			final path: Null<String> = node.name;
			if (path == null) continue;
			final segments: Array<String> = path.split('.');
			final last: String = segments[segments.length - 1];
			if (aliases.contains(node.kind) && path == name) return true;
			if (modulePaths.contains(node.kind) && node.kind != shape.packageDeclKind && last == name) return true;
			if (last == WILDCARD_SEGMENT && segments.length >= 2 && SourceText.isUpperInitial(segments[segments.length - 2])) return true;
		}
		return false;
	}

	/**
	 * Every name in `branch`'s pattern run a capture may introduce, in document order, and whether
	 * every pattern stayed inside the whitelist. A bare identifier named in `constants` is
	 * `Undecided` rather than a `Capture`; so is every bare name inside an unmodelled shape.
	 */
	public static function scan(branch: QueryNode, shape: RefShape, constants: Array<String>): PatternScan {
		final state: ScanState = new ScanState(shape, constants);
		final binderKinds: Array<String> = shape.casePatternBinderKinds ?? [];
		for (pattern in patternRun(branch, shape)) {
			if (binderKinds.contains(pattern.kind))
				scanNode(state, pattern, true, Whole)
			else if (pattern.children.length == 1)
				scanNode(state, pattern.children[0], true, Whole)
			else
				state.unmodelled(pattern);
		}
		return { idents: state.idents, modelled: state.modelled };
	}

	/**
	 * Every name declared across `trees` that the language may resolve UNQUALIFIED in a pattern position as a
	 * constant - the names of `constantDeclarations`, each once.
	 */
	public static function constantNames(trees: Array<QueryNode>, shape: RefShape): Array<String> {
		final out: Array<String> = [];
		for (decl in constantDeclarations(trees, shape)) {
			final name: Null<String> = decl.name;
			if (name != null && !out.contains(name)) out.push(name);
		}
		return out;
	}

	/**
	 * Every declaration across `trees` that the language may resolve UNQUALIFIED in a pattern position
	 * as a constant: a member of a closed constructor type (`bareConstructorTypeKinds`), a member of any
	 * abstract or alias (`aliasingDeclKinds` - which reaches a legacy `@:enum abstract`, projected as a
	 * plain abstract), and any `static` member. Over-inclusive on purpose - a `static var` captures in
	 * Haxe, only a `static inline` one compares - because a declaration here is only ever read as "may
	 * be a constant". Names spelled so that they never capture are left out: the spelling rule decides
	 * them first.
	 *
	 * Modifiers project as SIBLING nodes preceding their member, so a pending `static` run is carried
	 * across the nameless modifier nodes and consumed by the next named child.
	 */
	public static function constantDeclarations(trees: Array<QueryNode>, shape: RefShape): Array<QueryNode> {
		final hostKinds: Array<String> = (shape.bareConstructorTypeKinds ?? []).concat(shape.aliasingDeclKinds ?? []);
		final staticKind: Null<String> = shape.staticModifierKind;
		final out: Array<QueryNode> = [];
		function walk(node: QueryNode): Void {
			final allMembers: Bool = hostKinds.contains(node.kind);
			var pendingStatic: Bool = false;
			for (member in node.children) {
				if (member.kind == staticKind) {
					pendingStatic = true;
					continue;
				}
				final name: Null<String> = member.name;
				if (name == null) continue;
				if ((allMembers || pendingStatic) && isCaptureSpelling(name, shape)) out.push(member);
				pendingStatic = false;
			}
			for (child in node.children) walk(child);
		}
		for (tree in trees) walk(tree);
		return out;
	}

	/**
	 * Whether `node` is a constructor-extraction pattern whose callee is NAMED — a bare identifier or
	 * the dotted path of a qualified constructor, the only two callee spellings a pattern may carry.
	 */
	public static function isNamedCallee(node: QueryNode, shape: RefShape): Bool {
		if (node.children.length == 0) return false;
		final callee: QueryNode = node.children[0];
		return callee.kind == shape.identKind || callee.kind == shape.fieldAccessKind;
	}

	/**
	 * Walk one pattern node; `whole` marks the node that IS the entire pattern, `site` what its expected
	 * type is known from (`PatternSite`).
	 */
	private static function scanNode(state: ScanState, node: QueryNode, whole: Bool, site: PatternSite): Void {
		final shape: RefShape = state.shape;
		final kind: String = node.kind;
		if (node.span == null)
			state.unmodelled(node)
		else if (kind == shape.identKind)
			scanIdent(state, node, whole, site)
		else if ((shape.casePatternBinderKinds ?? []).contains(kind))
			scanBinder(state, node, whole, site)
		else if (kind == shape.assignKind)
			scanAssign(state, node, site)
		else if (kind == shape.callKind)
			scanCall(state, node)
		else if (!scanComposite(state, node, whole, site) && !constantLeafKinds(shape).contains(kind))
			state.unmodelled(node);
	}

	/** A constructor-extraction pattern: a NAMED callee (a read) over scanned arguments. */
	private static function scanCall(state: ScanState, node: QueryNode): Void {
		if (isNamedCallee(node, state.shape)) {
			final callee: Null<String> = node.children[0].name;
			for (i in 1...node.children.length) scanNode(state, node.children[i], false, callee == null ? Opaque : Slot(callee, i - 1));
		} else
			state.unmodelled(node);
	}

	/**
	 * Scan `node` when it is a pattern that only WRAPS sub-patterns — an array, a structure, a
	 * parenthesised or negated pattern, an extractor's right side — and answer whether it was one.
	 */
	private static function scanComposite(state: ScanState, node: QueryNode, whole: Bool, site: PatternSite): Bool {
		final shape: RefShape = state.shape;
		final kind: String = node.kind;
		final element: PatternSite = site == Whole || site == Structural ? Structural : Opaque;
		if (kind == shape.arrayLiteralKind)
			for (child in node.children) scanNode(state, child, false, element)
		else if (kind == shape.objectLiteralKind)
			for (field in node.children) {
				if (field.kind == shape.objectFieldKind && field.children.length == 1)
					scanNode(state, field.children[0], false, element)
				else
					state.unmodelled(field);
			}
		else if (kind == shape.parenKind || kind == shape.negationKind) {
			if (node.children.length == 1)
				scanNode(state, node.children[0], whole && kind == shape.parenKind, kind == shape.parenKind ? site : Opaque)
			else
				state.unmodelled(node);
		} else if (kind == shape.orPatternKind) {
			if (node.children.length == PAIR_CHILD_COUNT)
				for (side in node.children) scanNode(state, side, false, site)
			else
				state.unmodelled(node);
		} else if ((shape.casePatternExtractorKinds ?? []).contains(kind)) {
			if (node.children.length == PAIR_CHILD_COUNT)
				scanNode(state, node.children[1], false, Opaque)
			else
				state.unmodelled(node);
		} else
			return false;
		return true;
	}

	/** A bare identifier: the wildcard and a reserved spelling bind nothing, a known constant name is undecided. */
	private static function scanIdent(state: ScanState, node: QueryNode, whole: Bool, site: PatternSite): Void {
		final name: Null<String> = node.name;
		if (name == null || name.length == 0) {
			state.unmodelled(node);
			return;
		}
		if (isCaptureSpelling(name, state.shape))
			state.push(node, name, state.constants.contains(name) ? Undecided : Capture, false, whole, site, null);
	}

	/** A grammar-declared binder node (`case var x:`) — a leaf carrying the bound name. */
	private static function scanBinder(state: ScanState, node: QueryNode, whole: Bool, site: PatternSite): Void {
		final name: Null<String> = node.name;
		if (name == null || node.children.length != 0)
			state.unmodelled(node)
		else
			state.push(node, name, Capture, true, whole, site, null);
	}

	/** A `name = subpattern` capture: the name binds by syntax, the subpattern is scanned on its own. */
	private static function scanAssign(state: ScanState, node: QueryNode, site: PatternSite): Void {
		if (node.children.length != PAIR_CHILD_COUNT) {
			state.unmodelled(node);
			return;
		}
		final lhs: QueryNode = node.children[0];
		final rhs: QueryNode = node.children[1];
		final name: Null<String> = lhs.name;
		if (lhs.kind != state.shape.identKind || name == null || lhs.span == null || rhs.span == null) {
			state.unmodelled(node);
			return;
		}
		if (name != state.shape.wildcardPatternName) state.push(lhs, name, Capture, true, false, site, rhs);
		scanNode(state, rhs, false, site);
	}

	/** The pattern leaves that bind nothing and hold no sub-pattern: a dotted path and the literals. */
	public static function constantLeafKinds(shape: RefShape): Array<String> {
		final leaves: Array<String> = [];
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind != null) leaves.push(fieldAccessKind);
		for (kind in shape.stringLiteralKinds ?? []) leaves.push(kind);
		for (kind in shape.numericLiteralKinds ?? []) leaves.push(kind);
		final boolKind: Null<String> = shape.boolLitKind;
		if (boolKind != null) leaves.push(boolKind);
		final nullKind: Null<String> = shape.nullLiteralKind;
		if (nullKind != null) leaves.push(nullKind);
		return leaves;
	}

	/**
	 * Whether `root` declares a type named `name` whose kind cannot stand for another type: any
	 * `typeDeclKinds` or `bareConstructorTypeKinds` declaration except an alias (`aliasingDeclKinds`)
	 * that is not itself a closed constructor type — a typedef or a plain abstract.
	 */
	private static function declaresProvenType(root: QueryNode, shape: RefShape, name: String): Bool {
		final closed: Array<String> = shape.bareConstructorTypeKinds ?? [];
		final aliases: Array<String> = shape.aliasingDeclKinds ?? [];
		final kinds: Array<String> = (shape.typeDeclKinds ?? []).concat(closed);
		function walk(node: QueryNode): Bool {
			if (node.name == name && kinds.contains(node.kind) && (closed.contains(node.kind) || !aliases.contains(node.kind))) return true;
			return node.children.exists(walk);
		}
		return walk(root);
	}

}

/** What a name in a pattern IS, as far as the caller's knowledge of declarations reaches. */
enum abstract PatternRole(Int) {

	/** Binds a new name for the arm — by syntax (`var x`, `x = p`) or by the bare-name rule. */
	final Capture = 0;

	/** A bare name a constant declaration may claim, or one inside an unmodelled shape. */
	final Undecided = 1;

}

/** Where a pattern name's EXPECTED type comes from — what a proof that it captures has to read. */
enum PatternSite {

	/** The whole pattern (through parentheses or an alternative): the switch subject's type. */
	Whole;

	/** An array element or structure field reached from the whole pattern through such shapes only. */
	Structural;

	/** Argument `index` of the constructor pattern named `callee`. */
	Slot(callee: String, index: Int);

	/** Anywhere else — an extractor's right side, a negation, an unmodelled shape. */
	Opaque;

}

/** What `CasePatterns.subjectProof` proved about a switch subject's type. */
typedef SubjectProof = {

	/** The type carries no pattern constant. */
	final typed: Bool;

	/** The type is dynamic, and so is every element and field of it. */
	final isDynamic: Bool;
};

/** One name a pattern may bind. */
typedef PatternIdent = {

	/** The node that carries the name — a bare identifier, a binder node or an `=`-capture's left slot. */
	final node: QueryNode;
	final name: String;
	final role: PatternRole;

	/** Whether the name binds by SYNTAX (`var x`, `x = p`) rather than by the bare-name rule. */
	final explicit: Bool;

	/** Whether the binder IS the whole pattern — a catch-all. */
	final whole: Bool;

	/** What the name's expected type is known from. */
	final site: PatternSite;

	/** The sub-pattern of an `x = p` capture, whose start ends the text that unbinds `x`; null otherwise. */
	final assigned: Null<QueryNode>;
};

/** The result of `CasePatterns.scan`. */
typedef PatternScan = {
	final idents: Array<PatternIdent>;

	/** Whether every pattern stayed inside the whitelist; when false, a name the scan missed may still bind. */
	final modelled: Bool;
};

/** The mutable accumulator of one `CasePatterns.scan`. */
@:nullSafety(Strict)
private final class ScanState {

	public final idents: Array<PatternIdent> = [];
	public final shape: RefShape;
	public final constants: Array<String>;
	public var modelled(default, null): Bool = true;

	public function new(shape: RefShape, constants: Array<String>) {
		this.shape = shape;
		this.constants = constants;
	}

	public function push(
		node: QueryNode, name: String, role: PatternRole, explicit: Bool, whole: Bool, site: PatternSite, assigned: Null<QueryNode>
	): Void {
		idents.push({
			node: node,
			name: name,
			role: role,
			explicit: explicit,
			whole: whole,
			site: site,
			assigned: assigned
		});
	}

	/**
	 * Record a shape outside the whitelist: every bare name inside it may bind, so each is `Undecided`.
	 * A declaration node the resolver already binds (a nested `var x`) carries no bare name to add.
	 */
	public function unmodelled(node: QueryNode): Void {
		modelled = false;
		final declKinds: Array<String> = shape.declHostKinds;
		function walk(n: QueryNode): Void {
			if (declKinds.contains(n.kind)) return;
			final name: Null<String> = n.name;
			if (n.kind == shape.identKind && name != null && CasePatterns.isCaptureSpelling(name, shape))
				push(n, name, Undecided, false, false, Opaque, null);
			for (child in n.children) walk(child);
		}
		walk(node);
	}

}
