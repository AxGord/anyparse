package anyparse.check;

import anyparse.query.CallGraphNames;
import anyparse.query.DeclaredNullity;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.Refs.RefHit;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeNameBinding;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;

/**
 * What the declared type of an operand binds to, for ONE file — every type bound in the scope of the
 * file that WRITES it, never by its simple name:
 *
 *  - a read of a binding this file declares (a local, a parameter, a field, a `$name` fragment):
 *    its annotation, here;
 *  - a call to a function this file declares: its written return type, here, with the function's
 *    own type parameters in scope;
 *  - `recv.m` and `recv.m(…)`: the receiver's own declarations (typed the same way, or a type name
 *    for a static access), then `m` as each of them DECLARES it — its type or its return type, bound
 *    in the declaring file with the owner's and the method's type parameters shadowing.
 *
 * Everything else is `Unknown`: an inherited member, a receiver no rule above types, a member whose
 * type is not written. A built-in candidate among several drops out of a `Bound` answer, since it can
 * overload nothing.
 */
@:nullSafety(Strict)
final class OperandBinder {

	private final _file: String;
	private final _source: String;
	private final _tree: QueryNode;
	private final _shape: RefShape;
	private final _index: SymbolIndex;
	private final _declared: DeclaredNullity;
	private final _builtins: Array<String>;
	private final _wrappers: Array<String>;
	private final _identKinds: Array<String>;
	private final _fnKinds: Array<String>;

	public function new(
		file: String, source: String, tree: QueryNode, shape: RefShape, index: SymbolIndex, provider: TypeInfoProvider,
		builtins: Array<String>
	) {
		_file = file;
		_source = source;
		_tree = tree;
		_shape = shape;
		_index = index;
		_declared = DeclaredNullity.of(file, tree, source, shape, provider, () -> index);
		_builtins = builtins;
		_wrappers = shape.memberTransparentWrapperTypeNames ?? [];
		_identKinds = [
			for (kind in [shape.identKind, shape.stringInterpIdentKind]) if (kind != null) kind
		];
		_fnKinds = (shape.functionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
	}

	/** What `operand`'s declared type binds to. */
	public function tierOf(operand: QueryNode): Tier {
		final fieldKind: Null<String> = _shape.fieldAccessKind;
		final member: (QueryNode, Bool) -> Tier = (access, call) -> {
			final name: Null<String> = access.name;
			return name == null || access.kind != fieldKind || access.children.length != 1
				? Unknown
				: memberTier(access.children[0], name, call);
		};
		if (operand.kind == _shape.callKind && operand.children.length > 0) {
			final callee: QueryNode = operand.children[0];
			return _identKinds.contains(callee.kind) ? localCallTier(callee) : member(callee, true);
		}
		if (operand.kind == fieldKind) return member(operand, false);
		final from: Null<Int> = hitOf(operand)?.bindingSpan?.from;
		return from == null ? Unknown : _declared.writtenHeadTier(from, _wrappers, _builtins);
	}

	/**
	 * The reference hit of an identifier read, or null for anything else — and null for a read a
	 * `case` capture may bind instead of the declaration the hit names (`capturedBetween`).
	 */
	private function hitOf(ident: QueryNode): Null<RefHit> {
		final name: Null<String> = ident.name;
		final span: Null<Span> = ident.span;
		if (name == null || span == null || !_identKinds.contains(ident.kind)) return null;
		final hit: Null<RefHit> = TypeResolver.resolveBindingHit(name, span, _tree, _shape);
		return hit == null || capturedBetween(name, span, hit.bindingSpan?.from) ? null : hit;
	}

	/**
	 * Whether a `case` branch holding the read at `at` may capture `name` in its pattern while the
	 * binding the reference walk found (`bindingFrom`) lies OUTSIDE that branch. The walk does not see
	 * a bare lowercase identifier in a pattern as a binder (`case t:` captures, it never compares), so
	 * its answer is the outer declaration the capture shadows. Every non-upper-initial identifier in a
	 * pattern counts, an extractor's function name included: over-counting only declines.
	 */
	private function capturedBetween(name: String, at: Span, bindingFrom: Null<Int>): Bool {
		final branchKind: Null<String> = _shape.caseBranchKind;
		final plainKind: Null<String> = _shape.plainCasePatternKind;
		final binderKinds: Array<String> = _shape.casePatternBinderKinds ?? [];
		final skipUpper: Bool = _shape.upperInitialNeverCaptures == true;
		if (branchKind == null) return false;
		final from: Int = bindingFrom ?? -1;
		function captures(pattern: QueryNode): Bool {
			final n: Null<String> = pattern.name;
			return (n == name && (
				binderKinds.contains(pattern.kind) || (pattern.kind == _shape.identKind && !(skipUpper && SourceText.isUpperInitial(n)))
			)) || pattern.children.exists(captures);
		}
		function walk(node: QueryNode): Bool {
			final span: Null<Span> = node.span;
			if (span == null || at.from < span.from || at.to > span.to) return span == null && node.children.exists(walk);
			final inside: Bool = from >= span.from && from < span.to;
			if (node.kind == branchKind && !inside)
				for (c in node.children)
					if ((c.kind == plainKind || binderKinds.contains(c.kind)) && captures(c)) return true;
			return node.children.exists(walk);
		}
		return walk(_tree);
	}

	/** A call whose callee names a function this file declares: that function's written return type. */
	private function localCallTier(callee: QueryNode): Tier {
		final hit: Null<RefHit> = hitOf(callee);
		final from: Null<Int> = hit?.bindingSpan?.from;
		final fn: Null<QueryNode> = hit?.bindingNode;
		if (from == null || fn == null) return Unknown;
		final declaration: QueryNode = fn;
		final member: Null<MemberInfo> = _index.fileInfo(_file)?.types.flatMap(t -> t.members)
			.find(m -> m.declFrom == declaration.span?.from);
		if (member != null && !typedByItsReturn(member)) return Unknown;
		return _fnKinds.contains(declaration.kind)
			? _declared.headTier(
				CallGraphNames.returnSourceOf(declaration, _source, _shape.typeAnnotationKinds ?? []), from, _wrappers, _builtins
			)
			: Unknown;
	}

	/**
	 * `name` read (or, with `call`, called) on `receiver`: the member as every declaration of the
	 * receiver's type declares it DIRECTLY, each bound in its declaring file.
	 */
	private function memberTier(receiver: QueryNode, name: String, call: Bool): Tier {
		final owners: Null<Array<ResolvedType>> = receiverDecls(receiver);
		if (owners == null) return Unknown;
		final found: Array<ResolvedType> = [];
		for (owner in owners) {
			final members: Array<MemberInfo> = owner.type.members.filter(m -> m.name == name);
			final source: Null<String> = _index.sourceOf(owner.file.file);
			final ownParams: Array<String> = owner.type.typeParamNames;
			if (members.length == 0 || source == null || owner.type.typeParamArity != ownParams.length) return Unknown;
			for (m in members) {
				final written: Null<String> = call ? m.returnSource : m.typeSource;
				if (written == null || (call && !typedByItsReturn(m))) return Unknown;
				final params: Array<String> = call
					? ownParams.concat(CallGraphNames.declaredTypeParams(source, new Span(m.declFrom, m.declFrom), name))
					: ownParams;
				switch DeclaredNullity.headTierIn(written, owner.file, _index, params, _wrappers, _builtins) {
					case Bound(decls):
						for (d in decls) found.push(d);
					case Free:
					case Unknown:
						return Unknown;
				}
			}
		}
		return found.length == 0 ? Free : Bound(found);
	}

	/**
	 * Whether a call to `m` has the type its written return type names: not when `@:overload` offers
	 * other signatures to select, nor for a macro, whose written return is the `Expr` it builds rather
	 * than the type of the expression the call site receives.
	 */
	private static inline function typedByItsReturn(m: MemberInfo): Bool {
		return !m.hasOverloadMeta && !m.isMacro;
	}

	/**
	 * The declarations of the receiver's type: what an operand receiver binds to, or — for an
	 * upper-initial name no binding in this file claims — the type that name binds to, for a static
	 * access. Null when neither is proven, including a built-in receiver whose declaration the index
	 * does not hold.
	 */
	private function receiverDecls(receiver: QueryNode): Null<Array<ResolvedType>> {
		switch tierOf(receiver) {
			case Bound(decls):
				return decls;
			case Free:
				return null;
			case Unknown:
		}
		final name: Null<String> = receiver.name;
		final hit: Null<RefHit> = hitOf(receiver);
		final fi: Null<FileInfo> = _index.fileInfo(_file);
		if (name == null || fi == null || !_identKinds.contains(receiver.kind) || !SourceText.isUpperInitial(name)) return null;
		if (hit != null && (hit.bindingSpan != null || hit.bindingNode != null)) return null;
		return switch TypeNameBinding.tierOf(name, fi, _index) {
			case Bound(decls): decls;
			case _: null;
		};
	}

}
