package anyparse.check.common.literals;

import anyparse.query.MemberKinds;

/**
 * The one answer to "which children of a node are declarations whose initialiser the compiler reads as a constant": a
 * member behind an `inline` modifier, and a value member of an enum abstract. A `case` pattern or a metadata argument may
 * name such a constant, and a concatenation written in its place is no constant there.
 *
 * Decided from the node's kinds and its modifier / annotation children, never from source text.
 */
@:nullSafety(Strict)
final class ConstantReadSlots {

	/**
	 * `node`'s children classified in order. A modifier or annotation child is `declaration == false`; any other child
	 * is a declaration, `constant` when its initialiser is read as one, and `constantMembers` says whether its own
	 * members are constant-read in turn (an enum abstract, a conditional region inside one). `constantMembers` is the
	 * answer already given for `node` itself.
	 */
	public static function of(node: QueryNode, constantMembers: Bool, seams: ConstantSeams): Array<ChildSlot> {
		final slots: Array<ChildSlot> = [];
		final metaName: Null<String> = seams.enumAbstractMetaName;
		var runInline: Bool = false;
		var runEnumMeta: Bool = false;
		for (c in node.children) {
			if (seams.modifierKinds.contains(c.kind)) {
				if (c.kind == seams.inlineKind) runInline = true;
				slots.push({ declaration: false, constant: false, constantMembers: false });
				continue;
			}
			if (seams.metaKinds.contains(c.kind)) {
				if (metaName != null && c.name == metaName) runEnumMeta = true;
				slots.push({ declaration: false, constant: false, constantMembers: false });
				continue;
			}
			// EVERY other child ends the run — a member, a nested type, a statement. Ending it only at a MEMBER left
			// `@:enum abstract E {…}` marking every LATER declaration in the module as an enum abstract.
			final fn: Bool = seams.functionKinds.contains(c.kind);
			// `runInline` is not asked whether the declaration is a MEMBER: a module-level `inline final S = …`
			// projects as a top-level declaration, and its value is the same compile-time constant.
			slots.push({
				declaration: true,
				constant: (constantMembers && !fn && MemberKinds.isMemberDeclNode(c)) || (runInline && !fn),
				constantMembers: c.kind == seams.enumAbstractDeclKind || runEnumMeta || (constantMembers && c.kind == seams.conditionalKind)
			});
			runInline = false;
			runEnumMeta = false;
		}
		return slots;
	}

}

/** The kinds `ConstantReadSlots` reads off a grammar's shape. */
typedef ConstantSeams = {
	final modifierKinds: Array<String>;
	final inlineKind: Null<String>;
	final metaKinds: Array<String>;
	final enumAbstractMetaName: Null<String>;
	final enumAbstractDeclKind: Null<String>;
	final conditionalKind: Null<String>;
	final functionKinds: Array<String>;
};

/** One child of a node, as `ConstantReadSlots.of` classifies it. */
typedef ChildSlot = { final declaration: Bool; final constant: Bool; final constantMembers: Bool; };
