package anyparse.query;

import anyparse.query.AbstractCasts.TypeEnd;
import anyparse.query.CallSelection.CallArgument;
import anyparse.query.CallSelection.CallCandidate;
import anyparse.query.CallSelection.CallCandidates;
import anyparse.query.CallSignature.SignatureParam;
import anyparse.query.MemberLookup.HostedMembers;
import anyparse.query.NominalTypes.IndexTyping;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.TypingService.TypingHost;
import anyparse.runtime.Span;

using Lambda;

/**
 * The type a call returns in the index's written-source currency (`NominalTypes`) where the typing service selects the
 * signature it binds (`CallSelection`, step T5): the receiver's declarations as the call's file resolves them, the
 * arguments typed once, with no expected type, by the arcs whose type this file writes (`ARGUMENT_HOST`).
 */
@:nullSafety(Strict)
@:access(anyparse.query.NominalTypes)
final class CallReturns {

	/**
	 * `INDEX_HOST` narrowed to the arcs whose type is WRITTEN in the file being read, which is where `callArguments` resolves
	 * it: a literal, a binding's annotation, a local's initializer. A member read, a call, the self reference or a loop element
	 * answer a type written in another file (or a name only), so they type no argument.
	 */
	private static final ARGUMENT_HOST: TypingHost<String, IndexTyping> = {
		peel: (node, _) -> node,
		isAccess: (kind, c) -> kind == c.shape.fieldAccessKind,
		literal: (typeName, _) -> typeName,
		ascribed: NominalTypes.indexAscribed,
		self: (_, _) -> null,
		binding: (ident, c) -> TypeResolver.identBindingFrom(ident, c.root, c.shape),
		bound: argumentBound,
		initializer: (_, use, c) -> NominalTypes.localInitializer(use, c.root, c.shape, c.chain.declaredTypeSources),
		loopElement: (_, _) -> null,
		parameter: null,
		unbound: (_, _) -> null,
		access: (_, _) -> null,
		element: null,
		call: (_, _) -> null,
		construction: null,
		contextual: null,
		arithmetic: null,
		reading: c -> c.seen
	};

	/**
	 * The type the call `node` of `method` returns where the typing service selects its signature (`CallSelection`), on a
	 * receiver of each declaration of `starts` — a type name written at the call (`onType`: a static the type, its plain
	 * aliases followed, declares itself), a value (`onType` false: an instance member), the enclosing type of a bare call
	 * (`onType` null: either, a static only of the type itself) —: every one declaring the member and taking the call
	 * (one no candidate of which compiles is a namesake the receiver is not, the code compiling) returning the same type over
	 * the signatures the call may select (`CallSelection.returnOf`), as its declaring file writes it. The arguments are typed
	 * once (`callArguments`). Null otherwise.
	 */
	public static function selectedReturn(
		node: QueryNode, starts: Array<ResolvedType>, method: String, onType: Null<Bool>, c: IndexTyping
	): Null<String> {
		return agreedOver(
			node, starts, method, onType, c, (calls, start, candidates, args) -> calls.returnOf(start, candidates, args, []),
			(a, b) -> a == b
		);
	}

	/**
	 * The type the parameter the argument `at` of the call `node` binds is written with, and the file writing it, where the
	 * typing service selects the signature the call binds as `selectedReturn` does (`CallSelection.select`) and the
	 * compiler's way of binding the arguments puts that one on one parameter (`CallSelection.parameterRun`): the
	 * parameter's written type with its declaring type's parameters bound through `start`'s chain (`AncestorTable.boundType`),
	 * every declaration of `starts` agreeing. Null for a parameter written with no type, the rest parameter, one written with
	 * a type parameter of the signature or of the member (the call binds it), a choice not decided, and declarations that
	 * disagree.
	 */
	public static function selectedParameter(
		node: QueryNode, starts: Array<ResolvedType>, method: String, onType: Null<Bool>, at: Int, c: IndexTyping
	): Null<WrittenParameter> {
		final held: Null<SymbolIndex> = c.index;
		if (held == null) return null;
		final index: SymbolIndex = held;
		function answer(
			calls: CallSelection, start: ResolvedType, candidates: CallCandidates, args: Array<CallArgument>
		): Null<WrittenParameter> {
			final k: Null<CallCandidate> = calls.select(candidates, args);
			final run: Array<Int> = (k == null ? null : calls.parameterRun(k, args)) ?? [];
			return k == null || at >= run.length ? null : parameterType(start, k, run[at], index);
		}
		return agreedOver(node, starts, method, onType, c, answer, (a, b) -> a.text == b.text && a.file == b.file);
	}

	/** The declaration `owner` of the file `file` as the index holds it, alone; none when it holds none. */
	public static function ownDeclaration(owner: TypeDeclMatch, index: SymbolIndex, file: String): Array<ResolvedType> {
		final found: Null<ResolvedType> = index.refs.findDeclaredType(file, owner.name);
		return found == null ? [] : [found];
	}

	/**
	 * The declaration the type name `name`, written at `at` in the file `file`, resolves to there, alone — else, where the
	 * file resolves no one declaration of it (a std type a target's `_std` copy re-declares, every one read), each
	 * declaration of the name, the walk then asking every one of them to agree.
	 */
	public static function writtenDeclaration(name: String, at: QueryNode, index: SymbolIndex, file: String): Array<ResolvedType> {
		final fi: Null<FileInfo> = index.fileInfo(file);
		final found: Null<ResolvedType> = fi == null ? null : index.refs.resolveTypeRef(name, fi, at.span?.from);
		return found == null ? index.refs.resolvedDeclsNamed(name) : [found];
	}

	/**
	 * What `answer` gives for the call `node` of `method` over the candidates of each declaration of `starts` declaring the
	 * member and taking the call — the shared walk of `selectedReturn` and `selectedParameter`, its arguments typed once
	 * (`callArguments`) —, every one agreeing. Null where one answers null or two disagree.
	 */
	private static function agreedOver<T>(
		node: QueryNode, starts: Array<ResolvedType>, method: String, onType: Null<Bool>, c: IndexTyping,
		answer: (calls:CallSelection, start:ResolvedType, candidates:CallCandidates, args:Array<CallArgument>) -> Null<T>,
		same: (a:T, b:T) -> Bool
	): Null<T> {
		final index: Null<SymbolIndex> = c.index;
		final fi: Null<FileInfo> = index?.fileInfo(c.file);
		if (index == null || fi == null) return null;
		final args: Array<CallArgument> = callArguments(node, c, fi);
		final calls: CallSelection = index.typing.calls;
		var found: Null<T> = null;
		for (start in starts) {
			final declared: Null<HostedMembers> = index.typing.members.declaringMember(start, method);
			if (declared == null) continue;
			final statics: Bool = declared.members.exists(m -> m.isStatic);
			final own: Null<ResolvedType> = index.typing.casts.followed(start);
			// a static is not inherited, and a value reads no static
			final misread: Bool = onType != null && declared.members.exists(m -> m.isStatic != onType);
			if (statics && (own == null || !AncestorTable.same(declared.host, own)) || misread) return null;
			final candidates: Null<CallCandidates> = calls.candidates(declared, statics);
			if (candidates != null && calls.excludes(candidates, args)) continue;
			final given: Null<T> = candidates == null ? null : answer(calls, start, candidates, args);
			if (given == null) return null;
			if (found != null && !same(found, given)) return null;
			found = given;
		}
		return found;
	}

	/**
	 * What the call `node`, written in this file (`fi`), hands its callee: each argument typed once with no expected type
	 * (`ARGUMENT_HOST`), resolved where this file writes it — the `null` literal apart, an argument typed by no such arc
	 * untyped. Remembered by the site and the declaration enclosing it (`QueryCache.callArguments`).
	 */
	private static function callArguments(node: QueryNode, c: IndexTyping, fi: FileInfo): Array<CallArgument> {
		final index: Null<SymbolIndex> = c.index;
		final span: Null<Span> = node.span;
		final args: Array<QueryNode> = node.children.slice(1);
		if (index == null || span == null) return [for (_ in args) Untyped];
		final site: Span = span;
		final owner: Null<TypeDeclInfo> = fi.types.find(t -> t.span.from <= site.from && site.to <= t.span.to);
		final key: DeclarationKey = DeclarationKey.ofSite(
			c.file, owner?.span.from ?? -1, site.from, c.chain.source.length, c.chain.source.substring(site.from, site.to)
		);
		final params: Array<String> = NominalTypes.writtenTypeParams(fi);
		return index.typing.cache.callArguments.answer(
			key,
			() -> [
				for (a in args)
					if (a.kind == c.shape.nullLiteralKind)
						NullValue
					else {
						final own: IndexTyping = {
							root: c.root,
							shape: c.shape,
							declaredTypes: c.declaredTypes,
							chain: c.chain,
							index: index,
							file: c.file,
							seen: []
						};
						final text: Null<String> = TypingService.typeWalk(a, c.shape, ARGUMENT_HOST, own);
						final end: Null<TypeEnd> = text == null ? null : index.typing.casts.endIn(text, fi, site.from, params);
						if (end == null)
							Untyped
						else if (text != null && NominalTypes.outerNominalOf(text, c.chain.typeSyntax) == c.shape.optionalValueTypeName)
							Nullable(end)
						else
							Typed(end);
					}
			]
		);
	}

	/**
	 * The type parameter `p` of the candidate `k` a call on a receiver of `start` binds is written with, its declaring type's
	 * parameters bound through `start`'s chain (`AncestorTable.boundType`), and the file writing it; null for one written with
	 * no type, the rest parameter and one naming a type parameter of the signature or of the member.
	 */
	private static function parameterType(start: ResolvedType, k: CallCandidate, p: Int, index: SymbolIndex): Null<WrittenParameter> {
		final param: Null<SignatureParam> = k.signature.params[p];
		final written: Null<String> = param?.type;
		final own: Array<String> = k.signature.typeParamNames.concat(k.member.typeParamNames);
		if (param == null || written == null || param.form == Rest) return null;
		if (CallGraphNames.mentionsTypeName(written, own, index.typeSyntax)) return null;
		final bound: Null<String> = index.typing.ancestors.boundType(start, k.host, [], written, k.signature.at, own);
		return bound == null ? null : { text: bound, file: k.host.file };
	}

	/** `ARGUMENT_HOST`'s binding: the type the binding at `from` is written with in this file, completed; null for none. */
	private static function argumentBound(from: Int, c: IndexTyping): Null<String> {
		final written: Null<String> = c.chain.declaredTypeSources[from];
		return written == null ? null : NominalTypes.boundType(from, written, c, true);
	}

}

/** The type a parameter is written with, and the file writing it (`CallReturns.selectedParameter`). */
typedef WrittenParameter = {
	final text: String;
	final file: FileInfo;
}
