package anyparse.query;

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
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.query.TypeTerm.TypeEnd;
import anyparse.query.TypingService.TypingHost;
import anyparse.runtime.Span;

using Lambda;

/**
 * The type a call returns in the index's written-source currency (`NominalTypes`) where the typing service selects the
 * signature it binds (`CallSelection`, step T5): the receiver's declarations as the call's file resolves them, the
 * arguments typed once, with no expected type, by the arcs whose type this file writes (`argumentHost`).
 */
@:nullSafety(Strict)
@:access(anyparse.query.NominalTypes)
final class CallReturns {

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
			(a, b) -> a == b ? a : null
		);
	}

	/**
	 * The type the parameter the argument `at` of the call `node` binds is written with, and the file writing it, where the
	 * typing service selects the signature the call binds as `selectedReturn` does (`CallSelection.select`) and the
	 * compiler's way of binding the arguments puts that one on one parameter (`CallSelection.parameterRun`): the parameter's
	 * type as `parameterType` reads it — its declaring type's parameters bound through `start`'s chain and the type arguments
	 * `receiverArgs` the receiver is written with, the signature's own by the arguments before it —, every declaration of
	 * `starts` agreeing. Null for a parameter written with no type, the rest parameter, a choice not decided, and declarations
	 * that disagree.
	 */
	public static function selectedParameter(
		node: QueryNode, starts: Array<ResolvedType>, method: String, onType: Null<Bool>, at: Int, receiverArgs: Array<String>,
		c: IndexTyping
	): Null<WrittenParameter> {
		final held: Null<SymbolIndex> = c.index;
		if (held == null) return null;
		final index: SymbolIndex = held;
		function answer(
			calls: CallSelection, start: ResolvedType, candidates: CallCandidates, args: Array<CallArgument>
		): Null<WrittenParameter> {
			final k: Null<CallCandidate> = calls.select(candidates, args);
			final run: Array<Int> = (k == null ? null : calls.parameterRun(k, args)) ?? [];
			return k == null || at >= run.length
				? null
				: parameterType(start, k, {
					run: run,
					at: at,
					receiverArgs: receiverArgs,
					given: a -> argumentText(node, a, c)
				}, node, c, index);
		}
		return agreedOver(node, starts, method, onType, c, answer, mergedParameter.bind(_, _, index.typeSyntax));
	}

	/**
	 * The type the parameter the argument `at` of the call `node` (`recv.method(…)`) binds is written with where the call
	 * binds a static extension (`StaticExtensions.binding`, step T3) on a receiver of the declaration `start` whose type is
	 * written `receiver`: the receiver takes the extension's first parameter (`unify_typed_args`), the arguments the rest,
	 * and it binds the signature's type parameters before they do (`parameterType`). Null where no extension is proved to
	 * bind, and where its signature is not selected.
	 */
	public static function extensionParameter(
		node: QueryNode, start: ResolvedType, receiver: String, method: String, at: Int, c: IndexTyping
	): Null<WrittenParameter> {
		final index: Null<SymbolIndex> = c.index;
		final fi: Null<FileInfo> = index?.fileInfo(c.file);
		final site: Null<Span> = node.span;
		if (index == null || fi == null || site == null) return null;
		final calls: CallSelection = index.typing.calls;
		final declared: Null<HostedMembers> = index.typing.extensions.binding(fi, start, method);
		final candidates: Null<CallCandidates> = declared == null ? null : calls.candidates(declared, true);
		if (declared == null || candidates == null) return null;
		final params: Array<String> = NominalTypes.writtenTypeParams(fi);
		final args: Array<CallArgument> = [argumentOf(receiver, fi, site.from, params, c)].concat(callArguments(node, c, fi));
		final k: Null<CallCandidate> = calls.select(candidates, args);
		final run: Array<Int> = (k == null ? null : calls.parameterRun(k, args)) ?? [];
		final given: Int -> Null<String> = a -> a == 0 ? receiver : argumentText(node, a - 1, c);
		return k == null || at + 1 >= run.length
			? null
			: parameterType(declared.host, k, {
				run: run,
				at: at + 1,
				receiverArgs: [],
				given: given
			}, node, c, index);
	}

	/**
	 * The type `node` carries where this file writes it (`argumentHost`: a literal, an annotation, a construction, the self
	 * reference, a local's initializer read so), with no expected type; null for one a member read, a call or another arc
	 * types — a type written in another file,
	 * which a namesake here would take the place of.
	 */
	public static function writtenType(node: QueryNode, c: IndexTyping): Null<String> {
		return TypingService.typeWalk(node, c.shape, argumentHost(true), c);
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
	 * `INDEX_HOST` narrowed to the arcs whose type is WRITTEN in the file being read, which is where `callArguments` resolves
	 * it: a literal, a binding's annotation, a local's initializer, with `writtenHere` a construction (the type it writes) and the
	 * self reference (its type, or an abstract's underlying one, written in this file). A member read, a call or a loop element
	 * answer a type written in another file (or a name only), so they type no argument. Built per question: the index host
	 * reaches this class through its composed values, so no static of it may read the index host's back.
	 */
	private static function argumentHost(writtenHere: Bool = false): TypingHost<String, IndexTyping> {
		return {
			peel: (node, _) -> node,
			isAccess: (kind, c) -> kind == c.shape.fieldAccessKind,
			literal: (typeName, _) -> typeName,
			ascribed: NominalTypes.indexAscribed,
			self: writtenHere ? NominalTypes.indexSelf : (_, _) -> null,
			binding: (ident, c) -> TypeResolver.identBindingFrom(ident, c.root, c.shape),
			bound: argumentBound,
			initializer: (_, use, c) -> NominalTypes.localInitializer(use, c.root, c.shape, c.chain.declaredTypeSources),
			loopElement: (_, _) -> null,
			parameter: null,
			unbound: (_, _) -> null,
			access: (_, _) -> null,
			element: null,
			call: (_, _) -> null,
			construction: writtenHere ? ComposedValues.indexConstruction : null,
			contextual: null,
			arithmetic: null,
			reading: c -> c.seen
		};
	}

	/**
	 * What `answer` gives for the call `node` of `method` over the candidates of each declaration of `starts` declaring the
	 * member and taking the call — the shared walk of `selectedReturn` and `selectedParameter`, its arguments typed once
	 * (`callArguments`) —, every one agreeing. Null where one answers null or two disagree.
	 */
	private static function agreedOver<T>(
		node: QueryNode, starts: Array<ResolvedType>, method: String, onType: Null<Bool>, c: IndexTyping,
		answer: (calls:CallSelection, start:ResolvedType, candidates:CallCandidates, args:Array<CallArgument>) -> Null<T>,
		merged: (a:T, b:T) -> Null<T>
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
			final agreed: Null<T> = given == null || found == null ? given : merged(found, given);
			if (agreed == null) return null;
			found = agreed;
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
						final text: Null<String> = TypingService.typeWalk(a, c.shape, argumentHost(), own);
						text == null ? Untyped : argumentOf(text, fi, site.from, params, c);
					}
			]
		);
	}

	/**
	 * What an argument of the type `text`, written in `fi` at `at` (`params` the type parameters in scope there), hands its
	 * callee: the end it resolves to (`AbstractCasts.endIn`), nullable when it is written `Null<…>`.
	 */
	private static function argumentOf(text: String, fi: FileInfo, at: Int, params: Array<String>, c: IndexTyping): CallArgument {
		final end: TypeEnd = c.index?.typing.casts.endIn(text, fi, at, params) ?? Open;
		return NominalTypes.outerNominalOf(text, c.chain.typeSyntax) == c.shape.optionalValueTypeName ? Nullable(end) : Typed(end);
	}

	/** The type of the argument `a` of the call `node` as this file writes it (`writtenType`); null for none. */
	private static function argumentText(node: QueryNode, a: Int, c: IndexTyping): Null<String> {
		final arg: Null<QueryNode> = node.children[a + 1];
		return arg == null ? null : writtenType(arg, c);
	}

	/** The type `term` spells, for a binding a monomorph took: none for a cell, nor for an opaque type naming one. */
	private static function termText(term: Null<TypeTerm>): Null<String> {
		return switch term {
			case Of(_, _, text): text;
			case Opaque(text, monos) if (monos.length == 0): text;
			case _: null;
		};
	}

	/**
	 * Two declarations' answers for one parameter as one: null unless they spell one type as far bound (`TypeSyntax.spellsAs`,
	 * read by `syntax`); read in two files, the first's spelling read in no one file.
	 */
	private static function mergedParameter(a: WrittenParameter, b: WrittenParameter, syntax: TypeSyntaxReader): Null<WrittenParameter> {
		final x: Null<TypeSyntax> = syntax(a.text);
		final y: Null<TypeSyntax> = syntax(b.text);
		return if (x == null || y == null || !x.spellsAs(y) || a.unbound.join(',') != b.unbound.join(','))
			null
		else if (a.file == b.file)
			a
		else
			{ text: a.text, file: null, unbound: a.unbound };
	}

	/**
	 * The type the parameter of the candidate `k` that the argument `bound.at` binds is written with, on a receiver of
	 * `start`, and the file it reads in: its declaring type's parameters bound through `start`'s chain and the receiver's
	 * written arguments (`AncestorTable.boundType`), each type parameter of the signature written as the type the arguments
	 * before it bind it to (`inferredCells`) — one they bind to none listed `unbound`, left as written. The calling file when
	 * every name the parameter and the chain write reads alike there (`TypeRefIndex.readsAlike`); else the declaring file,
	 * and none where a type the receiver or an argument is written with is spelled into it. Null for one written with no
	 * type, the rest parameter, one naming a type parameter of the member the signature does not declare, and one whose
	 * declaring type's parameters are not bound.
	 */
	private static function parameterType(
		start: ResolvedType, k: CallCandidate, bound: ArgumentRun, node: QueryNode, c: IndexTyping, index: SymbolIndex
	): Null<WrittenParameter> {
		final param: Null<SignatureParam> = k.signature.params[bound.run[bound.at]];
		final written: Null<String> = param?.type;
		final own: Array<String> = k.signature.typeParamNames.concat(k.member.typeParamNames);
		if (param == null || written == null || param.form == Rest) return null;
		final text: Null<String> = index.typing.ancestors.boundType(start, k.host, bound.receiverArgs, written, k.signature.at, own);
		final foreign: Array<String> = k.member.typeParamNames.filter(n -> !k.signature.typeParamNames.contains(n));
		if (text == null || CallGraphNames.mentionsTypeName(text, foreign, index.typeSyntax)) return null;
		final named: Array<String> = k.signature.typeParamNames.filter(n -> CallGraphNames.mentionsTypeName(text, [n], index.typeSyntax));
		final names: Array<String> = [];
		final types: Array<String> = [];
		final unbound: Array<String> = [];
		final monos: Monomorphs = new Monomorphs();
		final cells: Map<String, Int> = named.length == 0 ? [] : inferredCells(start, k, bound, monos, node, c, index);
		for (name in named) {
			final cell: Null<Int> = cells[name];
			final type: Null<String> = cell == null ? null : termText(monos.resolved(cell));
			if (type == null) {
				unbound.push(name);
				continue;
			}
			names.push(name);
			types.push(type);
		}
		final caller: Null<FileInfo> = index.fileInfo(c.file);
		final substituted: Bool = bound.receiverArgs.length > 0 || names.length > 0;
		final file: Null<FileInfo> = if (caller != null && readsInCaller(start, k, written, caller, index))
			caller
		else if (substituted)
			null
		else
			k.host.file;
		return { text: CallGraphNames.substituteTypeParams(text, names, types, index.typeSyntax), file: file, unbound: unbound };
	}

	/**
	 * Whether the parameter type `written` of the candidate `k`, and what `start`'s chain passes to the declaring type's
	 * parameters, read in the calling file `caller` as where they are written (`TypeRefIndex.readsAlike`): a namesake the
	 * caller declares or imports would otherwise take the type's place.
	 */
	private static function readsInCaller(
		start: ResolvedType, k: CallCandidate, written: String, caller: FileInfo, index: SymbolIndex
	): Bool {
		final scope: Array<String> = k.signature.typeParamNames.concat(k.member.typeParamNames).concat(k.host.type.typeParamNames);
		return index.refs.readsAlike(written, k.host.file, caller, scope, index.typeSyntax)
			&& index.typing.ancestors.chainReadsAlike(start, k.host, caller);
	}

	/**
	 * The cells of the type parameters of the candidate `k`'s signature (`InferencePolicy.callCells`) as the arguments before
	 * `bound.at` bind them, left to right (`attempt_call`, `unify_call_args`): the type of each (`bound.given`, the receiver of
	 * a static extension first) unified with the parameter it binds (`Monomorphs.unify`), the cells a parameter names
	 * poisoned where its argument is not typed — a lambda or a literal the expected type types may bind them.
	 */
	private static function inferredCells(
		start: ResolvedType, k: CallCandidate, bound: ArgumentRun, monos: Monomorphs, node: QueryNode, c: IndexTyping, index: SymbolIndex
	): Map<String, Int> {
		final policy: InferencePolicy = index.typing.inference;
		final cells: Map<String, Int> = policy.callCells(k, monos);
		final fi: Null<FileInfo> = index.fileInfo(c.file);
		final site: Int = node.span?.from ?? 0;
		final own: Array<String> = k.signature.typeParamNames.concat(k.member.typeParamNames);
		for (a in 0...bound.at) {
			final written: Null<String> = k.signature.params[bound.run[a]]?.type;
			if (written == null) continue;
			final read: Null<String> = index.typing.ancestors.boundType(start, k.host, bound.receiverArgs, written, k.signature.at, own);
			final wanted: TypeTerm = policy.termOf(read ?? written, k.host.file, k.signature.at, cells);
			final given: Null<String> = read == null || fi == null ? null : bound.given(a);
			if (given == null || fi == null)
				for (cell in Monomorphs.cellsOf(wanted)) monos.poison(cell);
			else
				monos.unify(wanted, policy.termOf(given, fi, site, []), policy.reread.bind(_, _, fi));
		}
		return cells;
	}

	/** `ARGUMENT_HOST`'s binding: the type the binding at `from` is written with in this file, completed; null for none. */
	private static function argumentBound(from: Int, c: IndexTyping): Null<String> {
		final written: Null<String> = c.chain.declaredTypeSources[from];
		return written == null ? null : NominalTypes.boundType(from, written, c, true);
	}

}

/**
 * The type a parameter is written with, and the file writing it — none where several declarations of the callee agree on
 * the type from different files (`CallReturns.selectedParameter`); `unbound` the type parameters of the call's signature
 * it still names, which no argument before it binds.
 */
typedef WrittenParameter = {
	final text: String;
	final file: Null<FileInfo>;
	final unbound: Array<String>;
}

/** How a call's arguments meet the signature it selects, as far as typing one of them reads it (`CallReturns.parameterType`). */
typedef ArgumentRun = {

	/** The parameter each argument binds, in argument order (`CallSelection.parameterRun`). */
	final run: Array<Int>;

	/** The argument whose parameter is asked. */
	final at: Int;

	/** The type arguments the receiver is written with, for its type's parameters. */
	final receiverArgs: Array<String>;

	/** The type of the argument at an index, typed with no expected type; null for one not typed. */
	final given: (at:Int) -> Null<String>;

}
