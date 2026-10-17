package anyparse.grammar.haxe;

import anyparse.core.Doc;
import anyparse.format.MemberGap;
import anyparse.grammar.haxe.trivia.Pairs.HxDeclT;
import anyparse.grammar.haxe.trivia.Pairs.HxModuleT;
import anyparse.query.GrammarPlugin.MemberGapPolicy;
import haxe.Exception;

/**
 * The Haxe writer's member-gap policy (`GrammarPlugin.memberGapPolicy`) under one set of write options: the
 * shared `MemberGap` predicates, fed what the class-body Star of `HxClassDecl` / `HxAbstractDecl` feeds them -
 * `afterFieldsWithDocComments`, `beforeDocCommentEmptyLines`, `aroundMultilineFields`, and each member's Doc as
 * `HaxeModuleTriviaWriter` builds it.
 */
@:nullSafety(Strict)
@:access(anyparse.grammar.haxe.HaxeModuleTriviaWriter)
final class HaxeMemberGap {

	/**
	 * The projected container kinds written through a member Star that carries the whole policy: a class (plain,
	 * `final`, `abstract`) and an abstract all carry `afterFieldsWithDocComments`, `beforeDocCommentEmptyLines` and
	 * `blankAroundMultilineMembers('aroundMultilineFields')`.
	 */
	private static final CONTAINER_KINDS: Array<String> = ['ClassDecl', 'ClassForm', 'AbstractClassDecl', 'AbstractDecl'];

	/** The policy under `opt`, with a per-slot memo of the multi-line measure. */
	public static function policy(opt: HxModuleWriteOptions): MemberGapPolicy {
		final measured: Map<String, Bool> = [];
		final unreadable: Array<String> = [];
		inline function docGap(prev: Array<String>, next: Array<String>): DocGapVerdict {
			return MemberGap.docGap(
				MemberGap.docLed(prev), MemberGap.docLed(next), opt.afterFieldsWithDocComments, opt.beforeDocCommentEmptyLines
			);
		}
		return {
			containerKinds: CONTAINER_KINDS,
			docBlanks: (prev, next) -> MemberGap.forcedBlanks(docGap(prev, next), false, opt.aroundMultilineFields),
			multilineBlanks: (prev, next) ->
				opt.aroundMultilineFields > 0 ? MemberGap.forcedBlanks(docGap(prev, next), true, opt.aroundMultilineFields) : null,
			multiline: slot -> {
				if (measured.exists(slot)) return measured[slot];
				if (unreadable.contains(slot)) return null;
				final doc: Null<Doc> = memberDoc(slot, opt);
				if (doc == null) {
					unreadable.push(slot);
					return null;
				}
				final multi: Bool = MemberGap.multiline(doc, opt);
				measured[slot] = multi;
				return multi;
			}
		};
	}

	/**
	 * The Doc the writer builds for the ONE member `slot` declares (its leading comments excluded, as the member
	 * Star measures it), read by parsing the slot as the sole member of a class; null when it does not parse as
	 * exactly one member.
	 */
	private static function memberDoc(slot: String, opt: HxModuleWriteOptions): Null<Doc> {
		final tree: Null<HxModuleT> =
			try HaxeModuleTriviaParser.parse('class MemberGapProbe {\n$slot\n}') catch (exception: Exception) null;
		if (tree == null || tree.decls.length != 1) return null;
		final decl: Null<HxDeclT> = tree.decls[0].node.decl;
		return switch decl {
			case ClassDecl(body) if (body.members.length == 1): HaxeModuleTriviaWriter.writeHxMemberDeclT(body.members[0].node, opt);
			case _: null;
		};
	}

}
