package dev;

import anyparse.query.ArmTypePath;
import anyparse.query.format.json.CodeGraphJson;
import dev.ArmRegistry.ArmRecord;
import dev.GateArms.ModuleTouch;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.Summary;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using anyparse.util.Groups;
using Lambda;
using StringTools;

/**
 * The one answer to "does a test, a declared arm or a pinned caller reach each function the slice added or changed": the slice
 * gate's `reach` row. A function is reached when a test file names its type and it, an arm cuts it, or a chain of callers (the
 * calls graph, `DEPTH` levels) ends in a function that is either; a private helper of a pinned member is therefore reached
 * through it. A function with none is red until the worker's `reach-exempt.md` names it with a reason. Constructors, fields
 * and types are not read, and a file whose changed functions `hxq changed` cannot name is not read unless it is new.
 */
@:nullSafety(Strict)
final class ReachRow {

	/** The levels of callers a chain climbs from a function before it gives up. */
	public static inline final DEPTH: Int = 4;

	/** The worker's declaration, in the slice's logs directory: one `<Type.function or Type> — <why>` line per function or group. */
	public static final DECLARATION: String = 'reach-exempt.md';

	/** What the gate leaves in its own logs: every function with no reach, one name per line. */
	public static final LIST: String = 'reach-open.txt';

	/** The names the row prints before it counts the rest. */
	private static inline final LISTED: Int = 8;

	/** The group of an outline row that holds the declaration's name. */
	private static inline final NAME_GROUP: Int = 3;

	/** The roots whose functions the row reads: tests and the test kit are what reaches them. */
	private static final SOURCE_ROOTS: Array<String> = ['src/', 'tools/src/'];

	/** The one edge kind that is no call: a type holding a member. */
	private static final CONTAINS: String = 'contains';

	/**
	 * The outline row of a declaration: its indent, kind and name. A name its file declares twice is addressed through its type
	 * (`ClassForm:T >> FnMember:new`), and the last step is the row's own.
	 */
	private static final OUTLINE_ROW: EReg = ~/^\d+-\d+  ( *)(?:\S+ >> )*(\w+):(\S+)/;

	private static final TYPE_KINDS: Array<String> = ['ClassForm', 'ClassDecl', 'InterfaceDecl', 'AbstractDecl'];
	private static final CONSTRUCTOR: String = 'new';

	/** The name of an entry point: a word every test file holds, so naming it says nothing of the type that declares it. */
	private static final ENTRY_POINT: String = 'main';

	/** Whether the slice changed a source file the row reads. */
	public static function reached(touched: Array<String>): Bool {
		return touched.exists(file -> file.endsWith('.hx') && SOURCE_ROOTS.exists(root -> file.startsWith(root)));
	}

	/**
	 * The functions the `.hx` outline `text` of module `module` holds, as `hxq graph` names them (`<type>.<function>`): the
	 * main type's own, and those of a type declared beside it. Constructors are left out.
	 */
	public static function functionsOf(text: String, module: String): Array<String> {
		final names: Array<String> = [];
		final simple: String = module.substring(module.lastIndexOf('.') + 1);
		final owners: Array<String> = [];
		for (line in text.split('\n')) if (OUTLINE_ROW.match(line)) {
			final depth: Int = OUTLINE_ROW.matched(1).length;
			final kind: String = OUTLINE_ROW.matched(2);
			final name: String = OUTLINE_ROW.matched(NAME_GROUP);
			while (owners.length > depth) owners.pop();
			if (TYPE_KINDS.contains(kind)) {
				while (owners.length < depth) owners.push('');
				owners.push(name == simple ? module : '$module.$name');
			} else if (kind == 'FnMember' && name != CONSTRUCTOR && owners.length > 0) {
				names.push(ArmTypePath.graphMember(owners[owners.length - 1], name));
			}
		}
		return names;
	}

	/**
	 * The functions of `functions` a slice changed in `touch`: those its report names, or every one when the module is new
	 * (`fresh`); none when the report cannot name them of a module that was there.
	 */
	public static function seedsOf(touch: ModuleTouch, functions: Array<String>, fresh: Bool): Array<String> {
		final members: Null<Array<String>> = touch.members;
		return if (members != null)
			functions.filter(name -> members.contains(name.substring(name.lastIndexOf('.') + 1)))
		else if (fresh)
			functions
		else
			[];
	}

	/** The graph names of the functions the arms of `records` cut. */
	public static function armed(records: Array<ArmRecord>): Array<String> {
		return [ for (record in records) for (cut in [GateArms.cutOf(record)]) if (cut != null) cut ];
	}

	/** The callers of each function of a calls graph, by name: the members at the other end of an edge that is a call. */
	public static function callersOf(graph: CodeGraphJson): Map<String, Array<String>> {
		final names: Map<String, String> = [ for (node in graph.nodes) if (node.level == 'member') node.id => node.name ];
		final callers: Map<String, Array<String>> = [];
		for (edge in graph.edges) {
			final from: Null<String> = names[edge.from];
			final to: Null<String> = names[edge.to];
			if (from == null || to == null || edge.kind == CONTAINS || from == to) continue;
			final known: Array<String> = callers[to] ?? [];
			known.pushUnique(from);
			callers[to] = known;
		}
		return callers;
	}

	/**
	 * The `seeds` no chain reaches: a seed is reached when it, or a function that calls it, directly or `depth` levels up, is
	 * `direct` (a test names it, an arm cuts it).
	 */
	public static function open(
		seeds: Array<String>, direct: String -> Bool, callers: Map<String, Array<String>>, depth: Int
	): Array<String> {
		return seeds.filter(seed -> !climbs(seed, direct, callers, depth));
	}

	/** Whether the declared `exempt` name covers `seed`: it is, or begins, or ends, a run of the seed's dotted segments. */
	public static function covers(name: String, seed: String): Bool {
		return '.$seed.'.indexOf('.$name.') >= 0;
	}

	/** The verdict on the `open` functions against the `exempt` names the worker declared. */
	public static function verdict(open: Array<String>, exempt: Array<String>): Outcome {
		final red: Array<String> = open.filter(seed -> !exempt.exists(name -> covers(name, seed)));
		if (red.length == 0) return Passed;
		final shown: String = red.slice(0, LISTED).join(', ') + (red.length > LISTED ? ', … ${red.length - LISTED} more' : '');
		return Failed(
			'${red.length} changed functions no test, arm or pinned caller reaches: $shown — pin them, or name each in $DECLARATION'
			+ ' as `<Type.function> — <why>`'
		);
	}

	/** The declaration the worker writes, in the directory above the gate's logs (`<worktree>-logs`). */
	public static function declaration(logs: String): String {
		return Path.join([Path.directory(Path.removeTrailingSlashes(logs)), DECLARATION]);
	}

	/**
	 * Whether a test file of `tree` names both the type and the function of the graph name `member`, as whole words: the
	 * cheap stand-in for a call the graph could not resolve. An entry point `main` is never named, whatever the files hold.
	 */
	public static function named(tree: String, member: String): Bool {
		final at: Int = member.lastIndexOf('.');
		final owner: String = member.substring(0, at);
		final type: String = owner.substring(owner.lastIndexOf('.') + 1);
		final method: String = member.substring(at + 1);
		if (method == ENTRY_POINT) return false;
		final found: Result = cmd('git -C $tree grep -lFw --untracked --all-match -e $type -e $method -- test').run();
		return found.ok && found.lines().exists(file -> file.endsWith('.hx'));
	}

	/** The row over the slice of `gate`: its changed functions against the arms, the tests and the callers that reach them. */
	public static function outcome(gate: GateTree): Outcome {
		if (!reached(gate.touched)) return Skipped('no source file changed');
		final seeds: Array<String> = [];
		var unread: Int = 0;
		for (touch in GateArms.touchesOf(gate, command -> command)) {
			final file: Null<String> = fileOf(touch.module, gate.touched);
			if (file == null) continue;
			final fresh: Bool = !cmd('git -C ${gate.tree} cat-file -e ${gate.base}:$file').run().ok;
			if (touch.members == null && !fresh) unread++;
			final outline: Result = gate.hxq(gate.tree, ['show', file, '--outline']).run();
			if (outline.ok) for (seed in seedsOf(touch, functionsOf(outline.out, touch.module), fresh)) seeds.push(seed);
		}
		final skipped: String = unread == 0 ? '' : ', $unread files whose changed functions the report cannot name unread';
		if (seeds.length == 0) {
			gate.summary.detail('no changed function$skipped');
			return Passed;
		}
		final armedNames: Array<String> = armed(ArmRegistry.read(Path.join([gate.tree, ArmRegistry.DIRECTORY])));
		final memo: Map<String, Bool> = [];
		final direct: String -> Bool = name -> {
			if (!memo.exists(name)) memo[name] = armedNames.contains(name) || named(gate.tree, name);
			return memo[name] == true;
		};
		final focus: Array<String> = [ for (seed in seeds) for (arg in ['--focus', seed]) arg ];
		final graph: CodeGraphJson = GateArms.graphOf(gate, ['--level', 'member', '--edges', 'calls', '--radius', '$DEPTH'].concat(
			focus
		), command -> command);
		final red: Array<String> = open(seeds, direct, callersOf(graph), DEPTH);
		File.saveContent(Path.join([gate.logs, LIST]), red.map(name -> '$name\n').join(''));
		final declared: String = declaration(gate.logs);
		final result: Outcome = verdict(red, FileSystem.exists(declared) ? MovedFiles.named(File.getContent(declared)) : []);
		gate.summary.detail('${seeds.length} functions, ${red.length} unreached$skipped');
		return result;
	}

	/** The touched source file that holds `module`, or null when none of `touched` does. */
	public static function fileOf(module: String, touched: Array<String>): Null<String> {
		final path: String = module.replace('.', '/') + '.hx';
		return touched.find(file -> SOURCE_ROOTS.exists(root -> file == root + path));
	}

	private static function climbs(seed: String, direct: String -> Bool, callers: Map<String, Array<String>>, depth: Int): Bool {
		var layer: Array<String> = [seed];
		final seen: Map<String, Bool> = [seed => true];
		for (_ in 0...depth + 1) {
			if (layer.exists(direct)) return true;
			final next: Array<String> = [];
			for (name in layer) {
				final up: Null<Array<String>> = callers[name];
				if (up != null) for (caller in up) if (!seen.exists(caller)) {
					seen[caller] = true;
					next.push(caller);
				}
			}
			layer = next;
		}
		return false;
	}

}
