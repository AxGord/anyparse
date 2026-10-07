package anyparse.query;

import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
using StringTools;

/** One declared arm handed to `MutationSchema.compose`: its run id, its address and the whole file with its cut applied. */
typedef SchemaArm = {
	id: Int,
	select: String,
	mutated: String
};

/**
 * Where `compose` put one arm in the composed text, or why it left the arm out (`skip` non-null, the line fields 0, `owner` empty).
 * Lines are 1-based: `dispatch` is the line the arm's switch landed on, `copyFrom`..`copyTo` the lines of its copy.
 */
typedef SchemaPlacement = {
	id: Int,
	skip: Null<String>,
	dispatch: Int,
	copyFrom: Int,
	copyTo: Int,

	/** The type that holds the copy and the switch; empty when the arm is left out. */
	owner: String
};

/** One composed file: its text, and one placement per arm. */
typedef SchemaFile = {
	text: String,
	placements: Array<SchemaPlacement>
};

/** One text insertion into the original source, owned by one arm. */
private typedef SchemaInsert = {
	at: Int,
	text: String,
	id: Int,
	role: SchemaRole
};

/** What one insertion is: an arm's switch line, an arm's copy, or a type's switch fields (owned by no arm). */
private enum SchemaRole {
	Dispatch;
	Copy;
	Switch;
}

/**
 * Mutant schemata for `tools/mutation-arm.sh`: every arm of one file compiled into ONE build behind a run-time
 * switch, so a sweep compiles once instead of once per arm.
 *
 * An arm's cut stays the `hxq patch` it always was; what this adds is where its result goes. The arm's whole mutated
 * method is copied in beside the original as `__mut<id>_<name>`, and the original's body opens with
 * `if (__mutOn(<id>)) return __mut<id>_<name>(<args>);`. With `APQ_MUTANT=<id>` in the environment the
 * method IS the mutated one — recursion and method values go through the switch as well — and with any other value
 * the switch is a comparison that fails. `__mutOn` is a private static method of the type itself, so a module
 * whose text the build embeds and a child compiler re-compiles (the facts macro) carries its switch along.
 *
 * Only the dispatch is spliced into a line the original already has (right after the body's `{`), and a copy and the switch
 * go in just before the closing brace of their type, so every original line keeps its number — a position the compiler
 * hands back for the original code is the one the per-arm build reports. A method inside a `#if` region is copied
 * right after itself instead, in the same region, which does move the lines below it.
 *
 * A method is left out, with the reason, where a copy cannot stand for it: a constructor, a `macro` / `extern` /
 * `overload` method, a body that is not a block, and a cut that reached outside the method's own text. Whatever is
 * left out is built per arm, as before. That the composed build still means the per-arm build in every other way —
 * nothing executes a switch at compile time, nothing reads the composed text — is the caller's to check: both are
 * answered by the build itself (`tools/mutation-arm.sh`).
 */
@:nullSafety(Strict)
final class MutationSchema {

	/** The switch every type holding a copy carries, as a private static method. */
	public static inline final SWITCH: String = '__mutOn';

	/** The environment variable naming the active arm id. */
	public static inline final ACTIVE_VAR: String = 'APQ_MUTANT';

	/** The environment variable naming the file a switch reached at COMPILE time records its id in. */
	public static inline final MACRO_LOG_VAR: String = 'APQ_MUTANT_MACRO_LOG';

	/** The prefix of a copy's name: `__mut<id>_<name>`. */
	private static inline final COPY_PREFIX: String = '__mut';

	/**
	 * The switch fields, inserted before the closing brace of every type that holds a copy. The switch reads
	 * `APQ_MUTANT` once, on first use, so a static initializer that calls a switched method before the type's own
	 * statics ran still sees the active arm. Compiled into a macro, it records each id it is asked about in
	 * `APQ_MUTANT_MACRO_LOG`: a switch reached at compile time is a method whose cut could have changed what the build
	 * generated, which only a per-arm build answers. The switch is public so a `--macro` call can type
	 * its type (and every copy in it) in the macro context, which is how `tools/mutation-arm.sh` checks
	 * a module the build embeds as text. Fields of the type and not a class of their own: a module whose
	 * types are all behind `#if macro` must still contribute no type to a build that is not one.
	 */
	private static final SWITCH_FIELDS: String = '\n\tprivate static var __mutActive: Null<Int>;\n' + '\t#if macro\n'
		+ '\tprivate static var __mutReached: Null<Array<Int>>;\n' + '\t#end\n\n' + '\tpublic static function $SWITCH(id: Int): Bool {\n'
		+ '\t\tvar active: Null<Int> = __mutActive;\n' + '\t\tif (active == null) {\n'
		+ '\t\t\tfinal raw: Null<String> = Sys.getEnv(\'$ACTIVE_VAR\');\n' + '\t\t\tactive = raw == null ? 0 : Std.parseInt(raw) ?? 0;\n'
		+ '\t\t\t__mutActive = active;\n' + '\t\t}\n' + '\t\t#if macro\n'
		+ '\t\tfinal log: Null<String> = Sys.getEnv(\'$MACRO_LOG_VAR\');\n' + '\t\tfinal reached: Array<Int> = __mutReached ?? [];\n'
		+ '\t\t__mutReached = reached;\n' + '\t\tif (log != null && !reached.contains(id)) {\n' + '\t\t\treached.push(id);\n'
		+ '\t\t\tfinal out: sys.io.FileOutput = sys.io.File.append(log);\n' + '\t\t\tout.writeString(\'$$id\\n\');\n'
		+ '\t\t\tout.close();\n' + '\t\t}\n' + '\t\t#end\n' + '\t\treturn active == id;\n' + '\t}\n';

	/** The modifiers a copy keeps (`Override` is dropped: the copy overrides nothing). */
	private static final KEPT_MODIFIERS: Array<String> = ['Public', 'Private', 'Static', 'Inline', 'Dynamic', 'Final'];

	/** The modifiers that leave the arm out: a copy cannot stand for a macro, an extern or an overload. */
	private static final REFUSED_MODIFIERS: Array<String> = ['Macro', 'Extern', 'Overload'];

	/** The metadata a copy drops: each would declare the copy a second operator, cast, accessor or native name. */
	private static final DROPPED_METAS: Array<String> = [
		'@:op',
		'@:from',
		'@:to',
		'@:arrayAccess',
		'@:resolve',
		'@:native',
		'@:expose',
		'@:overload'
	];

	/** The kinds of a method's parameters, in the order the call forwards them; a `Rest` is spread. */
	private static final PARAM_KINDS: Array<String> = ['Required', 'Optional', 'Rest'];

	/** The member kinds a type body lists its methods among; a method under any other parent is inside a `#if`. */
	private static final TYPE_KINDS: Array<String> = ['ClassDecl', 'ClassForm', 'AbstractDecl', 'EnumAbstractDecl'];

	/**
	 * `source` with every arm of `arms` that a copy can stand for composed in, and one placement per arm in `arms`
	 * order. `tree` is `source` parsed by `plugin`.
	 */
	public static function compose(source: String, tree: QueryNode, plugin: GrammarPlugin, arms: Array<SchemaArm>): SchemaFile {
		final inserts: Array<SchemaInsert> = [];
		final skips: Map<Int, String> = [];
		final switchAt: Map<Int, Int> = [];
		final owners: Map<Int, String> = [];
		for (arm in arms) {
			final reason: Null<String> =
				try plan(source, tree, plugin, arm, inserts, switchAt, owners) catch (exception: Exception) exception.message;
			if (reason != null) skips[arm.id] = reason;
		}
		final ordered: Array<SchemaInsert> = inserts.filter(insert -> !skips.exists(insert.id));
		// one set of switch fields per type, after every copy that type receives at the same offset
		final typed: Array<Int> = [];
		for (arm in arms) {
			final offset: Int = switchAt[arm.id] ?? -1;
			if (offset >= 0 && !skips.exists(arm.id) && !typed.contains(offset)) {
				typed.push(offset);
				ordered.push({
					at: offset,
					text: SWITCH_FIELDS,
					id: 0,
					role: Switch
				});
			}
		}
		// stable: two inserts at one offset keep the order they were pushed in
		haxe.ds.ArraySort.sort(ordered, (a, b) -> a.at - b.at);
		final out: StringBuf = new StringBuf();
		final spans: Map<Int, { dispatch: Int, copyFrom: Int, copyTo: Int }> = [];
		var done: Int = 0;
		var line: Int = 1;
		for (insert in ordered) {
			final kept: String = source.substring(done, insert.at);
			out.add(kept);
			line += lines(kept);
			final at: { dispatch: Int, copyFrom: Int, copyTo: Int } = spans[insert.id] ?? { dispatch: 0, copyFrom: 0, copyTo: 0 };
			switch insert.role {
				case Dispatch:
					at.dispatch = line;
				case Copy:
					at.copyFrom = line + 1;
					// the copy sits between the insert's leading and trailing line breaks
					at.copyTo = line + lines(insert.text) - 1;
				case Switch:
			}
			spans[insert.id] = at;
			out.add(insert.text);
			line += lines(insert.text);
			done = insert.at;
		}
		out.add(source.substring(done));
		return {
			text: out.toString(),
			placements: [
				for (arm in arms) {
					final at: { dispatch: Int, copyFrom: Int, copyTo: Int } = spans[arm.id] ?? { dispatch: 0, copyFrom: 0, copyTo: 0 };
					{
						id: arm.id,
						skip: skips[arm.id],
						dispatch: at.dispatch,
						copyFrom: at.copyFrom,
						copyTo: at.copyTo,
						owner: skips.exists(arm.id) ? '' : owners[arm.id] ?? ''
					};
				}
			]
		};
	}

	/**
	 * The two inserts of `arm` pushed onto `inserts`, and the offset its type's switch fields go at into `switchAt`, or
	 * why the arm is left out.
	 */
	private static function plan(
		source: String, tree: QueryNode, plugin: GrammarPlugin, arm: SchemaArm, inserts: Array<SchemaInsert>, switchAt: Map<Int, Int>,
		owners: Map<Int, String>
	): Null<String> {
		final member: QueryNode = switch Address.resolve(tree, source, plugin, { select: arm.select }) {
			case Ok(_, node) if (node != null): node;
			case Ok(_, _): return 'the address resolved no node';
			case Err(message): return message;
		};
		final name: Null<String> = member.name;
		final span: Null<Span> = member.span;
		if (member.kind != 'FnMember' || name == null || span == null) return 'a ${member.kind}, not a method';
		if (name == 'new') return 'a constructor';
		final body: Null<QueryNode> = member.children.find(child -> child.kind == 'BlockBody');
		final bodySpan: Null<Span> = body?.span;
		if (bodySpan == null || source.charAt(bodySpan.from) != '{') return 'its body is not a block';
		final parent: Null<QueryNode> = parentOf(tree, member);
		if (parent == null) return 'no enclosing type';
		final modifiers: Array<QueryNode> = modifiersOf(parent, member);
		for (modifier in modifiers) if (REFUSED_MODIFIERS.contains(modifier.kind)) return 'a ${modifier.kind.toLowerCase()} method';
		// the type the switch fields go into: the parent, or the type around the `#if` the method sits in
		var owner: Null<QueryNode> = parent;
		while (owner != null && !TYPE_KINDS.contains(owner.kind)) owner = parentOf(tree, owner);
		final closing: Int = closingBrace(source, owner);
		if (closing < span.to) return 'no type body to hold the switch';

		// The cut is an `hxq patch` of this member, so outside the member the mutated file is the original.
		final tail: Int = source.length - span.to;
		if (
			!arm.mutated.startsWith(source.substring(0, span.from)) || !arm.mutated.endsWith(source.substring(span.to))
			|| arm.mutated.length < span.from + tail
		)
			return 'the cut reached outside the method';
		final mutated: String = arm.mutated.substring(span.from, arm.mutated.length - tail);
		final head: EReg = ~/^function(\s+)([A-Za-z_][A-Za-z0-9_]*)/;
		if (!head.match(mutated) || head.matched(2) != name) return 'the mutated method does not open with `function $name`';
		final copyName: String = '$COPY_PREFIX${arm.id}_$name';
		final kept: Array<String> = [
			for (modifier in modifiers) if (keeps(modifier)) source.substring(modifier.span?.from ?? 0, modifier.span?.to ?? 0)
		];
		final copy: String = kept.concat(['function${head.matched(1)}$copyName${mutated.substr(head.matchedPos().len)}']).join(' ');
		final args: Array<String> = [
			for (child in member.children) if (PARAM_KINDS.contains(child.kind)) (child.kind == 'Rest' ? '...' : '') + (child.name ?? '')
		];
		inserts.push({
			at: bodySpan.from + 1,
			text: ' if ($SWITCH(${arm.id})) return $copyName(${args.join(', ')});',
			id: arm.id,
			role: Dispatch
		});
		inserts.push({
			at: parent == owner ? closing : span.to,
			text: '\n\t$copy\n',
			id: arm.id,
			role: Copy
		});
		switchAt[arm.id] = closing;
		owners[arm.id] = owner?.name ?? '';
		return null;
	}

	/** Whether a copy keeps `modifier`. */
	private static function keeps(modifier: QueryNode): Bool {
		return if (modifier.kind == 'Meta' || modifier.kind == 'MetaCall')
			!DROPPED_METAS.contains(modifier.name ?? '')
		else
			KEPT_MODIFIERS.contains(modifier.kind);
	}

	/** The modifiers and metadata right before `member` among `parent`'s children, in source order. */
	private static function modifiersOf(parent: QueryNode, member: QueryNode): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		var i: Int = parent.children.indexOf(member) - 1;
		while (i >= 0) {
			final sibling: QueryNode = parent.children[i];
			final modifier: Bool = sibling.kind == 'Meta' || sibling.kind == 'MetaCall' || sibling.kind == 'Override'
				|| KEPT_MODIFIERS.contains(sibling.kind) || REFUSED_MODIFIERS.contains(sibling.kind);
			if (!modifier || sibling.span == null) break;
			out.unshift(sibling);
			i--;
		}
		return out;
	}

	/** The node whose children hold `node`, or null. */
	private static function parentOf(tree: QueryNode, node: QueryNode): Null<QueryNode> {
		if (tree.children.contains(node)) return tree;
		for (child in tree.children) {
			final found: Null<QueryNode> = parentOf(child, node);
			if (found != null) return found;
		}
		return null;
	}

	/** The offset of `type`'s closing brace, or -1 when it has none where its span ends. */
	private static function closingBrace(source: String, type: Null<QueryNode>): Int {
		final span: Null<Span> = type?.span;
		return span != null && span.to > 0 && source.charAt(span.to - 1) == '}' ? span.to - 1 : -1;
	}

	/** How many line breaks `text` holds. */
	private static function lines(text: String): Int {
		return text.split('\n').length - 1;
	}

}
