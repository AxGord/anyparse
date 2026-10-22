package anyparse.query;

import anyparse.check.ConstantFieldScan;
import anyparse.query.Address.AddressSpec;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.ModulePath;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;
import haxe.ds.Either;

using Lambda;

/**
 * `extract-constant` ADDRESSED mode — move ONE expression into a `static final` of a type that may live in
 * another module or package, and leave a qualified reference behind:
 *
 *     final timeout:Int = 5 * 60;                    // in a method of pkg.a.Worker
 *
 * becomes, with `--select '… >> FinalStmt:timeout' --name TIMEOUT --into src/pkg/b/Limits.hx`,
 *
 *     final timeout:Int = Limits.TIMEOUT;            // + import pkg.b.Limits;
 *     public static inline final TIMEOUT:Int = 5 * 60; // in pkg.b.Limits — inline only for a scalar literal
 *
 * The address names an expression, or a local / field DECLARATION, whose initializer is then the expression
 * (its declared type becomes the constant's). The literal modes of `ExtractConstant` stay as they were; this is
 * the one that knows WHICH occurrence, and so can move any constant, not only a string.
 *
 * ## What moves — a positive whitelist
 *
 * A constant is the value every reader shares. So the expression must read nothing (`firstContextRead`: no
 * local, no `this`, no member, no interpolated name) and be a compile-time constant by the shared proof the
 * constant-field checks use (`ConstantFieldScan.isConstantExpression`: a literal, an operator or parentheses
 * over constants). An array or object literal of such constants is a FRESH value at every evaluation while a
 * `static final` is ONE instance, so it moves only under `--shared`, the caller's assertion that no reader
 * mutates it — the same kind of operator assertion `resolve-define --undefined` is. Everything else is refused
 * with its reason, and so are three positions whose meaning a reference would change: a metadata argument, a
 * `case` pattern, and a parameter default (which must fold, so only an `inline` constant may replace it).
 *
 * `inline` is added where `inline-constant` would add it (`ConstantFieldScan.isConstantScalarInitializer`), so
 * the two never disagree about what folds.
 *
 * ## Where it goes
 *
 * The receiving type must be able to hold a static (a class); the constant is spliced into its constants rank
 * by `ExtractConstant.buildModuleSource`, which also refuses a name the type already has and creates a missing
 * module. The reference is `Type.NAME`; the source gains `import pkg.Mod;` (`pkg.Mod.Sub` for a sub-module type)
 * unless that bare name resolves on its own (`RefactorSupport.bareNameResolves`, and no wildcard import that
 * could shadow it). Refused when the bare name would bind something else at the use: a local of that name, a
 * type the source declares, or an import of a different path. A declared type is carried only when every type
 * it names is visible from any module (a std top-level type, or a dotted path); otherwise `--annotate` spells it.
 */
@:nullSafety(Strict)
final class ExtractConstantTo {

	/** The module the std top-level value types live in (`Int`, `Float`, `Bool`, `Null`, `Dynamic`…). */
	private static inline final STD_TYPES_MODULE: String = 'StdTypes';

	/**
	 * Move the addressed expression of `request` into a `static final` named `request.name`, as described above.
	 * Returns the rewritten source, the destination module's final text (null when it IS the source) and the
	 * advisories to print, or an `Err` naming why nothing moves.
	 */
	public static function extractTo(request: ExtractToRequest, plugin: GrammarPlugin): ExtractToResult {
		final name: String = request.name;
		if (!SourceText.isIdentifier(name)) return Err('"$name" is not a valid identifier for a constant name');
		final source: String = request.source;
		final tree: QueryNode = switch ParseGate.parse(plugin, source, request.sourceFile) {
			case Unparsed(message): return Err(message);
			case Parsed(parsed): parsed;
		};
		final resolved: Null<QueryNode> = switch Address.resolve(tree, source, plugin, request.address) {
			case Ok(_, node): node;
			case Err(message): return Err(message);
		};
		if (resolved == null) return Err('the address resolves to no node');
		final shape: RefShape = plugin.refShape();
		final decl: Null<QueryNode> = isValueDecl(resolved, shape) ? resolved : null;
		final init: Null<QueryNode> = decl == null ? resolved : initializerOf(decl, shape);
		final initSpan: Null<Span> = init?.span;
		if (init == null || initSpan == null) return Err('the addressed declaration has no initializer to move');
		final path: Array<QueryNode> = TreePath.pathTo(tree, init) ?? [init];
		final seams: Null<ConstantFieldSeams> = ConstantFieldScan.seams(plugin);
		if (seams == null) return Err('the grammar describes no compile-time constants');
		final inlined: Bool = switch movability(init, path, source, plugin, seams, request.shared) {
			case Left(message): return Err(message);
			case Right(inlineIt): inlineIt;
		};
		final typeText: Null<String> = switch constantType(request, decl, init, source, plugin) {
			case Left(message): return Err(message);
			case Right(text): text;
		};
		final advisories: Array<String> = [];
		if (typeText == null) advisories.push('the constant\'s type is left to the compiler\'s inference — --annotate <Type> spells it');
		if (!ConstantFieldScan.isConstantExpression(init, source, seams, _ -> false))
			advisories.push('the moved literal is now ONE shared instance (--shared)');
		final value: String = source.substring(initSpan.from, initSpan.to);
		final member: ConstantMember = {
			name: name,
			typeText: typeText,
			value: value,
			inlined: inlined
		};
		final dest: Null<ExtractToModule> = request.dest;
		return dest == null
			? intoSameFile(request, tree, path, initSpan, member, plugin, advisories)
			: intoOtherModule(request, dest, tree, initSpan, member, plugin, advisories);
	}

	/**
	 * The first node under `node` (itself included, pre-order) that READS a name — an identifier, `this` / `super`
	 * included, or a name interpolated into a string — or null when it reads none. What a value has to be free of
	 * before it may leave the scope it was written in: a constant moved to another type, an element moved to another
	 * array. A type named by `new` or an annotation is not a read (see `firstUnseenType`).
	 */
	public static function firstContextRead(node: QueryNode, shape: RefShape): Null<QueryNode> {
		if (node.kind == shape.identKind || node.kind == shape.stringInterpIdentKind) return node;
		for (child in node.children) {
			final hit: Null<QueryNode> = firstContextRead(child, shape);
			if (hit != null) return hit;
		}
		return null;
	}

	/**
	 * The first type name under `node` (its children and its type annotations, recursively) that a module other
	 * than the one it is written in may not see, or null when there is none. Visible everywhere, by a positive
	 * list: a dotted path (it names its module) and a std top-level type (`isStdTopLevelType`). Everything else —
	 * a project type, a type parameter, a sub-module type — answers its name, since the destination's imports
	 * are not read here.
	 */
	public static function firstUnseenType(node: QueryNode, plugin: GrammarPlugin): Null<String> {
		final shape: RefShape = plugin.refShape();
		final name: Null<String> = node.name;
		final namesType: Bool = node.kind == shape.newExprKind || (shape.typeAnnotationKinds ?? []).contains(node.kind);
		if (namesType && name != null && !name.contains('.') && !isStdTopLevelType(plugin, name)) return name;
		final type: Null<QueryNode> = node.type;
		final fromType: Null<String> = type == null ? null : firstUnseenType(type, plugin);
		if (fromType != null) return fromType;
		for (child in node.children) {
			final hit: Null<String> = firstUnseenType(child, plugin);
			if (hit != null) return hit;
		}
		return null;
	}

	/**
	 * Whether `name` is a std top-level type, visible bare from every module: one the std core declares as a
	 * root-package module (`Array`, `String`, `Math`…) or one its `StdTypes` module declares (`Int`, `Bool`,
	 * `Null`…). False when no std was discovered — unknown is no proof.
	 */
	public static function isStdTopLevelType(plugin: GrammarPlugin, name: String): Bool {
		if (StdTypes.declaresModule('', name) == true) return true;
		final core: Null<Array<TypeDeclInfo>> = StdTypes.moduleTypes(plugin, STD_TYPES_MODULE);
		return core != null && core.exists(t -> t.name == name);
	}

	/** Whether `node` declares a local or a data field — an address whose INITIALIZER is the expression. */
	private static inline function isValueDecl(node: QueryNode, shape: RefShape): Bool {
		return (shape.localDeclKinds ?? []).contains(node.kind) || MemberKinds.isDataFieldKind(node.kind);
	}

	/** The `static final` text of `member`, `visibility` first. */
	private static inline function memberText(member: ConstantMember, visibility: String): String {
		final annotation: String = member.typeText == null ? '' : ':${member.typeText}';
		final modifiers: String = member.inlined ? 'static inline final' : 'static final';
		return '$visibility $modifiers ${member.name}$annotation = ${member.value};';
	}

	/** The last segment of a dotted path. */
	private static inline function lastSegment(path: String): String {
		return path.substr(path.lastIndexOf('.') + 1);
	}

	/** A declaration's initializer: its last child, when that child is not part of its type annotation. */
	private static function initializerOf(decl: QueryNode, shape: RefShape): Null<QueryNode> {
		final last: Null<QueryNode> = decl.children.length == 0 ? null : decl.children[decl.children.length - 1];
		return last == null || (shape.typeAnnotationKinds ?? []).contains(last.kind) ? null : last;
	}

	/**
	 * Whether `init` (at `path`) may move, as `Right(inline)`, or `Left` naming why not — the position refusals,
	 * a context read, a non-constant, an unshared aggregate, a parameter default that would not fold.
	 */
	private static function movability(
		init: QueryNode, path: Array<QueryNode>, source: String, plugin: GrammarPlugin, seams: ConstantFieldSeams, shared: Bool
	): Either<String, Bool> {
		final shape: RefShape = plugin.refShape();
		final position: Null<String> = positionRefusal(path, shape);
		if (position != null) return Left(position);
		final read: Null<QueryNode> = firstContextRead(init, shape);
		if (read != null)
			return Left('the expression reads `${read.name ?? read.kind}` — a constant must not read a local, `this` or a member');
		final scalar: Bool = ConstantFieldScan.isConstantExpression(init, source, seams, _ -> false);
		if (!scalar && !isConstantAggregate(init, source, seams, shape))
			return Left(
				'the ${init.kind} is not a compile-time constant — a literal, an operator or parentheses over literals, '
				+ 'or (with --shared) an array / object literal of them moves'
			);
		if (!scalar && !shared)
			return Left(
				'an array / object literal is a FRESH value at every evaluation and a static final ONE shared instance — '
				+ 'pass --shared when no reader mutates it'
			);
		final inlined: Bool = scalar && ConstantFieldScan.isConstantScalarInitializer(init, plugin);
		final inParam: Bool = path.exists(n -> (shape.paramKinds ?? []).contains(n.kind));
		return inParam && !inlined
			? Left('a parameter default must fold at compile time, and only a scalar literal moves into an `inline` constant')
			: Right(inlined);
	}

	/** Why the expression at the end of `path` may not become a reference where it sits, or null. */
	private static function positionRefusal(path: Array<QueryNode>, shape: RefShape): Null<String> {
		for (i in 0...path.length - 1) {
			final node: QueryNode = path[i];
			if (MemberKinds.META_KINDS.contains(node.kind)) return 'the expression is a metadata argument, which must stay a literal';
			final pattern: Bool = node.kind == shape.plainCasePatternKind
				|| (node.kind == shape.caseBranchKind && node.children.length > 0 && path[i + 1] == node.children[0]);
			if (pattern)
				return 'the expression is a case pattern — a reference there is matched as a capture or a constant of another kind';
		}
		return null;
	}

	/** Whether `node` is an array / object literal whose every element is a constant expression or such a literal. */
	private static function isConstantAggregate(node: QueryNode, source: String, seams: ConstantFieldSeams, shape: RefShape): Bool {
		final constant: QueryNode -> Bool = n ->
			ConstantFieldScan.isConstantExpression(n, source, seams, _ -> false) || isConstantAggregate(n, source, seams, shape);
		return node.kind == shape.arrayLiteralKind
			? node.children.foreach(constant)
			: node.kind == shape.objectLiteralKind
				&& node.children.foreach(field -> field.children.length == 1 && constant(field.children[0]));
	}

	/**
	 * The constant's type annotation: `--annotate`, else the declaration's own annotation (refused across modules
	 * when it names a type the destination may not see), else a literal's type, else null (left to inference).
	 */
	private static function constantType(
		request: ExtractToRequest, decl: Null<QueryNode>, init: QueryNode, source: String, plugin: GrammarPlugin
	): Either<String, Null<String>> {
		final annotate: Null<String> = request.annotate;
		if (annotate != null) return Right(annotate);
		final declType: Null<QueryNode> = decl?.type;
		final typeSpan: Null<Span> = declType?.span;
		if (declType != null && typeSpan != null) {
			final unseen: Null<String> = request.dest == null ? null : firstUnseenType(declType, plugin);
			return unseen == null
				? Right(source.substring(typeSpan.from, typeSpan.to))
				: Left('the declared type names `$unseen`, which the destination module may not see — spell it with --annotate');
		}
		final shape: RefShape = plugin.refShape();
		var value: QueryNode = init;
		while ((value.kind == shape.parenKind || value.kind == shape.negationKind) && value.children.length == 1) value = value.children[0];
		return Right((shape.literalTypeNames ?? [])[value.kind]);
	}

	/** The constant goes into `request.destType`, declared in the source file itself. */
	private static function intoSameFile(
		request: ExtractToRequest, tree: QueryNode, path: Array<QueryNode>, initSpan: Span, member: ConstantMember, plugin: GrammarPlugin,
		advisories: Array<String>
	): ExtractToResult {
		final destType: Null<String> = request.destType;
		if (destType == null) return Err('name the receiving type with --to <Type>, or its module with --into <file>');
		final host: Null<String> = hostRefusal(RefactorSupport.uniqueTypeDeclNamed(tree, destType), destType, plugin.refShape());
		if (host != null) return Err(host);
		final shadow: Null<String> = localShadow(tree, initSpan, destType, plugin.refShape());
		if (shadow != null) return Err(shadow);
		final enclosing: Null<String> = enclosingTypeName(path);
		final visibility: String = enclosing == destType ? 'private' : 'public';
		final replaced: String = switch replaceUse(request, initSpan, '$destType.${member.name}', plugin, request.optsJson) {
			case Ok(text, _): text;
			case Err(message): return Err(message);
		};
		final pkg: String = ModuleScan.packageOf(tree);
		return switch ExtractConstant.buildModuleSource(
			true, replaced, pkg, destType, request.sourceFile, member.name, memberText(member, visibility), request.reformat, plugin,
			request.optsJson
		) {
			case Ok(text, _): Ok(text, null, advisories);
			case Err(message): Err(message);
		};
	}

	/** The constant goes into a type of the module `dest`, which the source reaches through an import. */
	private static function intoOtherModule(
		request: ExtractToRequest, dest: ExtractToModule, tree: QueryNode, initSpan: Span, member: ConstantMember, plugin: GrammarPlugin,
		advisories: Array<String>
	): ExtractToResult {
		final shape: RefShape = plugin.refShape();
		final destType: String = request.destType ?? dest.base;
		final destSource: Null<String> = dest.source;
		if (destSource == null && destType != dest.base)
			return Err('module ${dest.file} does not exist, and a new module holds only its main type ${dest.base}');
		if (destSource != null) {
			final destTree: QueryNode = switch ParseGate.parse(plugin, destSource, dest.file) {
				case Unparsed(message): return Err(message);
				case Parsed(parsed): parsed;
			};
			final host: Null<String> = hostRefusal(RefactorSupport.uniqueTypeDeclNamed(destTree, destType), destType, shape);
			if (host != null) return Err(host);
		}
		final module: ModulePath = { path: dest.pkg == '' ? dest.base : '${dest.pkg}.${dest.base}', pkg: dest.pkg, base: dest.base };
		final importPath: String = destType == dest.base ? module.path : '${module.path}.$destType';
		final rebinding: Null<String> = rebindingRefusal(tree, destType, importPath);
		if (rebinding != null) return Err(rebinding);
		final shadow: Null<String> = localShadow(tree, initSpan, destType, shape);
		if (shadow != null) return Err(shadow);
		final replaced: String = switch replaceUse(request, initSpan, '$destType.${member.name}', plugin, request.optsJson) {
			case Ok(text, _): text;
			case Err(message): return Err(message);
		};
		final wildcard: Bool = tree.children.exists(c -> c.kind == 'ImportWildDecl');
		final imported: Bool = tree.children.exists(c -> c.kind == 'ImportDecl' && c.name == importPath);
		final bare: Bool = !wildcard && RefactorSupport.bareNameResolves(destType, module, ModuleScan.packageOf(tree));
		final newSource: String = if (imported || bare)
			replaced
		else
			switch AddImport.addImport(replaced, importPath, false, true, plugin, request.optsJson) {
				case Ok(text, _): text;
				case Err(message): return Err('import: $message');
			};
		return switch ExtractConstant.buildModuleSource(
			destSource != null, destSource, dest.pkg, destType, dest.file, member.name, memberText(member, 'public'), request.reformat,
			plugin, dest.optsJson
		) {
			case Ok(text, _): Ok(newSource, text, advisories);
			case Err(message): Err(message);
		};
	}

	/** Replace the expression at `initSpan` with `reference`. */
	private static function replaceUse(
		request: ExtractToRequest, initSpan: Span, reference: String, plugin: GrammarPlugin, optsJson: Null<String>
	): EditResult {
		return CanonicalEdit.canonicalize(request.source, [{ span: initSpan, text: reference }], request.reformat, plugin, optsJson);
	}

	/** Why `decl` (the receiving type named `name`) cannot hold the constant, or null when it can. */
	private static function hostRefusal(decl: Null<TypeDeclMatch>, name: String, shape: RefShape): Null<String> {
		if (decl == null) return 'no unique type "$name" to receive the constant';
		final hosts: Array<String> = MemberKinds.classLikeContainerKinds(shape);
		return hosts.contains(decl.kind) || hosts.contains(decl.nameNode.kind)
			? null
			: 'type "$name" is a ${decl.kind} — a static final needs a class';
	}

	/** Why the bare `destType` would bind something else in the source file, or null. */
	private static function rebindingRefusal(tree: QueryNode, destType: String, importPath: String): Null<String> {
		if (RefactorSupport.typeDeclsNamed(tree, destType).length > 0)
			return 'the source declares its own type `$destType` — `$destType.NAME` would name it';
		for (child in tree.children) {
			final path: Null<String> = child.name;
			if (path == null) continue;
			final binds: Bool = (child.kind == 'ImportDecl' && path != importPath && lastSegment(path) == destType)
				|| (child.kind == 'ImportAliasDecl' && path == destType);
			if (binds) return 'the source already binds `$destType` by another import — `$destType.NAME` would name that';
		}
		return null;
	}

	/** Why a local of the use's function shadows `name`, or null. */
	private static function localShadow(tree: QueryNode, initSpan: Span, name: String, shape: RefShape): Null<String> {
		final scope: QueryNode = BinderScan.enclosingFunctionSubtree(tree, initSpan.from, shape);
		return BinderScan.boundNames(scope, shape).contains(name)
			? '`$name` is a local name where the expression sits — `$name.NAME` would read it'
			: null;
	}

	/** The name of the innermost type declaration on `path`, or null. */
	private static function enclosingTypeName(path: Array<QueryNode>): Null<String> {
		var i: Int = path.length - 1;
		while (i >= 0) {
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(path[i]);
			if (decl != null) return decl.name;
			i--;
		}
		return null;
	}

}

/** What `ExtractConstantTo.extractTo` moves and where. */
typedef ExtractToRequest = {
	final source: String;
	final sourceFile: String;
	final address: AddressSpec;
	final name: String;

	/** The receiving type; null = the destination module's main type (required when there is no `dest`). */
	final destType: Null<String>;

	/** The destination module, or null when the receiving type is declared in the source file. */
	final dest: Null<ExtractToModule>;

	/** The caller's assertion that no reader mutates a moved array / object literal. */
	final shared: Bool;

	/** The constant's type annotation as the caller spells it, overriding the inferred one. */
	final annotate: Null<String>;
	final reformat: Bool;
	final optsJson: Null<String>;
}

/** A destination module of `extract-constant`: its file, its source (null when it is to be created), its package and name. */
typedef ExtractToModule = {
	final file: String;
	final source: Null<String>;
	final pkg: String;
	final base: String;
	final optsJson: Null<String>;
}

/** The result of `ExtractConstantTo.extractTo`: the new source, the destination module's text (null = the source) and advisories. */
enum ExtractToResult {

	Ok(source: String, dest: Null<String>, advisories: Array<String>);
	Err(message: String);

}

/** The constant `extractTo` writes. */
private typedef ConstantMember = {
	final name: String;
	final typeText: Null<String>;
	final value: String;
	final inlined: Bool;
}
