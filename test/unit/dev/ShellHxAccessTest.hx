package unit.dev;

import dev.ShellHxAccess;
import utest.Assert;
import utest.Test;

/**
 * `ShellHxAccess`: which shell commands read or write a repo `.hx` outside hxq — every segment of a pipeline, the directory
 * followed through `cd`, here-documents and quoted payloads as data, and the repo told from a slice's logs, a fixture
 * directory and a path held in a variable.
 */
@:nullSafety(Strict)
final class ShellHxAccessTest extends Test {

	private static inline final TREE: String = '/w/anyparse';

	public function testEverySegmentOfALineIsRead(): Void {
		Assert.isTrue(ShellHxAccess.reads('cd /w/anyparse && export X=1 && cat src/A.hx', null, null));
		Assert.isFalse(ShellHxAccess.reads('cd /w/anyparse && cat a.txt; git diff src/A.hx', null, null));
		Assert.isTrue(ShellHxAccess.reads('ls x | head -3; cat tools/src/dev/B.hx', TREE, null));
	}

	public function testARelativePathNeedsAKnownRepoDirectory(): Void {
		Assert.isFalse(ShellHxAccess.reads('cat src/A.hx', null, null));
		Assert.isTrue(ShellHxAccess.reads('cat src/A.hx', TREE, null));
		Assert.isFalse(ShellHxAccess.reads("cd $P && cat src/A.hx", TREE, null));
		Assert.isFalse(ShellHxAccess.reads("cat $F/src/A.hx", TREE, null));
		Assert.isFalse(ShellHxAccess.reads('cd /w/other && cat src/A.hx', TREE, null));
	}

	public function testAProgramThatIsNotAReaderOrIsAWriteIsNotARead(): Void {
		Assert.isFalse(ShellHxAccess.reads('hxq show src/A.hx', TREE, null));
		Assert.isFalse(ShellHxAccess.reads('git diff main -- src/A.hx', TREE, null));
		Assert.isFalse(ShellHxAccess.reads('cat notes.txt && ls src/A.hx', TREE, null));
		Assert.isFalse(ShellHxAccess.reads('cat test/cases/a.hxtest', TREE, null));
		Assert.isFalse(ShellHxAccess.reads("cat > src/A.hx <<'EOF'\nx\nEOF", TREE, null));
		Assert.isFalse(ShellHxAccess.reads("sed -i '' 's/a/b/' src/A.hx", TREE, null));
		Assert.isTrue(ShellHxAccess.reads('sed -n 1,5p src/A.hx 2>/dev/null', TREE, null));
	}

	public function testAHeredocBodyAndAQuotedPayloadAreData(): Void {
		Assert.isFalse(ShellHxAccess.reads("hxq patch src/A.hx --write - <<'EOF'\ncat src/B.hx\nEOF", TREE, null));
		Assert.isFalse(ShellHxAccess.writes("hxq patch src/A.hx --write - <<'EOF'\nx > src/B.hx\nEOF", TREE, null));
		Assert.isFalse(ShellHxAccess.writes("hxq patch src/B.hx --write $'a\\n====\\nx > src/A.hx'", TREE, null));
		Assert.isFalse(ShellHxAccess.reads("hxq patch src/B.hx --write 'a; cat src/A.hx'", TREE, null));
		Assert.isTrue(ShellHxAccess.writes("cat > src/B.hx <<'EOF'\nclass B {}\nEOF", TREE, null));
	}

	public function testAWriteOutsideHxqIsCaught(): Void {
		Assert.isTrue(ShellHxAccess.writes("sed -i '' 's/a/b/' src/anyparse/A.hx", TREE, null));
		Assert.isTrue(ShellHxAccess.writes("perl -pi -e 's/a/b/' src/A.hx", TREE, null));
		Assert.isTrue(ShellHxAccess.writes('echo x >> test/unit/ATest.hx', TREE, null));
		Assert.isFalse(ShellHxAccess.writes('echo x 2>&1 | tee log', TREE, null));
		Assert.isFalse(ShellHxAccess.writes('cmd 2>/dev/null > out.txt', TREE, null));
	}

	public function testAFixtureOrLogsDirectoryOrAVariableIsNotTheRepo(): Void {
		Assert.isFalse(ShellHxAccess.writes('cd /tmp/hxqb-S1-logs/fx && cat > src/A.hx', null, 'S1'));
		Assert.isFalse(ShellHxAccess.writes('mkdir -p /tmp/hxqb-FB2-fx/src && cd /tmp/hxqb-FB2-fx && cat > src/E.hx', null, 'FB2'));
		Assert.isFalse(ShellHxAccess.writes('cd /tmp/probe && cat > src/Main.hx', null, null));
		Assert.isFalse(ShellHxAccess.writes("mkdir -p $D/src && cat > $D/src/A.hx", TREE, null));
		Assert.isFalse(ShellHxAccess.writes("P=/tmp/hxqb-S232-logs/p; cd $P && cat > src/pkg/Base.hx", TREE, 'S232'));
		Assert.isFalse(ShellHxAccess.reads('cat /w/anyparse-logs/x/src/A.hx', null, null));
		Assert.isFalse(ShellHxAccess.reads('cat /tmp/hxqb-S1-logs/src/A.hx', null, 'S1'));
	}

	public function testTheAgentsOwnSliceTreeIsTheRepo(): Void {
		Assert.isTrue(ShellHxAccess.writes('cd /tmp/hxqb-S1 && echo x > src/A.hx', null, 'S1'));
		Assert.isFalse(ShellHxAccess.writes('cd /tmp/hxqb-S1 && echo x > src/A.hx', null, 'S2'));
		Assert.isFalse(ShellHxAccess.writes('cd /tmp/hxqb-S1 && echo x > src/A.hx', null, null));
		Assert.isTrue(ShellHxAccess.reads('cd /tmp/hxqb-TOKEN-AUDIT && sed -n 1p src/A.hx', null, 'TOKEN-AUDIT'));
	}

	public function testRepoPathsAreTheMainTreeAndItsWorktrees(): Void {
		Assert.isTrue(ShellHxAccess.isRepoPath('/w/anyparse/src/A.hx', null));
		Assert.isTrue(ShellHxAccess.isRepoPath('/w/.wt/anyparse/S1/src/A.hx', null));
		Assert.isFalse(ShellHxAccess.isRepoPath('/w/.wt/anyparse/S1-logs/src/A.hx', null));
		Assert.isFalse(ShellHxAccess.isRepoPath('/w/other/src/A.hx', null));
		Assert.isFalse(ShellHxAccess.isRepoPath('/private/tmp/x/anyparse/src/A.hx', null));
	}

	public function testACopyOntoOrAMoveOfARepoHxIsAWrite(): Void {
		Assert.isTrue(ShellHxAccess.writes('cd /w/anyparse && cp /tmp/x.bak src/A.hx', null, null));
		Assert.isTrue(ShellHxAccess.writes('cp -f /tmp/x.bak src/A.hx', TREE, null));
		Assert.isFalse(ShellHxAccess.writes('cp src/A.hx /tmp/x.bak', TREE, null));
		Assert.isTrue(ShellHxAccess.writes('mv src/A.hx src/B.hx', TREE, null));
		Assert.isTrue(ShellHxAccess.writes('mv src/A.hx /tmp/gone', TREE, null));
		Assert.isTrue(ShellHxAccess.writes('git mv src/A.hx src/B.hx', TREE, null));
		Assert.isTrue(ShellHxAccess.writes('git -C /w/anyparse mv /w/anyparse/src/A.hx /w/anyparse/src/B.hx', null, null));
		Assert.isTrue(ShellHxAccess.writes('echo x | tee -a src/A.hx', TREE, null));
		Assert.isTrue(ShellHxAccess.writes('install -m 644 /tmp/a src/A.hx', TREE, null));
		Assert.isFalse(ShellHxAccess.writes('cd /tmp/hxqb-S1-logs/fx && cp a src/A.hx', null, 'S1'));
		Assert.isFalse(ShellHxAccess.writes('cp a notes.txt', TREE, null));
		Assert.isFalse(ShellHxAccess.writes('git diff src/A.hx', TREE, null));
	}

	public function testAnInterpreterScriptThatWritesAHxIsAHeuristicSegment(): Void {
		final script: String = "cd /w/anyparse && python3 - <<'EOF'\nopen('src/A.hx', 'w').write('x')\nEOF";
		Assert.equals('python3 -', ShellHxAccess.scriptSegment(script, null, null));
		Assert.isNull(ShellHxAccess.scriptSegment("python3 - <<'EOF'\nopen('src/A.hx', 'w').write('x')\nEOF", null, null));
		Assert.isNull(ShellHxAccess.scriptSegment("cd /tmp/hxqb-S1-logs && python3 - <<'EOF'\nopen('src/A.hx', 'w')\nEOF", null, 'S1'));
		Assert.isNull(ShellHxAccess.scriptSegment("cd /w/anyparse && python3 - <<'EOF'\nprint(open('src/A.hx').read())\nEOF", null, null));
		Assert.isNull(ShellHxAccess.scriptSegment("cd /w/anyparse && python3 - <<'EOF'\nopen('notes.txt', 'w')\nEOF", null, null));
		Assert.notNull(ShellHxAccess.scriptSegment("cd /w/anyparse && node -e \"fs.writeFileSync('src/A.hx', 'x')\"", null, null));
	}

	public function testTheMatchingSegmentIsWhatTheSampleShows(): Void {
		Assert.equals('sed -n 1,5p src/A.hx', ShellHxAccess.readSegment('hxq lint x && sed -n 1,5p src/A.hx | wc', TREE, null));
		Assert.equals('cp a src/A.hx', ShellHxAccess.writeSegment('ls && cp a src/A.hx; echo done', TREE, null));
		Assert.isNull(ShellHxAccess.readSegment('hxq show src/A.hx', TREE, null));
	}

}
