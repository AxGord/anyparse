package unit;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Engine;
import anyparse.query.QueryNode;
import anyparse.query.Selector;
import testkit.MutationArms;
import testkit.TestRegistry;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * Every declared arm still ADDRESSES a live member — asked of the parser, of
 * the very file `tools/mutation-arm.sh` patches.
 *
 * `testkit.TestDiscovery` asks the same question of the TYPER, and for most
 * arms that is the earlier and better answer: it is a build error, so a rename
 * stops the build instead of a sweep. It has one blind spot, and it is not a
 * small one. A module whose every type sits behind `#if macro` contributes no
 * type to a non-macro build, so `Context.getModule('anyparse.macro.WriterLowering')`
 * answers `ok, 0 type(s)` — measured on `d86c958b` — and the whole macro-time
 * half of the engine (`WriterLowering` 109 members, `Lowering` 77,
 * `WriterCodegen`, `TriviaTypeSynth`, the five `Writer*Lowering` modules S85 and
 * S87 split out) was unaddressable by an arm because of it. S100 hit the wall
 * head-on: four arms it wanted against a writer seam had to cut the config
 * LOADER instead.
 *
 * The parser has no such blind spot — a `#if` region is a `Conditional` node
 * whose branches are ordinary children — so this walk answers for a macro-time
 * member exactly as it does for a runtime one. It also answers a question the
 * build macro never asked at all: the runner resolves a type to a FILE by hand
 * (`for root in src test`) and selects `FnMember:<method>` in it, and until now
 * nothing checked that either step still lands.
 *
 * What it deliberately does NOT check is whether a FRAGMENT arm's `find` text
 * still occurs. That is `anyparse.query.Patch`'s matcher, and calling it per arm
 * would run a canonical writer round-trip over each host file; running the arm
 * is what answers it, and a stale `find` fails loudly there. Backlog, named.
 */
@:nullSafety(Strict)
final class MutationArmAddressTest extends Test {

	/** The selector `tools/mutation-arm.sh` hands `hxq patch` for every arm, whatever its cut. */
	private static inline final MEMBER_KIND: String = 'FnMember';

	/**
	 * Every arm resolves to a file under `src/` or `test/` that declares its member.
	 *
	 * Reads the REAL registry, which is the point: this is the only instrument that
	 * can see a macro-time member, so a fixture over a table of its own would leave
	 * the hole exactly where S100 found it. The pure half of the same question —
	 * a dotted type becoming a path — is `unit.MutationArmsTest`, on a table of its
	 * own, and `M-ARM-PATH-FLAT` cuts the member both of them go through.
	 */
	@:pin('control')
	@:killer('M-ARM-PATH-FLAT')
	public function testEveryDeclaredArmAddressesALiveMember(): Void {
		#if (sys || nodejs)
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final trees: Map<String, QueryNode> = [];
		final unaddressed: Array<String> = [];
		final rendered: Array<String> = TestRegistry.arms();
		for (line in rendered) {
			final member: String = line.split(' :: ')[1];
			final parts: Array<String> = member.split('#');
			final candidates: Array<String> = MutationArms.candidateFiles(parts[0]);
			final file: Null<String> = candidates.find(path -> FileSystem.exists(path));
			if (file == null) {
				unaddressed.push('$member: under none of ${candidates.join(', ')}');
				continue;
			}
			final cached: Null<QueryNode> = trees[file];
			final tree: QueryNode = if (cached != null)
				cached
			else {
				final parsed: QueryNode = plugin.parseFile(File.getContent(file));
				trees[file] = parsed;
				parsed;
			};
			final selector: Selector = Selector.parse('$MEMBER_KIND:${parts[1]}');
			if (Engine.select(tree, selector, plugin.selectKindEquivalence()).length == 0)
				unaddressed.push('$member: $file declares no $MEMBER_KIND of that name');
		}
		Assert.isTrue(rendered.length > 0, 'the registry has to carry arms for this walk to mean anything');
		Assert.equals(0, unaddressed.length, 'arms whose member the runner could not reach:\n  ${unaddressed.join('\n  ')}');
		#else
		Assert.pass('the walk needs a filesystem');
		#end
	}

	/**
	 * The arms the typer could not answer for are exactly the ones under a `#if macro`
	 * module, and they are reachable here.
	 *
	 * `TestRegistry.deferredArms()` is the build macro saying which questions it handed
	 * on; without this, a module quietly moving behind a conditional would move its arm
	 * from a build error to nothing at all, silently. The census is pinned by name in
	 * `unit.TestDiscoveryParityTest`; what is checked here is that every deferred arm is
	 * one the walk above reaches.
	 */
	@:pin('control')
	@:killer('M-ARM-PATH-FLAT')
	public function testTheDeferredArmsAreTheOnesTheWalkAnswersFor(): Void {
		#if (sys || nodejs)
		final missing: Array<String> = [];
		for (line in TestRegistry.deferredArms()) {
			final member: String = line.split(' :: ')[1];
			final candidates: Array<String> = MutationArms.candidateFiles(member.split('#')[0]);
			if (candidates.find(path -> FileSystem.exists(path)) == null) missing.push(line);
		}
		Assert.isTrue(TestRegistry.deferredArms().length > 0, 'a deferral the typer never makes would make this fixture vacuous');
		Assert.equals(0, missing.length, 'deferred arms with no file to parse:\n  ${missing.join('\n  ')}');
		#else
		Assert.pass('the walk needs a filesystem');
		#end
	}

}
