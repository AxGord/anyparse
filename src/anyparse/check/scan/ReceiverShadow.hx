package anyparse.check.scan;

import anyparse.query.MemberLookup;
import anyparse.query.NominalTypes;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;

/** What the receiver's own type says about spelling a static function as an extension call on it. */
enum abstract ReceiverVerdict(Int) {

	/** The type provably has no member of the method's name: an extension call binds the static function. */
	final Free = 0;

	/** The type or a supertype declares a member of that name; an instance member wins over a static extension. */
	final Shadowed = 1;

	/** The receiver is `Dynamic`: the extension call compiles and dispatches nothing at run time. */
	final DynamicReceiver = 2;

	/** The receiver's type is not resolved, or no index is at hand. */
	final UnresolvedReceiver = 3;

	/** The type's member closure is not readable (a supertype outside the index, an alias, a `@:forward` abstract, `@:using`). */
	final UnresolvedClosure = 4;

}

/** One file's receiver-typing context, built once and asked for every receiver of the file. */
typedef ReceiverTyping = {
	final shape: RefShape;
	final root: QueryNode;
	final file: String;
	final symbols: () -> Null<SymbolIndex>;
	final declaredTypes: Map<Int, String>;
	final chain: ChainTypeContext;
}

/** A receiver's resolved nominal type (null when unresolved) and what it says about the method. */
typedef ReceiverJudgement = { final nominal: Null<String>; final verdict: ReceiverVerdict; }

/**
 * The one answer to "may this call be spelled `recv.member(…)` — does the receiver's own type already declare `member`".
 *
 * Haxe binds an instance member before a static extension, so `Lambda.map(arr, f)` → `arr.map(f)` silently calls
 * `Array.map` where the type declares the name. The receiver's nominal type is read through the deep mode of
 * `NominalTypes.expressionTypeNominal`, behind a kind whitelist — identifier, field path, call, string literal — which is also
 * what makes the spliced receiver postfix-safe: no other expression ever resolves, so none needs parentheses. Every
 * rule that spells an extension call (`prefer-static-extension`, `prefer-helper`) asks here.
 */
final class ReceiverShadow {

	/** The typing context of `file`: the declared types and the chain context are built once per file. */
	public static function typingOf(
		typed: TypeInfoProvider, plugin: GrammarPlugin, root: QueryNode, source: String, file: String, symbols: () -> Null<SymbolIndex>
	): ReceiverTyping {
		return {
			shape: plugin.refShape(),
			root: root,
			file: file,
			symbols: symbols,
			declaredTypes: typed.declaredTypes(source),
			chain: { declaredTypeSources: typed.declaredTypeSources(source), source: source, typeSyntax: plugin.typeSyntax }
		};
	}

	/** What `recv`'s type says about a call of `method` at byte `at` spelled as an extension. */
	public static function judge(recv: QueryNode, method: String, typing: ReceiverTyping, at: Int): ReceiverJudgement {
		final nominal: Null<String> = nominalOf(recv, typing);
		final isDynamic: Bool = nominal != null && nominal == typing.shape.rawDynamicTypeName;
		return { nominal: nominal, verdict: isDynamic ? ReceiverVerdict.DynamicReceiver : verdictFor(nominal, method, typing, at) };
	}

	private static function verdictFor(nominal: Null<String>, method: String, typing: ReceiverTyping, at: Int): ReceiverVerdict {
		final resolved: Null<SymbolIndex> = typing.symbols();
		if (nominal == null || resolved == null) return ReceiverVerdict.UnresolvedReceiver;
		final receiverType: String = nominal;
		final members: MemberLookup = resolved.typing.members;
		return if (members.memberShadowsExtension(receiverType, method))
			ReceiverVerdict.Shadowed
		else if (
			members.typeProvablyLacksMember(receiverType, method, typing.file, at)
			&& members.closureFreeOfExtensionTypes(receiverType, typing.file, at)
		)
			ReceiverVerdict.Free
		else
			ReceiverVerdict.UnresolvedClosure;
	}

	private static function nominalOf(recv: QueryNode, typing: ReceiverTyping): Null<String> {
		final shape: RefShape = typing.shape;
		if (
			!(shape.stringLiteralKinds ?? []).contains(recv.kind)
			&& recv.kind != shape.identKind && recv.kind != shape.fieldAccessKind && recv.kind != shape.callKind
		)
			return null;
		final selfText: Null<String> = shape.selfReferenceText;
		final span: Null<Span> = recv.span;
		// a bare `this` outside an abstract body stays unresolved (the type doc); inside one it is the underlying value
		if (recv.kind == shape.identKind && selfText != null && recv.name == selfText) {
			final decl: Null<TypeDeclMatch> = span == null ? null : TypeResolver.enclosingTypeDecl(typing.root, span);
			if (decl == null || !(shape.underlyingThisTypeKinds ?? []).contains(decl.kind)) return null;
		}
		final nominal: Null<String> = NominalTypes.expressionTypeNominal(
			recv, typing.root, shape, typing.declaredTypes, typing.symbols(), typing.file, typing.chain
		);
		// `Dynamic` is answered as itself (the caller drops it) before any nullable wrapper it may also be listed as
		return nominal != null && nominal != shape.rawDynamicTypeName && (shape.nullableWrapperTypeNames ?? []).contains(nominal)
			? null
			: nominal;
	}

}
