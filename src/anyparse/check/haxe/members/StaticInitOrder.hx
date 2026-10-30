package anyparse.check.haxe.members;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.NoAutofix;
import anyparse.check.common.members.MemberInitDeps;
import anyparse.check.common.members.MemberSlots;
import anyparse.check.scan.RunScan;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.SymbolIndex;

/**
 * Flags a static field initializer that reads a static field of the same type declared BELOW it. Haxe runs static
 * initializers in declaration order, so the read sees the later field before its own initializer ran: `null` on the
 * interpreter, `undefined` on js, the type's zero on a static target — even for a non-inline `static final` constant.
 *
 * A read inside a function literal runs when the function is called and is left alone, as is a read of an `inline`
 * field (folded at compile time) or of a field with no initializer (no order to violate). A read is a binding, not a
 * word (`MemberInitDeps.firstEarlyRead`): a string, a comment, an object-literal key or another type's member reads
 * nothing, and the finding names the field actually read.
 */
@:nullSafety(Strict)
final class StaticInitOrder extends HaxeRule implements NoAutofix {

	private static inline final RULE_ID: String = 'static-init-order';

	public function new() {
		super(
			RULE_ID,
			'a static field initializer reading a static field declared below it, which is not initialized yet when the read runs',
			RuleCategory.Members
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final containers: Array<String> = shape.visibilityContainerKinds ?? [];
		final deferred: Array<String> = (shape.lambdaKinds ?? []).concat([for (k in [shape.namedFnExprKind]) if (k != null) k]);
		return RunScan.collect(files, plugin, (entry, tree, out) -> {
			final reported: Map<Int, Bool> = [];
			final regions: Array<LexRegion> = plugin.lexicalRegions(entry.source);
			function walk(node: QueryNode, typeName: Null<String>): Void {
				final container: Bool = containers.contains(node.kind);
				final owner: Null<String> = container ? node.name ?? typeName : typeName;
				final members: Array<OrderedMember> = container ? MemberSlots.collectMembers(node, entry.source, shape, [], regions) : [];
				for (m in members) {
					final span: Null<Span> = m.initNode?.span;
					if (span == null || !m.isStatic || reported.exists(span.from)) continue;
					final read: Null<OrderedMember> = MemberInitDeps.firstEarlyRead(m, members, owner, tree, shape, deferred);
					if (read == null) continue;
					reported[span.from] = true;
					out.push({
						file: entry.file,
						span: span,
						rule: RULE_ID,
						severity: Severity.Warning,
						message: 'reads `${read.node.name}` before its initializer runs: statics initialize in declaration order'
					});
				}
				for (c in node.children) walk(c, owner);
			}
			walk(tree, null);
		});
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	public function noAutofixReason(): String {
		return 'moving the read field above the reader can break member order or another initializer that reads it, and'
			+ ' which declaration should move is a human call';
	}

}
