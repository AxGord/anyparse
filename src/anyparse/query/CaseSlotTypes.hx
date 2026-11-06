package anyparse.query;

import anyparse.query.CasePatterns.PatternIdent;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.NominalTypes.ChainTypeContext;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.query.TypingService.Resolution;

using Lambda;

/**
 * What the slots of a `case` pattern hold, read off the declarations of a run's index: the written type a
 * switch subject carries, the type a constructor's parameter takes under the type arguments of the value it
 * matches, whether that type can claim a bare name as a constant, and whether a run of arms matches every
 * constructor of an enum — the one answer to "what type does this slot of a case pattern hold". Every
 * unknown reads as no proof, so a caller acts only on what the declarations state.
 */
@:nullSafety(Strict)
final class CaseSlotTypes {

	private final _file: String;
	private final _source: String;
	private final _root: QueryNode;
	private final _shape: RefShape;
	private final _typeSyntax: TypeSyntaxReader;
	private final _provider: TypeInfoProvider;
	private final _index: SymbolIndex;

	public function new(
		file: String, source: String, root: QueryNode, plugin: GrammarPlugin, provider: TypeInfoProvider, index: SymbolIndex
	) {
		_file = file;
		_source = source;
		_root = root;
		_shape = plugin.refShape();
		_typeSyntax = plugin.typeSyntax;
		_provider = provider;
		_index = index;
	}

	/**
	 * The type `subject` carries, as its declaration writes it. That declaration may sit in another file, so
	 * the text has no reading scope here and only a name the whole index declares once resolves through it.
	 */
	public function subjectType(subject: QueryNode): Null<SlotType> {
		final chain: ChainTypeContext = {
			declaredTypeSources: _provider.declaredTypeSources(_source),
			source: _source,
			castTargetSources: TypeInfoMemo.castTargetSources(_provider, _source),
			typeSyntax: _typeSyntax
		};
		final written: Null<String> = NominalTypes.expressionTypeSource(
			peeled(subject), _root, _shape, _provider.declaredTypes(_source), _index, _file, chain
		);
		return written == null ? null : {
			source: written,
			scope: null,
			argsUnread: false,
			optional: false
		};
	}

	/** The type the slot `target` of `pattern`, a pattern of `switchNode`, holds. */
	public function slotAt(switchNode: QueryNode, pattern: QueryNode, target: QueryNode): Null<SlotType> {
		if (switchNode.children.length == 0) return null;
		final subject: Null<SlotType> = subjectType(switchNode.children[0]);
		return subject == null ? null : typeAt(pattern, subject, target);
	}

	/** The typed proof of a capture in `pattern`, a pattern of `switchNode`, for `CasePatterns.isDecidedCapture`. */
	public function slotProof(switchNode: QueryNode, pattern: QueryNode): (PatternIdent) -> Bool {
		return ident -> {
			final slot: Null<SlotType> = slotAt(switchNode, pattern, ident.node);
			slot != null && rulesOutConstant(slot, ident.name);
		};
	}

	/**
	 * Whether a value of `type` can never compare against the bare `name`. Only the type a pattern expects lends its
	 * own values to a bare name, so a structure, a function, a built-in value type and a declared class pass, and an
	 * enum or enum abstract passes when it declares no such member. A typedef naming a type, a plain abstract and an
	 * unresolved name do not.
	 */
	public function rulesOutConstant(type: SlotType, name: String): Bool {
		final syntax: Null<TypeSyntax> = _typeSyntax(unwrapped(type));
		if (syntax == null) return false;
		return switch syntax.shape {
			case Function(_, _, _), Structure(_): true;
			case Nominal(path, _):
				CasePatterns.isBuiltinValueType(path, _shape) || declarationHolds(declarationOf(path, type.scope), name);
			case _: false;
		};
	}

	/**
	 * Whether `arms` leave no value of `type` unmatched: `type` is an enum, neither a wrapper nor an optional
	 * parameter admits a null, and each constructor has an unguarded arm matching it whole, its every
	 * argument a wildcard or a proven capture.
	 */
	public function covers(type: SlotType, arms: Array<QueryNode>, scope: PatternNameScope): Bool {
		if (type.optional || unwrapped(type) != type.source) return false;
		final decl: Null<ResolvedType> = enumOf(type);
		if (decl == null) return false;
		final ctors: Array<MemberInfo> = decl.type.members;
		if (ctors.length == 0) return false;
		final matched: Array<String> = [];
		for (arm in arms) {
			final run: Array<QueryNode> = CasePatterns.patternRun(arm, _shape);
			if (run.length < arm.children.length && arm.children[run.length].kind == _shape.parenKind) continue;
			final idents: Array<PatternIdent> = CasePatterns.scan(arm, _shape, []).idents;
			for (plain in run) if (plain.children.length == 1) ctorsMatched(plain.children[0], type, ctors, idents, scope, matched);
		}
		return ctors.foreach(m -> matched.contains(m.name));
	}

	private inline function wrappers(): Array<String> {
		return _shape.nullableWrapperTypeNames ?? [];
	}

	private inline function unwrapped(type: SlotType): String {
		return NominalTypes.unwrapNullable(type.source, wrappers(), _typeSyntax);
	}

	/** Collects the constructors `pattern` matches whole. */
	private function ctorsMatched(
		pattern: QueryNode, type: SlotType, ctors: Array<MemberInfo>, idents: Array<PatternIdent>, scope: PatternNameScope,
		out: Array<String>
	): Void {
		final node: QueryNode = peeled(pattern);
		if (node.kind == _shape.orPatternKind) {
			for (side in node.children) ctorsMatched(side, type, ctors, idents, scope, out);
		} else if (node.kind == _shape.identKind) {
			final info: Null<MemberInfo> = ctors.find(m -> m.name == node.name);
			if (info != null && info.paramTypeSources.length == 0) out.push(info.name);
		} else if (node.kind == _shape.callKind && CasePatterns.isNamedCallee(node, _shape)) {
			final info: Null<MemberInfo> = ctors.find(m -> m.name == node.children[0].name);
			if (info == null || info.paramTypeSources.length != node.children.length - 1) return;
			for (i in 1...node.children.length) if (!wholeSlot(node.children[i], slotOf(type, info.name, i - 1), idents, scope)) return;
			out.push(info.name);
		}
	}

	/** Whether the argument `arg` of a pattern takes whatever its slot holds. */
	private function wholeSlot(arg: QueryNode, slot: Null<SlotType>, idents: Array<PatternIdent>, scope: PatternNameScope): Bool {
		final node: QueryNode = peeled(arg);
		if (node.kind == _shape.identKind && node.name == _shape.wildcardPatternName) return true;
		final ident: Null<PatternIdent> = idents.find(i -> i.node == node);
		return ident != null
			&& CasePatterns.isDecidedCapture(
				ident, { typed: false, isDynamic: false }, scope, i -> slot != null && rulesOutConstant(slot, i.name)
			);
	}

	/** The type `target` meets inside `pattern`, itself matched against `expected`. */
	private function typeAt(pattern: QueryNode, expected: SlotType, target: QueryNode): Null<SlotType> {
		if (pattern == target) return expected;
		if (pattern.kind == _shape.parenKind || pattern.kind == _shape.orPatternKind) {
			for (child in pattern.children) {
				final found: Null<SlotType> = typeAt(child, expected, target);
				if (found != null) return found;
			}
			return null;
		}
		if (pattern.kind != _shape.callKind || !CasePatterns.isNamedCallee(pattern, _shape)) return null;
		final ctor: Null<String> = pattern.children[0].name;
		if (ctor == null) return null;
		for (i in 1...pattern.children.length) {
			final slot: Null<SlotType> = slotOf(expected, ctor, i - 1);
			final found: Null<SlotType> = slot == null ? null : typeAt(pattern.children[i], slot, target);
			if (found != null) return found;
		}
		return null;
	}

	/**
	 * What parameter `at` of the constructor `ctor` holds on a value of `expected`. A parameter that is one of the enum's own
	 * type parameters takes the argument the value's type writes, in that type's reading scope; any other reads in the enum's file.
	 */
	private function slotOf(expected: SlotType, ctor: String, at: Int): Null<SlotType> {
		final decl: Null<ResolvedType> = enumOf(expected);
		final info: Null<MemberInfo> = decl?.type.members.find(m -> m.name == ctor);
		if (decl == null || info == null) return null;
		final written: Null<String> = info.paramTypeSources[at];
		if (written == null) return null;
		final enumSource: Null<String> = _index.sourceOf(decl.file.file);
		// a constructor's own type parameter is whatever the construction instantiates, which no written type here states
		if (
			enumSource == null
			|| CallGraphNames.mentionsTypeName(written, _provider.typeParamNames(enumSource)[info.declFrom] ?? [], _typeSyntax)
		)
			return null;
		final optional: Bool = at >= info.paramSkippableFrom;
		final names: Array<String> = decl.type.typeParamNames;
		final position: Int = names.indexOf(written);
		if (position < 0) {
			final mentions: Bool = CallGraphNames.mentionsTypeName(written, names, _typeSyntax);
			final wrapsParam: Bool = mentions && names.contains(NominalTypes.unwrapNullable(written, wrappers(), _typeSyntax));
			return wrapsParam ? null : {
				source: written,
				scope: { file: decl.file, at: info.declFrom },
				argsUnread: mentions,
				optional: optional
			};
		}
		if (expected.argsUnread) return null;
		final args: Array<String> = NominalTypes.typeArgumentSourcesOf(unwrapped(expected), _typeSyntax) ?? [];
		final arg: Null<String> = args[position];
		return arg == null ? null : {
			source: arg,
			scope: expected.scope,
			argsUnread: false,
			optional: optional
		};
	}

	/**
	 * The enum a value of `type` is one of: not an enum abstract, which holds values it
	 * does not declare, and not a type naming it through a typedef, which reads as unknown.
	 */
	private function enumOf(type: SlotType): Null<ResolvedType> {
		final syntax: Null<TypeSyntax> = _typeSyntax(unwrapped(type));
		if (syntax == null) return null;
		return switch syntax.shape {
			case Nominal(path, _):
				final decl: Null<ResolvedType> = declarationOf(path, type.scope);
				final aliases: Array<String> = _shape.aliasingDeclKinds ?? [];
				decl != null && (_shape.bareConstructorTypeKinds ?? []).contains(decl.type.kind) && !aliases.contains(decl.type.kind)
					? decl
					: null;
			case _: null;
		};
	}

	/** The one declaration `path` names: from its reading scope, or across the index when none is known. */
	private function declarationOf(path: String, scope: Null<SlotScope>): Null<ResolvedType> {
		final resolution: Resolution = scope == null
			? _index.typing.resolveUnscoped(path)
			: _index.typing.resolve(scope.file, path, scope.at);
		return switch resolution {
			case Declared(decl): decl;
			case Unknown: null;
		};
	}

	/** Whether a slot of the declared type `decl` lends no constant named `name`. */
	private function declarationHolds(decl: Null<ResolvedType>, name: String): Bool {
		if (decl == null) return false;
		final kind: String = decl.type.kind;
		if ((_shape.bareConstructorTypeKinds ?? []).contains(kind)) return !decl.type.members.exists(m -> m.name == name);
		if ((_shape.aliasingDeclKinds ?? []).contains(kind)) return decl.type.isAnonStruct;
		return (_shape.typeDeclKinds ?? []).contains(kind);
	}

	private function peeled(node: QueryNode): QueryNode {
		var inner: QueryNode = node;
		while (inner.kind == _shape.parenKind && inner.children.length == 1) inner = inner.children[0];
		return inner;
	}

}

/** A written type a pattern slot holds. */
typedef SlotType = {

	final source: String;

	/** Where `source` is read; null when the text came from a declaration whose file is not known here. */
	final scope: Null<SlotScope>;

	/** True when `source` mentions type parameters of an enclosing enum, so its own arguments bind nothing here. */
	final argsUnread: Bool;

	/** True when the slot is an optional parameter, which holds null though `source` writes no wrapper. */
	final optional: Bool;

}

/** The file and offset a written type reads from. */
typedef SlotScope = {
	final file: FileInfo;
	final at: Int;
}
