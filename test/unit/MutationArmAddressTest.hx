package unit;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.ElementSpan;
import anyparse.query.Engine;
import anyparse.query.Patch;
import anyparse.query.QueryNode;
import anyparse.query.Selector;
import anyparse.runtime.Span;
import testkit.MutationArms;
import testkit.TestRegistry;
import utest.Assert;
import utest.Test;

using StringTools;
using Lambda;

/**
 * One arm's cut site, resolved: the host file's text, the addressed node, and the region
 * a cut is searched inside.
 *
 * Both walks below need all three and derive them identically — resolve the file, parse
 * it once per host, select `<kind>:<member>`, take the declaration's edit span. Only what
 * they then ASK of the site differs, which is the whole reason the shape is shared.
 */
typedef ArmSite = {
	final source: String;
	final node: QueryNode;
	final group: Span;
};

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
 * (`for root in src test`) and selects `<kind>:<member>` in it — `FnMember` unless the record
 * spells another, which is how an arm reaches a grammar DECLARATION with no method to
 * cut — and until now nothing checked that either step still lands.
 *
 * The FRAGMENT half was written off here as needing a canonical writer
 * round-trip per host file. It does not: `Patch.locate` runs on the raw slice,
 * long before `CanonicalEdit.canonicalize` is reached, so the last fixture below
 * asks that matcher directly and costs one extra parse of the ~20 host files.
 */
@:nullSafety(Strict)
final class MutationArmAddressTest extends Test {

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
	@:killer('M-ARM-KIND-UNSPELLED')
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
			// The kind is the arm's own — `FnMember` for a member cut, and whatever a record
			// spells for one that addresses a grammar DECLARATION instead.
			final address: String = MutationArms.selectorOf(parts[1]);
			final selector: Selector = Selector.parse(address);
			if (Engine.select(tree, selector, plugin.selectKindEquivalence()).length == 0)
				unaddressed.push('$member: $file has no $address');
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

	/**
	 * Every FRAGMENT arm's stored `find` text still cuts — asked of the matcher `hxq patch`
	 * itself uses, over the very node the runner resolves.
	 *
	 * The build macro checks an arm's TYPE and its MEMBER, so a rename or a move stops the
	 * build. It never checked the fragment, and a refactor that rewrites a member's body
	 * leaves the arm pointing at text that no longer occurs — twice, measured: S103 found
	 * `M-ROOTS-THIRDPARTY` had silently stopped applying after an extraction, and
	 * `M-OPAQUE-REGION-NODE-SPAN` built green for a whole slice after `daf1a095` and was
	 * caught only by RUNNING it.
	 *
	 * A plain substring test over the host FILE cannot take the job, and the measurement says
	 * so rather than the reasoning: of the 69 fragment arms at `a45a05d9`, three match only
	 * through the whitespace-insensitive fallback and four occur TWICE in the file while
	 * occurring once in the node, so a strict substring gate would fail seven healthy arms and
	 * stop the build where there is no defect. What made the faithful check look expensive was
	 * a claim this fixture refutes: `Patch.locate` runs on the raw slice, long before
	 * `CanonicalEdit.canonicalize` is reached, so no writer round-trip is involved at all.
	 *
	 * The node has to resolve UNIQUELY, which is the runner's own contract (`--select` refuses
	 * an ambiguous match) and one step stricter than the walk above.
	 *
	 * Killed by arm `M-ARM-FRAGMENT-NONE`, which makes the matcher answer zero.
	 */
	@:access(anyparse.query.Patch)
	@:pin('control')
	@:killer('M-ARM-FRAGMENT-NONE')
	public function testEveryFragmentArmStillCutsItsNode(): Void {
		#if (sys || nodejs)
		final table: ArmTable = MutationArms.parse(File.getContent('test/testkit/mutation-arms.json'));
		Assert.equals(0, table.errors.length, 'the registry has to read cleanly first: ${table.errors.join('; ')}');
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final sources: Map<String, String> = [];
		final trees: Map<String, QueryNode> = [];
		final stale: Array<String> = [];
		var fragments: Int = 0;
		for (arm in table.arms) {
			final find: Null<String> = arm.find;
			if (find == null) continue;
			fragments++;
			final address: String = MutationArms.address(arm);
			final resolved: Null<ArmSite> = resolveArmSite(arm, address, plugin, sources, trees, stale);
			if (resolved == null) continue;
			final hits: Int = Patch.occurrences(
				resolved.source.substring(resolved.group.from, resolved.group.to), find, resolved.node.kind
			);
			if (hits != 1)
				stale.push(
					'$address: the stored fragment occurs $hits time(s) in the ${resolved.node.kind} node, and the cut needs exactly one'
				);
		}
		Assert.isTrue(fragments > 0, 'a registry with no fragment arm would make this walk vacuous');
		Assert.equals(0, stale.length, 'arms whose stored cut no longer applies:\n  ${stale.join('\n  ')}');
		#else
		Assert.pass('the walk needs a filesystem');
		#end
	}

	/**
	 * Every FORCE arm still opens a body its forced `return` can be spliced into.
	 *
	 * The walk above covers the FRAGMENT half. The other third of the registry declares
	 * `force` instead, and nothing checked those at all: that walk skips an arm with no
	 * fragment, and the build macro only asks the typer that the member exists. Their one
	 * applicability test lived inside `tools/mutation-arm.sh`, so it ran when the ARM ran —
	 * the same "only a run can tell you" that cost S118 a whole green slice on a rotted
	 * fragment, in the half that had no walk yet.
	 *
	 * What the runner needs is narrow, and the tree states all of it: the member resolves
	 * to exactly one node, that node opens a `BlockBody` (an expression body or a bodyless
	 * declaration offers no brace to splice after), nothing but whitespace follows the
	 * brace on its line, and the header up to it occurs exactly once inside the member —
	 * that header being the fragment `apq patch` is then handed.
	 *
	 * The runner derives the same header by BALANCING braces in a shell-embedded script,
	 * because shell has no parser, and that arithmetic is what once sent a forced `return`
	 * inside a return type that opened a brace of its own (`Null<{ … }>`). Asking the tree
	 * removes it: the body's span IS the answer. The two cannot drift quietly — a member
	 * this fixture accepts and the balancer misreads makes the runner refuse BY NAME.
	 */
	@:access(anyparse.query.Patch)
	public function testEveryForceArmStillOpensABodyToCutInto(): Void {
		#if (sys || nodejs)
		final table: ArmTable = MutationArms.parse(File.getContent('test/testkit/mutation-arms.json'));
		Assert.equals(0, table.errors.length, 'the registry has to read cleanly first: ${table.errors.join('; ')}');
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final sources: Map<String, String> = [];
		final trees: Map<String, QueryNode> = [];
		final stale: Array<String> = [];
		var forced: Int = 0;
		for (arm in table.arms) if (arm.force != null) {
			forced++;
			final address: String = MutationArms.address(arm);
			final resolved: Null<ArmSite> = resolveArmSite(arm, address, plugin, sources, trees, stale);
			if (resolved == null) continue;
			final header: Null<String> = forcedCutHeader(resolved);
			if (header == null) {
				stale.push('$address: the resolved ${resolved.node.kind} node opens no block body a forced return can follow');
				continue;
			}
			final hits: Int = Patch.occurrences(
				resolved.source.substring(resolved.group.from, resolved.group.to), header, resolved.node.kind
			);
			if (hits != 1)
				stale.push('$address: the signature down to its body brace occurs $hits time(s), and the splice needs exactly one');
		}
		Assert.isTrue(forced > 0, 'a registry with no forced arm would make this walk vacuous');
		Assert.equals(0, stale.length, 'forced arms with no body left to cut into:\n  ${stale.join('\n  ')}');
		#else
		Assert.pass('the walk needs a filesystem');
		#end
	}

	/**
	 * The arm's cut site, or null after naming in `stale` why it could not be resolved.
	 *
	 * Parses each host file ONCE and keeps the tree beside its source, because the two
	 * walks address the same ~20 hosts and every offset below is into that exact text.
	 */
	private static function resolveArmSite(
		arm: MutationArm, address: String, plugin: HaxeQueryPlugin, sources: Map<String, String>, trees: Map<String, QueryNode>,
		stale: Array<String>
	): Null<ArmSite> {
		#if (sys || nodejs)
		final candidates: Array<String> = MutationArms.candidateFiles(arm.type);
		final found: Null<String> = candidates.find(path -> FileSystem.exists(path));
		if (found == null) {
			stale.push('$address: under none of ${candidates.join(', ')}');
			return null;
		}
		final file: String = found;
		final cachedSource: Null<String> = sources[file];
		final source: String = if (cachedSource != null)
			cachedSource;
		else {
			final read: String = File.getContent(file);
			sources[file] = read;
			trees[file] = plugin.parseFile(read);
			read;
		}
		final tree: Null<QueryNode> = trees[file];
		if (tree == null) throw 'the tree is written beside the source it was parsed from';
		final selector: String = '${arm.kind}:${arm.method}';
		final matches: Array<QueryNode> = Engine.select(tree, Selector.parse(selector), plugin.selectKindEquivalence());
		if (matches.length != 1) {
			stale.push('$address: $file holds ${matches.length} "$selector" nodes, and the cut needs exactly one');
			return null;
		}
		final node: QueryNode = matches[0];
		final span: Null<Span> = node.span;
		if (span != null) return {
			source: source,
			node: node,
			group: ElementSpan.declEditSpan(source, tree, node, span, plugin.lexicalRegions.bind(source))
		};
		stale.push('$address: the resolved ${node.kind} node carries no span to search');
		return null;
		#else
		return null;
		#end
	}

	/**
	 * The member's own text down to and including the line its block body opens on — the
	 * anchor a forced `return` is spliced after — or null when there is nothing to splice
	 * into.
	 *
	 * Null covers the two shapes the runner cannot force and the registry may still name:
	 * a member whose body is an EXPRESSION (`function f(): Void trace(1);`) and one with no
	 * body at all (an interface or abstract declaration). Both are answered by the body
	 * node's KIND rather than by hunting a brace, which is the point — a return type may
	 * open a brace of its own, and the tree already keeps that inside the type.
	 */
	private static function forcedCutHeader(site: ArmSite): Null<String> {
		final memberSpan: Null<Span> = site.node.span;
		if (memberSpan == null) return null;
		final body: Null<QueryNode> = site.node.children.find(child -> child.kind == 'BlockBody');
		final bodySpan: Null<Span> = body?.span;
		if (bodySpan == null) return null;
		final lineEnd: Int = site.source.indexOf('\n', bodySpan.from);
		if (lineEnd < 0) return null;
		// The runner refuses a body that opens mid-line, and so does this: the header it
		// splices after would then carry the first statement along with the brace.
		if (site.source.substring(bodySpan.from + 1, lineEnd).trim() != '') return null;
		return site.source.substring(memberSpan.from, lineEnd + 1);
	}

}
