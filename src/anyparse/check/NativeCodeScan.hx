package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;

/**
 * Whether a node hands its text to the TARGET rather than to the Haxe typer: a call to a target
 * intrinsic (`__cpp__`, `__js__`, … — `StringFoldSupport.readsArgumentsAsSyntax`), a
 * `Syntax.code` / `Syntax.plainCode` call, or one of the `NATIVE_CODE_METAS`. Such text can name a
 * Haxe binding directly (`this->count`, `console.log(i)`), and neither the tree nor a masked text
 * scan sees it: the string argument is an inert literal to both. A check that deletes or renames a
 * binding must therefore read a carrier's RAW text for the name.
 */
@:nullSafety(Strict)
final class NativeCodeScan {

	/** The receiver the `NATIVE_SYNTAX_MEMBERS` hang off (`js.Syntax`, `python.Syntax`, `php.Syntax`, …). */
	private static inline final SYNTAX_RECEIVER: String = 'Syntax';

	/**
	 * The metadata whose argument is TARGET code pasted into the generated output — text the Haxe
	 * typer never reads, so a name it spells is invisible to a `--no-output` oracle.
	 */
	private static final NATIVE_CODE_METAS: Array<String> = [
		'@:functionCode',
		'@:functionTailCode',
		'@:cppFileCode',
		'@:headerClassCode',
		'@:headerCode',
		'@:cppNamespaceCode'
	];

	/** The `Syntax` members that paste their string argument into the generated output as target code. */
	private static final NATIVE_SYNTAX_MEMBERS: Array<String> = ['code', 'plainCode'];

	/** Whether `node` is a native-code carrier (see the type doc); `fold` names the target intrinsics, null when the grammar has none. */
	public static function isCarrier(node: QueryNode, shape: RefShape, fold: Null<StringFoldSupport>): Bool {
		final name: Null<String> = node.name;
		if (MemberKinds.META_KINDS.contains(node.kind)) return name != null && NATIVE_CODE_METAS.contains(name);
		if (node.kind != shape.callKind || node.children.length == 0) return false;
		final callee: QueryNode = node.children[0];
		final calleeName: Null<String> = callee.name;
		if (calleeName == null) return false;
		if (callee.kind == shape.identKind) return fold?.readsArgumentsAsSyntax(calleeName) == true;
		final receiver: Null<QueryNode> = callee.children.length > 0 ? callee.children[0] : null;
		return callee.kind == shape.fieldAccessKind && NATIVE_SYNTAX_MEMBERS.contains(calleeName) && receiver?.name == SYNTAX_RECEIVER;
	}

}
