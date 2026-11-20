package anyparse.grammar.haxe;

import anyparse.core.Doc;
import anyparse.format.CommentEmptyLinesPolicy;
import anyparse.format.MemberGap;
import anyparse.grammar.haxe.trivia.Pairs.HxDeclT;
import anyparse.grammar.haxe.trivia.Pairs.HxModuleT;
import anyparse.query.GrammarPlugin.MemberGapHead;
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
	 * The projected container kinds written through a class-body Star: a class (plain, `final`, `abstract`) and an
	 * abstract all carry the global `afterFieldsWithDocComments`, `metadataCountsAsDocComment`,
	 * `beforeDocCommentEmptyLines` and `blankAroundMultilineMembers('aroundMultilineFields')`.
	 */
	private static final CLASS_KINDS: Array<String> = ['ClassDecl', 'ClassForm', 'AbstractClassDecl', 'AbstractDecl'];

	/**
	 * The policy under `opt`, with a per-slot memo of the multi-line measure. An `enum abstract` body reads its own
	 * `enumAbstract*` doc knobs (an unset after-policy falls back to the global one, as its Star does); under
	 * `enumAbstractRulesUnlessValueList` the set a body reads depends on the body, so that kind has no policy.
	 */
	public static function policy(opt: HxModuleWriteOptions): MemberGapPolicy {
		final measured: Map<String, Bool> = [];
		final unreadable: Array<String> = [];
		function multiline(slot: String): Null<Bool> {
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
		var classBody: Null<MemberGapPolicy> = null;
		var enumAbstractBody: Null<MemberGapPolicy> = null;
		function forKind(kind: String): Null<MemberGapPolicy> {
			return if (CLASS_KINDS.contains(kind))
				classBody
			else if (kind == 'EnumAbstractDecl' && !opt.enumAbstractRulesUnlessValueList)
				enumAbstractBody
			else
				null;
		}
		final cls: MemberGapPolicy = body(
			opt, opt.metadataCountsAsDocComment, opt.afterFieldsWithDocComments, opt.beforeCommentedFields, multiline, forKind
		);
		classBody = cls;
		enumAbstractBody = body(
			opt, opt.enumAbstractMetadataCountsAsDocComment, opt.enumAbstractAfterFieldsWithDocComments ?? opt.afterFieldsWithDocComments,
			opt.enumAbstractBeforeCommentedFields, multiline, forKind
		);
		return cls;
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

	/**
	 * One body kind's policy: the doc-led notion under `metaCountsAsDoc`, the after-doc policy `after` and the blank a
	 * line-comment heading asks for under `beforeCommented`.
	 */
	private static function body(
		opt: HxModuleWriteOptions, metaCountsAsDoc: Bool, after: CommentEmptyLinesPolicy, beforeCommented: Int,
		multiline: (slot: String) -> Null<Bool>, forKind: (kind: String) -> Null<MemberGapPolicy>
	): MemberGapPolicy {
		inline function docLed(head: MemberGapHead): Bool {
			return MemberGap.docLed(head.leading) || (metaCountsAsDoc && head.hasMeta);
		}
		inline function docGap(prev: MemberGapHead, next: MemberGapHead): DocGapVerdict {
			return MemberGap.headedGap(
				MemberGap.docGap(docLed(prev), docLed(next), after, opt.beforeDocCommentEmptyLines, MemberGap.docSplitLead(next.leading)),
				MemberGap.headingAdds(beforeCommented, next.leading)
			);
		}
		return {
			forKind: forKind,
			docBlanks: (prev, next) -> MemberGap.forcedBlanks(docGap(prev, next), false, opt.aroundMultilineFields),
			multilineBlanks: (prev, next) ->
				opt.aroundMultilineFields > 0 ? MemberGap.forcedBlanks(docGap(prev, next), true, opt.aroundMultilineFields) : null,
			multiline: multiline
		};
	}

}
