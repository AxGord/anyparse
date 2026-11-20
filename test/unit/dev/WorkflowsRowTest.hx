package unit.dev;

import dev.Battery;
import dev.SliceGate;
import dev.WorkflowsRow;
import devkit.Cmd.cmd;
import devkit.Summary;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** `dev.WorkflowsRow`: what the slice gate's workflows row and the battery's workflows step say of the tracked workflow files. */
@:nullSafety(Strict)
final class WorkflowsRowTest extends Test {

	/** The loader's command as a plugin root holds it: it prints `fail <file>: <message>` for each file marked FAULT. */
	private static final STAND_IN: String = '#!/bin/sh\nstatus=0\nfor f in "$$1"/*.yaml; do\n'
		+ '  if grep -q FAULT "$$f"; then echo "fail $$f: state \\"sweep_wait\\" action requires on_success + on_error"; status=1;\n'
		+ '  else echo "ok $$(basename "$$f" .yaml)"; fi\ndone\nexit $$status\n';

	public function testTheGateHasARowThatJudgesTheTrackedWorkflows(): Void {
		final rows: Array<String> = [ for (branch in SliceGate.GATE_BRANCHES) for (row in branch) row ];
		Assert.isTrue(rows.contains('workflows'), 'the gate rows: $rows');
		Assert.isTrue(Battery.rowNames().contains('workflows'), 'the battery steps: ${Battery.rowNames()}');
	}

	@:pin('control')
	@:killer('M-WORKFLOWS-ROW-REACHED-BY-ANY-FILE')
	public function testOnlyATrackedWorkflowFileReachesTheRow(): Void {
		Assert.isTrue(WorkflowsRow.reached(['docs/a.md', '.claude/workflows/slice-pipeline.yaml']));
		Assert.isTrue(WorkflowsRow.reached(['.claude/workflows/lib/principles.md']));
		Assert.isFalse(WorkflowsRow.reached(['docs/a.md', '.claude/batch/queue.yaml', 'tools/src/dev/SliceGate.hx']));
		Assert.isFalse(WorkflowsRow.reached([]));
	}

	@:pin('control')
	@:killer('M-WORKFLOWS-ROW-STATUS-IGNORED')
	public function testAFileTheLoaderRefusesFailsTheRowWithItsMessage(): Void {
		TempDir.with(dir -> {
			final root: String = engine(dir);
			final tree: String = workflows(dir, ['good' => 'name: good', 'bad' => 'name: bad\n# FAULT']);
			final outcome: Outcome = WorkflowsRow.outcome(tree, root, new Summary());
			switch outcome {
				case Failed(why):
					Assert.stringContains('bad.yaml', why);
					Assert.stringContains('requires on_success + on_error', why);
					Assert.equals(-1, why.indexOf('good.yaml'), 'the file that loads is not named: $why');
				case _: Assert.fail('a refused file must fail the row: $outcome');
			}
		});
	}

	public function testATreeWhoseFilesAllLoadPasses(): Void {
		TempDir.with(dir -> {
			final tree: String = workflows(dir, ['a' => 'name: a', 'b' => 'name: b']);
			Assert.isTrue(WorkflowsRow.outcome(tree, engine(dir), new Summary()).match(Passed));
		});
	}

	@:pin('control')
	@:killer('M-WORKFLOWS-ROW-NO-LOADER-PASSES')
	public function testNoLoaderIsNotRunWhateverTheTree(): Void {
		TempDir.with(dir -> {
			final tree: String = workflows(dir, ['bad' => 'FAULT']);
			Assert.isTrue(WorkflowsRow.outcome(tree, null, new Summary()).match(NotRun(_)));
			Assert.isTrue(WorkflowsRow.outcome(tree, '', new Summary()).match(NotRun(_)));
			Assert.isTrue(WorkflowsRow.outcome(tree, dir.file('no-plugin'), new Summary()).match(NotRun(_)));
			Assert.isNull(WorkflowsRow.validator(dir.file('no-plugin')));
		});
	}

	/** A plugin root whose `scripts/wf-validate` is the stand-in loader. */
	private static function engine(dir: TempDir): String {
		final root: String = dir.file('plugin');
		FileSystem.createDirectory(Path.join([root, 'scripts']));
		final script: String = Path.join([root, 'scripts/wf-validate']);
		File.saveContent(script, STAND_IN);
		cmd('chmod +x $script').check();
		return root;
	}

	/** A tree whose `.claude/workflows` holds `files` by name. */
	private static function workflows(dir: TempDir, files: Map<String, String>): String {
		final tree: String = dir.file('tree');
		FileSystem.createDirectory(Path.join([tree, WorkflowsRow.FOLDER]));
		for (name => text in files) File.saveContent(Path.join([tree, WorkflowsRow.FOLDER, '$name.yaml']), text);
		return tree;
	}

}
