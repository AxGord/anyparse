package anyparse.macro;

#if macro
import anyparse.core.ShapeTree.ShapeKind;
import anyparse.core.ShapeTree.ShapeNode;
import haxe.macro.Context;

/**
 * The one answer to "can a sibling slot reach the renderer undecided".
 *
 * `anyparse.format.SiblingShare.decide` resolves every slot in the Doc of a `@:trivia` Star declaring
 * `siblingShare`, a region nested in that Star included, and nothing else resolves one. So the walk from the
 * writer's root stops at those Stars, and a slot it still reaches would ship unresolved: some walkers read an
 * unresolved slot's break side, which is why this is a build error and not a layout surprise.
 */
final class SiblingScope {

	private static final SLOT_FLAGS: Array<String> = ['siblingSlot', 'siblingLead'];

	/** Stops the build when a slot of any knob is reachable from the root outside a list sharing that knob. */
	public static function requireShared(shape: ShapeBuilder.ShapeResult): Void {
		final root: Null<ShapeNode> = shape.rules[shape.root];
		if (root == null) return;
		final knobs: Map<String, Bool> = [];
		for (rule in shape.rules) collectKnobs(rule, knobs);
		for (knob in knobs.keys()) {
			final path: Null<Array<String>> = unsharedPath(root, knob, shape.rules, [shape.root => true], [simpleName(shape.root)]);
			if (path != null)
				Context.fatalError(
					'WriterLowering: a sibling slot of knob "$knob" at ${path.join('.')} is outside every list declaring '
					+ '@:fmt(siblingShare(\'$knob\')), so nothing resolves it',
					Context.currentPos()
				);
		}
	}

	private static function collectKnobs(node: ShapeNode, knobs: Map<String, Bool>): Void {
		for (flag in SLOT_FLAGS) {
			final knob: Null<String> = MetaInspect.fmtReadString(node, flag);
			if (knob != null) knobs[knob] = true;
		}
		for (child in node.children) collectKnobs(child, knobs);
	}

	/** The way down from `node` to a slot of `knob` no sharing list holds, or null. Every rule is entered once. */
	private static function unsharedPath(
		node: ShapeNode, knob: String, rules: Map<String, ShapeNode>, entered: Map<String, Bool>, path: Array<String>
	): Null<Array<String>> {
		if (node.kind == ShapeKind.Star && MetaInspect.hasMeta(node, ':trivia') && MetaInspect.fmtReadString(node, 'siblingShare') == knob)
			return null;
		for (flag in SLOT_FLAGS) if (MetaInspect.fmtReadString(node, flag) == knob) return path;
		for (child in node.children) {
			final found: Null<Array<String>> = unsharedPath(child, knob, rules, entered, path.concat(step(child)));
			if (found != null) return found;
		}
		final ref: Null<String> = node.annotations[AnnotationKeys.BASE_REF];
		if (ref == null || entered.exists(ref)) return null;
		final rule: Null<ShapeNode> = rules[ref];
		if (rule == null) return null;
		entered[ref] = true;
		return unsharedPath(rule, knob, rules, entered, path.concat([simpleName(ref)]));
	}

	private static function step(child: ShapeNode): Array<String> {
		final ctor: Null<String> = child.annotations[AnnotationKeys.BASE_CTOR];
		final field: Null<String> = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		return if (ctor != null)
			[ctor]
		else if (field != null)
			[field]
		else
			[];
	}

	private static function simpleName(typePath: String): String {
		return typePath.substr(typePath.lastIndexOf('.') + 1);
	}

}
#end
