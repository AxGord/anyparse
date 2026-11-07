package unit.cli;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
#if (sys || nodejs)
import sys.io.File;
#end

using Lambda;
using StringTools;

/**
 * Every call that mutates the file system in `src/anyparse/query/cli` sits in `CliIo` — the one write
 * route `APQ_READ_ONLY` gates — or in a type listed here with the reason its write is not an edit of
 * the tree a reviewer judges (scratch, a cache, a file the caller named as the command's output).
 *
 * This census is what holds the documented claim that a new writing command is covered by being a
 * caller of the route: a command that reaches the disk directly is a new site, and it fails here
 * until it goes through `CliIo` or is listed with its reason.
 *
 * Both pins are `guard`s: nothing in the engine decides what the source text of its own commands
 * contains, so no cut of a compiled type flips them; they go red the day a direct write is added.
 */
@:nullSafety(Strict)
final class ReadOnlyWriteRouteCensusTest extends Test {

	#if (sys || nodejs)
	/** The directory swept: every command and the CLI's own helpers. */
	private static final ROOT: String = 'src/anyparse/query/cli';

	/** The receivers whose members touch the file system: `sys.io.File`, `sys.FileSystem`, `js.node.Fs`. */
	private static final RECEIVERS: Array<String> = ['File', 'FileSystem', 'Fs'];

	/** The members of those receivers that create, change or remove a file or directory. */
	private static final MUTATORS: Array<String> = [
		'saveContent',
		'saveBytes',
		'append',
		'deleteFile',
		'deleteDirectory',
		'rename',
		'createDirectory',
		'write',
		'copy'
	];

	/** A synchronous `js.node.Fs` member starting with one of these changes the file system. */
	private static final SYNC_MUTATOR_PREFIXES: Array<String> = [
		'write',
		'append',
		'unlink',
		'rm',
		'mkdir',
		'rename',
		'copyFile',
		'chmod',
		'symlink',
		'truncate',
		'utimes'
	];

	/** The types that may write directly, each with the reason it is not an edit of the judged tree. */
	private static final SANCTIONED: Map<String, String> = [
		'CliIo' => 'the write route itself: staging, rename, undo of a created file',
		'BatchRun' => 'the answers file the caller named',
		'MergeFileCommand' => 'a scratch directory for git merge-file',
		'StdlibDupCommand' => 'its own scratch directory',
		'ReconCommand' => 'the fork-path cache, best effort',
		'ProbeCommand' => 'the staged probe source under the temp root',
		'SweepCommand' => '--save, the snapshot file the caller named',
		'ModuleMoveCli' => 'the rollback removing a directory the move itself made',
		'CodeCacheLauncher' => 'the V8 code cache beside the engine, rewritten atomically',
		'WriteJournal' => 'restores the mode of a file the route itself wrote'
	];
	#end

	@:pin('guard')
	public function testEveryDirectDiskMutationIsInAListedType(): Void {
		#if (sys || nodejs)
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final hits: Map<String, Array<String>> = [];
		final unread: Array<String> = [];
		final paths: Array<String> = SourceTree.collect(ROOT);
		for (path in paths) {
			final type: String = path.substring(path.lastIndexOf('/') + 1, path.length - '.hx'.length);
			try {
				final found: Array<String> = directWrites(plugin.parseFile(File.getContent(path)));
				if (found.length > 0) hits[type] = found;
			} catch (exception: haxe.Exception) {
				unread.push('$path: ${exception.message}');
			}
		}
		final unlisted: Array<String> = [
			for (type => found in hits) if (!SANCTIONED.exists(type)) '$type: ${found.join(', ')}'
		];
		final stale: Array<String> = [for (type in SANCTIONED.keys()) if (!hits.exists(type)) type];
		unlisted.sort(anyparse.util.Compare.compareString);
		stale.sort(anyparse.util.Compare.compareString);
		Assert.isTrue(paths.length > 100, 'the sweep reaches the commands: ${paths.length} files');
		Assert.same([], unread, 'a file this census cannot parse is a file it cannot vouch for');
		Assert.same(
			[], unlisted, 'a direct write outside CliIo: go through CliIo.writeFile / deletePath, or list the type with its reason'
		);
		Assert.same([], stale, 'a sanctioned type that no longer writes directly: drop it from the list');
		#else
		Assert.fail('this gate is compiled out on the current target, so nothing enforces the route it checks');
		#end
	}

	/** The detector reports a mutating member of a file-system receiver, however the receiver is spelled, and nothing else. */
	@:pin('guard')
	public function testTheDetectorFindsADirectWriteAndNothingElse(): Void {
		#if (sys || nodejs)
		Assert.same(['File.saveContent'], found('class C { function f() { File.saveContent(a, b); } }'));
		Assert.same(['File.saveContent'], found('class C { function f() { sys.io.File.saveContent(a, b); } }'));
		Assert.same(['FileSystem.deleteFile'], found('class C { function f() { FileSystem.deleteFile(p); } }'));
		Assert.same(['Fs.writeFileSync'], found('class C { function f() { Fs.writeFileSync(a, b); } }'));
		Assert.same(['File.write'], found('class C { function f() { File.write(p); } }'));
		Assert.same(['File.copy'], found('class C { function f() { sys.io.File.copy(a, b); } }'));
		Assert.same(
			[], found('class C { function f() { CliIo.writeFile(a, b); CliIo.deletePath(p); } }'), 'the route is not a direct write'
		);
		Assert.same(
			[], found('class C { function f() { buffer.append(x); File.getContent(p); FileSystem.exists(p); Fs.readFileSync(p); } }')
		);
		#else
		Assert.fail('this gate is compiled out on the current target');
		#end
	}

	#if (sys || nodejs)
	private static function found(source: String): Array<String> {
		return directWrites(new HaxeQueryPlugin().parseFile(source));
	}

	/** `Receiver.member` of every mutating member access of a file-system receiver under `node`, in document order. */
	private static function directWrites(node: QueryNode): Array<String> {
		final out: Array<String> = [];
		final name: Null<String> = node.name;
		final receiver: Null<QueryNode> = node.children[0];
		if (node.kind == 'FieldAccess' && name != null && receiver != null) {
			final owner: Null<String> = receiver.name;
			if (owner != null && RECEIVERS.contains(owner) && mutates(name)) out.push('$owner.$name');
		}
		for (child in node.children) for (hit in directWrites(child)) out.push(hit);
		return out;
	}

	private static function mutates(member: String): Bool {
		return MUTATORS.contains(member) || (member.endsWith('Sync') && SYNC_MUTATOR_PREFIXES.exists(prefix -> member.startsWith(prefix)));
	}
	#end

}
