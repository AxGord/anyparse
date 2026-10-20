package anyparse.query;

import anyparse.query.AbstractCasts.TypeEnd;
import anyparse.query.ArgumentSlots.ArgumentFit;
import anyparse.query.ArgumentSlots.SlotParam;
import anyparse.query.CallSignature.ParamForm;
import anyparse.query.CallSignature.SignatureParam;
import anyparse.query.MemberLookup.HostedMembers;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.TypeSyntax.TypeSyntaxReader;

using Lambda;

/** How a member's calls choose among its signatures (`callUnification.ml`, `overload_kind`). */
enum abstract OverloadKind(Int) {

	/** One signature. */
	final Single = 0;

	/** `@:overload` annotations: the member's own signature, then each annotation's, tried in order; the first compiling binds. */
	final Meta = 1;

	/** The `overload` modifier: every candidate is tried, the most specific of those compiling binds. */
	final Proper = 2;

}

/** What a call hands one parameter, as far as the signature it selects depends on it. */
enum CallArgument {

	/** A value of the type the end stands for, typed with no expected type: the same whichever signature is tried. */
	Typed(end: TypeEnd);

	/** The `null` literal. */
	NullValue;

	/** A value not typed — one whose type the expected type may decide (an untyped function, an empty literal), or unknown. */
	Untyped;

}

/** One signature a call may select: the signature, the member writing it and the declaration it is declared on. */
typedef CallCandidate = {
	final signature: CallSignature;
	final member: MemberInfo;
	final host: ResolvedType;
}

/** The signatures a call to one member selects from, and how (`CallSelection.candidates`). */
typedef CallCandidates = {
	final kind: OverloadKind;
	final candidates: Array<CallCandidate>;
}

/**
 * The signature a call selects among those of the member it calls, and the type it returns (`docs/typing-service.md`, step
 * T5; Haxe 4.3.7 `callUnification.ml`, `unify_field_call` and `attempt_calls`). The candidates of an `@:overload` member are
 * its own signature, then each annotation's in written order (`init_meta_overloads`), and the first that compiles binds;
 * an `overload` member's are every same-named one, and the one compiling binds (`reduce_compatible` among several). Whether
 * a candidate compiles is `ArgumentSlots.compiles` over the arguments typed ONCE, with no expected type (`CallArgument`),
 * each cast to its parameter's type by `Unification.casts`.
 *
 * A positive whitelist, like every answer of the typing service. The code it reads compiles, so a candidate whose fit is not
 * decided still binds when it is the only one left that may compile; a choice that rests on a fit not decided otherwise —
 * an argument whose type the expected type decides, a parameter type the cast graph does not model — answers null, as do
 * a member declared in several `#if` branches or under one, an annotation that writes no one function, and an `overload`
 * member read off a value (its candidates take in the supertypes' too, `Overloads.get_overloads`).
 */
@:nullSafety(Strict)
final class CallSelection {

	/** The cast graph: the end each parameter type resolves to. */
	private final _casts: AbstractCasts;

	/** Whether an argument casts to a parameter (`Unification.casts`). */
	private final _unification: Unification;

	/** The supertype chains: where a candidate's return type is bound to the receiver's arguments (`AncestorTable.boundType`). */
	private final _ancestors: AncestorTable;

	/** `GrammarPlugin.typeSyntax`. */
	private final _typeSyntax: TypeSyntaxReader;

	/** Built once by the owning `TypingService`. */
	public function new(
		casts: AbstractCasts, unification: Unification, ancestors: AncestorTable, typeSyntax: TypeSyntaxReader
	) {
		_casts = casts;
		_unification = unification;
		_ancestors = ancestors;
		_typeSyntax = typeSyntax;
	}

	/**
	 * The candidates a call to the member `declared` holds selects from, read off a type (`onType`: a static) or off a
	 * value: one function's signatures in order (`Single`, or `Meta` with its annotations), or every `overload` member of a
	 * static (`Proper`). Null for a member under `#if`, one declared in several branches, a field, an `overload` member read
	 * off a value, and a member whose annotations the index does not read as signatures.
	 */
	public function candidates(declared: HostedMembers, onType: Bool): Null<CallCandidates> {
		final members: Array<MemberInfo> = declared.members;
		if (members.length == 0 || members.exists(m -> m.guarded || m.signatures.length == 0)) return null;
		final host: ResolvedType = declared.host;
		if (members.length == 1 && !members[0].isOverload) {
			final m: MemberInfo = members[0];
			return {
				kind: m.signatures.length == 1 ? Single : Meta,
				candidates: [for (s in m.signatures) { signature: s, member: m, host: host }]
			};
		}
		// several members of one name are overloads only when every one is; a static's take in no supertype's
		return !onType || members.exists(m -> !m.isOverload || !m.isStatic || m.signatures.length != 1)
			? null
			: { kind: Proper, candidates: [for (m in members) { signature: m.signatures[0], member: m, host: host }] };
	}

	/**
	 * Whether no candidate of `c` compiles for a call passing `args`: the call's receiver is then of another declaration (the
	 * code compiles) — a namesake a package-blind reader holds beside it.
	 */
	public function excludes(c: CallCandidates, args: Array<CallArgument>): Bool {
		return c.candidates.foreach(k -> verdict(k, args) == Misfits);
	}

	/** The candidate of `c` a call passing `args` binds (`chosen` over `verdict`), or null. */
	public function select(c: CallCandidates, args: Array<CallArgument>): Null<CallCandidate> {
		final at: Null<Int> = chosen(c.kind, [for (k in c.candidates) verdict(k, args)]);
		return at == null ? null : c.candidates[at];
	}

	/**
	 * The type a call binding the candidate `k` returns, on a receiver of the declaration `start` written with the type
	 * arguments `receiverArgs`: its written return type as the compiler reads it where it is written, `k.host`'s type
	 * parameters bound through `start`'s chain (`AncestorTable.boundType`). Null for a return written with no type (the body
	 * infers it), one that is no one type, and one naming a type parameter of the candidate or the member — what the call's
	 * arguments bind it to is not inferred.
	 */
	public function returnType(start: ResolvedType, k: CallCandidate, receiverArgs: Array<String>): Null<String> {
		final written: Null<String> = k.signature.returnSource;
		final own: Array<String> = k.signature.typeParamNames.concat(k.member.typeParamNames);
		return written == null || !NominalTypes.answerableType(written, _typeSyntax)
			|| CallGraphNames.mentionsTypeName(written, own, _typeSyntax)
			? null
			: _ancestors.boundType(start, k.host, receiverArgs, written, k.signature.at, own);
	}

	/**
	 * The type a call passing `args` returns over the candidates `c` on a receiver of `start` written with `receiverArgs`
	 * (`returnType`): the candidate it binds's (`select`), or — none decided — the one every candidate that may bind it
	 * returns (`ArgumentSlots.compiles` not `Misfits`), as all of them are written in one declaration. Null when they
	 * differ, and when one of them returns a type `returnType` does not read.
	 */
	public function returnOf(start: ResolvedType, c: CallCandidates, args: Array<CallArgument>, receiverArgs: Array<String>): Null<String> {
		final verdicts: Array<ArgumentFit> = [for (k in c.candidates) verdict(k, args)];
		final at: Null<Int> = chosen(c.kind, verdicts);
		if (at != null) return returnType(start, c.candidates[at], receiverArgs);
		var agreed: Null<String> = null;
		for (i => fits in verdicts) if (fits != Misfits) {
			final returned: Null<String> = returnType(start, c.candidates[i], receiverArgs);
			if (returned == null || agreed != null && agreed != returned) return null;
			agreed = returned;
		}
		return agreed;
	}

	/** Whether a call passing `args` compiles against the candidate `k` (`ArgumentSlots.compiles`). */
	public function verdict(k: CallCandidate, args: Array<CallArgument>): ArgumentFit {
		final signature: CallSignature = k.signature;
		return ArgumentSlots.compiles(slotsOf(signature), args.length, (a, p) -> fit(k, args[a], p), p -> skipsSafely(signature, p));
	}

	/**
	 * How the argument `arg` meets parameter `p` of the candidate `k`: a typed one cast to the parameter's type, resolved
	 * where the signature writes it (`Unification.casts`); `null` fits a parameter written `?p`; every other pair — an
	 * untyped argument, a parameter written with no type, with a type parameter of the signature, the member or its type, or
	 * with a type the cast graph does not model — may fit.
	 */
	private function fit(k: CallCandidate, arg: CallArgument, p: Int): ArgumentFit {
		final param: SignatureParam = k.signature.params[p];
		final written: Null<String> = param.type;
		return switch arg {
			case NullValue: param.form == Optional ? Fits : MayFit;
			case Untyped: MayFit;
			case Typed(given):
				final params: Array<String> = k.signature.typeParamNames.concat(k.member.typeParamNames);
				final wanted: TypeEnd = written == null ? Open : _casts.writtenEnd(written, k.host, k.signature.at, params);
				wanted.match(Open) || given.match(Open) ? MayFit : _unification.casts(given, wanted);
		};
	}

	/** Whether a call may leave the parameter `p` of `signature` out on every target: written `?p`, its value nullable. */
	public static inline function skipsSafely(signature: CallSignature, p: Int): Bool {
		return signature.params[p].form == Optional;
	}

	/**
	 * The candidate a call binds, given whether each compiles (`verdicts`, in the order the compiler tries them) under
	 * `kind`: for `Meta` and `Single` the first one that may compile, when it surely does or none after it may; for
	 * `Proper` the one that may, when it is the only one. Null otherwise.
	 */
	public static function chosen(kind: OverloadKind, verdicts: Array<ArgumentFit>): Null<Int> {
		final open: Array<Int> = [for (i in 0...verdicts.length) if (verdicts[i] != Misfits) i];
		if (open.length == 0) return null;
		if (kind == Proper) return open.length == 1 ? open[0] : null;
		return verdicts[open[0]] == Fits || open.length == 1 ? open[0] : null;
	}

	/** The slot model of `signature`'s parameters (`ArgumentSlots`): which a call may leave out, which takes the rest. */
	public static function slotsOf(signature: CallSignature): Array<SlotParam> {
		return [
			for (p in signature.params) { optional: p.form == Optional || p.form == Defaulted, rest: p.form == Rest }
		];
	}

}
